// Thermyx prototype alert relay. Deploy behind HTTPS and set environment variables.
//
// Required:  THERMYX_TOKEN            shared bearer token (the server refuses to start without it)
// Optional:  THERMYX_DEVICE_TOKENS    JSON map {"<deviceID>": "<token>"}; a listed device only
//                                     accepts its own token, never the shared one
//            TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN, TWILIO_FROM_NUMBER   (needed only to send SMS)
//            PORT                     default 8787
//            STATUS_FILE              where latest status is persisted, default ./data/status.json
//            SMS_REMINDER_MINUTES     minimum gap between repeat texts at the same level, default 5
const http = require("node:http");
const fs = require("node:fs");
const path = require("node:path");

const LEVELS = ["Normal", "Caution", "High risk", "Critical"];
const KINDS = ["status", "alert", "sos", "ok"];
const TWILIO_KEYS = ["TWILIO_ACCOUNT_SID", "TWILIO_AUTH_TOKEN", "TWILIO_FROM_NUMBER"];
const MAX_BODY = 100_000;
const MAX_RECIPIENTS = 5;

function log(...args) {
  console.log(new Date().toISOString(), ...args);
}

function json(res, status, body) {
  res.writeHead(status, { "Content-Type": "application/json" });
  res.end(JSON.stringify(body));
}

function parseDeviceTokens(raw) {
  if (!raw) return {};
  const parsed = JSON.parse(raw);
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new Error("THERMYX_DEVICE_TOKENS must be a JSON object of deviceID to token");
  }
  return parsed;
}

/// Validates an incoming event. Returns an error code string, or null when valid.
function validate(event) {
  if (!event || typeof event !== "object" || Array.isArray(event)) return "invalid_body";
  if (typeof event.deviceID !== "string" || !event.deviceID.trim() || event.deviceID.length > 128) return "invalid_device_id";
  if (!LEVELS.includes(event.level)) return "invalid_level";
  if (event.kind !== undefined && !KINDS.includes(event.kind)) return "invalid_kind";
  if (event.recipients !== undefined) {
    if (!Array.isArray(event.recipients)) return "invalid_recipients";
    if (event.recipients.some(r => typeof r !== "string")) return "invalid_recipients";
  }
  if (event.reasons !== undefined && (!Array.isArray(event.reasons) || event.reasons.some(r => typeof r !== "string"))) {
    return "invalid_reasons";
  }
  if (event.location !== undefined && event.location !== null) {
    const { latitude, longitude } = event.location;
    if (typeof latitude !== "number" || typeof longitude !== "number" || Math.abs(latitude) > 90 || Math.abs(longitude) > 180) {
      return "invalid_location";
    }
  }
  return null;
}

/// Normalises a phone number to E.164 (+ and digits), or returns null.
function normalisePhone(raw) {
  const digits = raw.replace(/[^\d+]/g, "");
  if (/^\+\d{8,15}$/.test(digits)) return digits;
  if (/^\d{10}$/.test(digits)) return `+1${digits}`; // US number without country code
  if (/^1\d{10}$/.test(digits)) return `+${digits}`;
  return null;
}

function composeMessage(event) {
  const kind = event.kind || "alert";
  const lines = [];
  if (kind === "ok") {
    lines.push(`Thermyx: the wearer on ${event.deviceID} checked in and says they're OK.`);
  } else if (kind === "sos") {
    lines.push(`Thermyx SOS from ${event.deviceID}: the wearer pressed Call 911.`);
  } else {
    lines.push(`Thermyx ${event.level} on ${event.deviceID}.`);
  }
  const reasons = Array.isArray(event.reasons) ? event.reasons.filter(Boolean).join(" ") : "";
  if (reasons) lines.push(reasons);
  if (event.location && typeof event.location.latitude === "number") {
    const { latitude, longitude } = event.location;
    lines.push(`Location: https://maps.google.com/?q=${latitude.toFixed(5)},${longitude.toFixed(5)}`);
  }
  if (kind !== "ok") lines.push("Please check on them.");
  return lines.join(" ");
}

function createRelay(options = {}) {
  const env = options.env || process.env;
  const token = env.THERMYX_TOKEN;
  if (!token) throw new Error("THERMYX_TOKEN is not set. Refusing to start an unauthenticated relay.");
  const deviceTokens = parseDeviceTokens(env.THERMYX_DEVICE_TOKENS);
  const statusFile = env.STATUS_FILE || path.join(__dirname, "data", "status.json");
  const reminderMs = Number(env.SMS_REMINDER_MINUTES || 5) * 60_000;
  const now = options.now || (() => Date.now());
  const sendSMS = options.sendSMS || twilioSend(env);

  const latestEvents = new Map();
  const lastTexted = new Map(); // deviceID -> { severity, at }

  // Restore the last known status so a restart does not blank every watcher.
  try {
    const saved = JSON.parse(fs.readFileSync(statusFile, "utf8"));
    for (const [id, event] of Object.entries(saved)) latestEvents.set(id, event);
    log(`Restored status for ${latestEvents.size} device(s) from ${statusFile}`);
  } catch (error) {
    if (error.code !== "ENOENT") log("Could not read status file:", error.message);
  }

  function persist() {
    try {
      fs.mkdirSync(path.dirname(statusFile), { recursive: true });
      const tmp = `${statusFile}.tmp`;
      fs.writeFileSync(tmp, JSON.stringify(Object.fromEntries(latestEvents)));
      fs.renameSync(tmp, statusFile);
    } catch (error) {
      log("Could not persist status:", error.message);
    }
  }

  function authorised(req, deviceID) {
    const header = req.headers.authorization || "";
    const expected = deviceID && Object.prototype.hasOwnProperty.call(deviceTokens, deviceID)
      ? deviceTokens[deviceID]
      : token;
    return header === `Bearer ${expected}`;
  }

  /// Decides whether this event should text the trusted circle.
  function shouldText(event) {
    const kind = event.kind || "alert";
    if (kind === "status") return false;
    if (kind === "sos" || kind === "ok") return true;
    const severity = LEVELS.indexOf(event.level);
    if (severity <= 0) return false;
    const previous = lastTexted.get(event.deviceID);
    if (!previous) return true;
    if (severity > previous.severity) return true;
    return now() - previous.at >= reminderMs;
  }

  function presentsAnyToken(req) {
    const header = req.headers.authorization || "";
    return header === `Bearer ${token}` || Object.values(deviceTokens).some(t => header === `Bearer ${t}`);
  }

  async function handleAlert(req, res, raw) {
    if (!presentsAnyToken(req)) return json(res, 401, { error: "unauthorized" });
    let event;
    try {
      event = JSON.parse(raw);
    } catch {
      return json(res, 400, { error: "invalid_json" });
    }
    const problem = validate(event);
    if (problem) return json(res, 400, { error: problem });
    if (!authorised(req, event.deviceID)) return json(res, 401, { error: "unauthorized" });

    const stored = { ...event, recipients: undefined, receivedAt: new Date(now()).toISOString() };
    delete stored.recipients;
    latestEvents.set(event.deviceID, stored);
    persist();

    // Back at Normal: forget the last text so the next escalation goes out at once.
    if (event.level === "Normal" && (event.kind || "alert") !== "ok") lastTexted.delete(event.deviceID);

    const recipients = [...new Set((event.recipients || []).map(normalisePhone).filter(Boolean))].slice(0, MAX_RECIPIENTS);
    if (!recipients.length) return json(res, 202, { delivered: 0, reason: "no_recipients" });
    if (!shouldText(event)) return json(res, 202, { delivered: 0, reason: "throttled" });
    if (!options.sendSMS && TWILIO_KEYS.some(key => !env[key])) {
      log("SMS requested but Twilio is not configured");
      return json(res, 503, { error: "sms_not_configured" });
    }

    const message = composeMessage(event);
    let delivered = 0;
    const failed = [];
    for (const to of recipients) {
      try {
        await sendWithRetry(sendSMS, to, message);
        delivered += 1;
      } catch (error) {
        log(`SMS to ${to.slice(0, -4).replace(/\d/g, "•")}${to.slice(-4)} failed:`, error.message);
        failed.push(to.slice(-4));
      }
    }
    if (delivered > 0 && (event.kind || "alert") === "alert") {
      lastTexted.set(event.deviceID, { severity: LEVELS.indexOf(event.level), at: now() });
    }
    return json(res, failed.length && !delivered ? 502 : 202, { delivered, failed: failed.length });
  }

  const server = http.createServer((req, res) => {
    const url = new URL(req.url, "http://relay.local");

    if (req.method === "GET" && url.pathname === "/health") {
      return json(res, 200, { ok: true });
    }

    if (req.method === "GET" && url.pathname.startsWith("/v1/status/")) {
      const deviceID = decodeURIComponent(url.pathname.slice("/v1/status/".length));
      if (!deviceID) return json(res, 400, { error: "invalid_device_id" });
      if (!authorised(req, deviceID)) return json(res, 401, { error: "unauthorized" });
      return json(res, 200, { event: latestEvents.get(deviceID) || null });
    }

    if (req.method !== "POST" || url.pathname !== "/v1/alerts") return json(res, 404, { error: "not_found" });

    let raw = "";
    let tooLarge = false;
    req.on("data", chunk => {
      raw += chunk;
      if (raw.length > MAX_BODY && !tooLarge) {
        tooLarge = true;
        json(res, 413, { error: "body_too_large" });
        req.destroy();
      }
    });
    req.on("end", () => {
      if (tooLarge) return;
      handleAlert(req, res, raw).catch(error => {
        log("Unexpected error:", error.message);
        if (!res.headersSent) json(res, 500, { error: "internal_error" });
      });
    });
  });

  return { server, latestEvents };
}

async function sendWithRetry(send, to, message) {
  try {
    await send(to, message);
  } catch (first) {
    await new Promise(resolve => setTimeout(resolve, 1000));
    await send(to, message);
  }
}

function twilioSend(env) {
  return async (to, body) => {
    const params = new URLSearchParams({ To: to, From: env.TWILIO_FROM_NUMBER, Body: body });
    const auth = Buffer.from(`${env.TWILIO_ACCOUNT_SID}:${env.TWILIO_AUTH_TOKEN}`).toString("base64");
    const response = await fetch(`https://api.twilio.com/2010-04-01/Accounts/${env.TWILIO_ACCOUNT_SID}/Messages.json`, {
      method: "POST",
      headers: { Authorization: `Basic ${auth}`, "Content-Type": "application/x-www-form-urlencoded" },
      body: params
    });
    if (!response.ok) throw new Error(`Twilio request failed: ${response.status}`);
  };
}

module.exports = { createRelay, validate, normalisePhone, composeMessage };

if (require.main === module) {
  let relay;
  try {
    relay = createRelay();
  } catch (error) {
    console.error(error.message);
    process.exit(1);
  }
  const port = Number(process.env.PORT || 8787);
  relay.server.listen(port, () => log(`Thermyx alert relay listening on ${port}`));
}
