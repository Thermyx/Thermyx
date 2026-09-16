// Minimal prototype alert relay. Deploy behind HTTPS and set environment variables.
// Required: THERMYX_TOKEN, TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN, TWILIO_FROM_NUMBER
// Optional: PORT (default 8787)
const http = require("node:http");

const port = Number(process.env.PORT || 8787);
const required = ["THERMYX_TOKEN", "TWILIO_ACCOUNT_SID", "TWILIO_AUTH_TOKEN", "TWILIO_FROM_NUMBER"];
const latestEvents = new Map();

function json(res, status, body) {
  res.writeHead(status, { "Content-Type": "application/json" });
  res.end(JSON.stringify(body));
}

async function twilio(endpoint, params) {
  const body = new URLSearchParams(params);
  const auth = Buffer.from(`${process.env.TWILIO_ACCOUNT_SID}:${process.env.TWILIO_AUTH_TOKEN}`).toString("base64");
  const response = await fetch(`https://api.twilio.com/2010-04-01/Accounts/${process.env.TWILIO_ACCOUNT_SID}/${endpoint}`, {
    method: "POST",
    headers: { Authorization: `Basic ${auth}`, "Content-Type": "application/x-www-form-urlencoded" },
    body
  });
  if (!response.ok) throw new Error(`Twilio request failed: ${response.status}`);
}

const server = http.createServer((req, res) => {
  if (req.method === "GET" && req.url.startsWith("/v1/status/")) {
    if (req.headers.authorization !== `Bearer ${process.env.THERMYX_TOKEN}`) return json(res, 401, { error: "unauthorized" });
    const deviceID = decodeURIComponent(req.url.slice("/v1/status/".length));
    return json(res, 200, { event: latestEvents.get(deviceID) || null });
  }
  if (req.method !== "POST" || req.url !== "/v1/alerts") return json(res, 404, { error: "not_found" });
  if (req.headers.authorization !== `Bearer ${process.env.THERMYX_TOKEN}`) return json(res, 401, { error: "unauthorized" });

  let raw = "";
  req.on("data", chunk => { raw += chunk; if (raw.length > 100_000) req.destroy(); });
  req.on("end", async () => {
    try {
      const event = JSON.parse(raw);
      if (!["Normal", "Caution", "High risk", "Critical"].includes(event.level)) return json(res, 400, { error: "invalid_level" });
      latestEvents.set(event.deviceID, event);
      const recipients = Array.isArray(event.recipients) ? event.recipients.filter(Boolean).slice(0, 5) : [];
      if (!recipients.length) return json(res, 202, { delivered: 0, reason: "no_recipients" });
      const message = `Thermyx ${event.level}: ${event.reasons?.join(" ") || "Please check the user."} Device: ${event.deviceID}`;
      if (required.some(key => !process.env[key])) return json(res, 503, { error: "backend_not_configured" });
      for (const to of recipients) {
        await twilio(`Messages.json`, { To: to, From: process.env.TWILIO_FROM_NUMBER, Body: message });
      }
      json(res, 202, { delivered: recipients.length });
    } catch (error) {
      json(res, 400, { error: error.message });
    }
  });
});

server.listen(port, () => console.log(`Thermyx alert relay listening on ${port}`));
