// Thermyx prototype alert relay. Deploy behind HTTPS on Node 22.5+.
//
// Access model
//   - A team member runs `node admin.js wearer-code` on the server to make a
//     one-time, 10-minute wearer code. The wearer's phone redeems it once and
//     receives its own device token. No shared secret ships in the app.
//   - The wearer's phone makes one-time watcher codes. A watcher who redeems
//     one is "pending" and sees nothing until the wearer approves them. The
//     wearer can revoke any watcher at any time; approval lasts 90 days.
//   - Watchers see only the current safety level, its kind (alert/SOS/OK) and
//     how fresh it is, plus a location only during an active safety event the
//     wearer consented to share.
//   - Tokens and codes are stored hashed; logs never contain tokens, codes,
//     phone numbers, or locations.
//
// Environment
//   PORT                   default 8787
//   DATABASE_FILE          default ./data/thermyx.sqlite (needs a persistent disk)
//   SMS_ENABLED            "true" to allow texting; OFF by default until tested with real phones
//   TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN, TWILIO_FROM_NUMBER   (only when SMS_ENABLED)
//   SMS_REMINDER_MINUTES   repeat-text gap at the same level, default 5
//   CONTACT_VERIFICATION_ENABLED  "true" to text trusted contacts a code that
//                          confirms their number; also needs SMS_ENABLED. OFF by default.
//   AI_SUMMARY_ENABLED     "true" to allow the daily AI summary. OFF by default.
//   ANTHROPIC_API_KEY      needed when AI_SUMMARY_ENABLED
//   AI_MODEL               default claude-haiku-4-5
const http = require("node:http");
const path = require("node:path");
const { openStore } = require("./store");

const LEVELS = ["Normal", "Caution", "High risk", "Critical"];
const KINDS = ["status", "alert", "sos", "ok"];
const TWILIO_KEYS = ["TWILIO_ACCOUNT_SID", "TWILIO_AUTH_TOKEN", "TWILIO_FROM_NUMBER"];
const MAX_BODY = 16_000;
const MAX_RECIPIENTS = 5;

function log(...args) {
  console.log(new Date().toISOString(), ...args);
}

function json(res, status, body) {
  res.writeHead(status, { "Content-Type": "application/json", "Cache-Control": "no-store" });
  res.end(JSON.stringify(body));
}

/// Validates a wearer event. Returns an error code, or null when valid.
function validateEvent(event) {
  if (!event || typeof event !== "object" || Array.isArray(event)) return "invalid_body";
  if (!LEVELS.includes(event.level)) return "invalid_level";
  if (event.kind !== undefined && !KINDS.includes(event.kind)) return "invalid_kind";
  if (event.recipients !== undefined && (!Array.isArray(event.recipients) || event.recipients.some(r => typeof r !== "string"))) {
    return "invalid_recipients";
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

const SUMMARY_NUMBERS = [
  "wornMinutes", "heatingMinutes", "coolingMinutes", "averageFootC", "peakFootC", "lowFootC",
  "averageAmbientC", "hotHours", "cadence", "standingMinutes", "gait", "events"
];

/// Keeps only the aggregate numbers a daily summary may use, so nothing
/// else the app might send reaches the model. Returns null when invalid.
function cleanSummaryRequest(body) {
  if (!body || typeof body !== "object" || Array.isArray(body)) return null;
  if (typeof body.day !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(body.day)) return null;
  const clean = { day: body.day };
  for (const key of SUMMARY_NUMBERS) {
    const v = body[key];
    if (v === undefined || v === null) continue;
    if (typeof v !== "number" || !Number.isFinite(v) || Math.abs(v) > 100_000) return null;
    clean[key] = Math.round(v * 10) / 10;
  }
  if (body.peakRisk !== undefined && body.peakRisk !== null) {
    if (!LEVELS.includes(body.peakRisk)) return null;
    clean.peakRisk = body.peakRisk;
  }
  if (body.focus === "health" || body.focus === "performance") clean.focus = body.focus;
  clean.unit = body.unit === "F" ? "F" : "C";
  if (clean.wornMinutes === undefined) return null;
  return clean;
}

const SUMMARY_SYSTEM = [
  "You write a short daily summary for someone who wears Thermyx, a smart insole that senses foot temperature and movement and can heat or cool.",
  "Use only the numbers given. Never invent a value, and skip anything that is missing.",
  "Write 3 to 4 plain, friendly sentences in second person. No lists, no headings, no emoji.",
  "Temperatures are given in Celsius; present them in the requested unit (C or F) with one decimal.",
  "Do not diagnose or make medical claims. If something stands out (a lot of heat, a cold foot, a High risk or Critical level), suggest common-sense steps like resting, drinking water, or checking shoe fit, and suggest talking to a doctor if they're worried.",
  "If the focus is performance, lead with movement (cadence, standing time); if health, lead with temperature and comfort."
].join(" ");

function anthropicSummarize(env) {
  return async request => {
    const response = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: {
        "x-api-key": env.ANTHROPIC_API_KEY,
        "anthropic-version": "2023-06-01",
        "content-type": "application/json"
      },
      body: JSON.stringify({
        model: env.AI_MODEL || "claude-haiku-4-5",
        max_tokens: 300,
        system: SUMMARY_SYSTEM,
        messages: [{ role: "user", content: `Today's numbers:\n${JSON.stringify(request)}` }]
      })
    });
    if (!response.ok) throw new Error(`Anthropic request failed: ${response.status}`);
    const data = await response.json();
    const text = (data.content || []).filter(part => part.type === "text").map(part => part.text).join("").trim();
    if (!text) throw new Error("empty summary");
    return text;
  };
}

/// Normalises a phone number to E.164, or returns null.
function normalisePhone(raw) {
  const digits = raw.replace(/[^\d+]/g, "");
  if (/^\+\d{8,15}$/.test(digits)) return digits;
  if (/^\d{10}$/.test(digits)) return `+1${digits}`;
  if (/^1\d{10}$/.test(digits)) return `+${digits}`;
  return null;
}

function composeMessage(event, deviceID) {
  const kind = event.kind || "alert";
  const lines = [];
  if (kind === "ok") lines.push(`Thermyx: the wearer on ${deviceID} checked in and says they're OK.`);
  else if (kind === "sos") lines.push(`Thermyx SOS from ${deviceID}: the wearer pressed Call 911.`);
  else lines.push(`Thermyx ${event.level} on ${deviceID}.`);
  const reasons = Array.isArray(event.reasons) ? event.reasons.filter(Boolean).join(" ") : "";
  if (reasons) lines.push(reasons);
  if (event.locationConsent && event.location && typeof event.location.latitude === "number") {
    const { latitude, longitude } = event.location;
    lines.push(`Location: https://maps.google.com/?q=${latitude.toFixed(5)},${longitude.toFixed(5)}`);
  }
  if (kind !== "ok") lines.push("Please check on them.");
  return lines.join(" ");
}

/// A small fixed-window rate limiter keyed by token hash or IP.
function rateLimiter(limit, windowMs, now) {
  const hits = new Map();
  return key => {
    const t = now();
    const entry = hits.get(key);
    if (!entry || t - entry.start >= windowMs) {
      hits.set(key, { start: t, count: 1 });
      if (hits.size > 10_000) hits.clear();
      return true;
    }
    entry.count += 1;
    return entry.count <= limit;
  };
}

function createRelay(options = {}) {
  const env = options.env || process.env;
  const now = options.now || (() => Date.now());
  const store = options.store || openStore(env.DATABASE_FILE || path.join(__dirname, "data", "thermyx.sqlite"), now);
  const smsEnabled = env.SMS_ENABLED === "true";
  const contactVerification = smsEnabled && env.CONTACT_VERIFICATION_ENABLED === "true";
  const reminderMs = Number(env.SMS_REMINDER_MINUTES || 5) * 60_000;
  const sendSMS = options.sendSMS || twilioSend(env);
  const pairLimit = rateLimiter(10, 60_000, now);   // per IP: slows code guessing
  const apiLimit = rateLimiter(120, 60_000, now);   // per token
  const verifyLimit = rateLimiter(5, 60 * 60_000, now); // contact codes per wearer per hour
  const aiSummary = env.AI_SUMMARY_ENABLED === "true";
  const summarize = options.summarize || anthropicSummarize(env);
  const summaryLimit = rateLimiter(20, 60 * 60_000, now); // AI summaries per wearer per hour

  store.purgeExpired();
  const purgeTimer = setInterval(() => store.purgeExpired(), 10 * 60_000);
  purgeTimer.unref();

  function bearer(req) {
    const header = req.headers.authorization || "";
    return header.startsWith("Bearer ") ? header.slice(7) : null;
  }

  function readBody(req, res, handler) {
    let raw = "";
    let aborted = false;
    req.on("data", chunk => {
      raw += chunk;
      if (raw.length > MAX_BODY && !aborted) {
        aborted = true;
        json(res, 413, { error: "body_too_large" });
        req.destroy();
      }
    });
    req.on("end", () => {
      if (aborted) return;
      let body = {};
      if (raw.trim()) {
        try { body = JSON.parse(raw); } catch { return json(res, 400, { error: "invalid_json" }); }
      }
      Promise.resolve(handler(body)).catch(error => {
        log("Unexpected error:", error.message);
        if (!res.headersSent) json(res, 500, { error: "internal_error" });
      });
    });
  }

  function shouldText(event, deviceID) {
    const kind = event.kind || "alert";
    if (kind === "status") return false;
    if (kind === "sos" || kind === "ok") return true;
    const severity = LEVELS.indexOf(event.level);
    if (severity <= 0) return false;
    const previous = store.lastText(deviceID);
    if (!previous) return true;
    if (severity > previous.severity) return true;
    return now() - previous.at >= reminderMs;
  }

  async function handleEvent(identity, event, res) {
    const problem = validateEvent(event);
    if (problem) return json(res, 400, { error: problem });
    const kind = event.kind || "alert";
    store.updateStatus(identity.deviceID, {
      level: event.level,
      kind,
      location: event.location,
      locationConsent: event.locationConsent === true
    });
    if (event.level === "Normal" && kind !== "ok") store.clearLastText(identity.deviceID);

    const recipients = [...new Set((event.recipients || []).map(normalisePhone).filter(Boolean))].slice(0, MAX_RECIPIENTS);
    if (!recipients.length || kind === "status") return json(res, 202, { stored: true, texted: 0, smsEnabled });
    if (!smsEnabled) return json(res, 202, { stored: true, texted: 0, smsEnabled: false, reason: "sms_disabled" });
    if (!shouldText(event, identity.deviceID)) return json(res, 202, { stored: true, texted: 0, smsEnabled, reason: "throttled" });
    if (!options.sendSMS && TWILIO_KEYS.some(key => !env[key])) {
      log("SMS enabled but Twilio is not configured");
      return json(res, 503, { error: "sms_not_configured" });
    }

    const message = composeMessage(event, identity.deviceID);
    let delivered = 0;
    let failed = 0;
    for (const to of recipients) {
      try { await sendWithRetry(sendSMS, to, message); delivered += 1; }
      catch (error) { failed += 1; log(`SMS to …${to.slice(-4)} failed:`, error.message); }
    }
    store.recordText(identity.deviceID, kind, LEVELS.indexOf(event.level), delivered, failed);
    return json(res, failed && !delivered ? 502 : 202, { stored: true, texted: delivered, failed, smsEnabled });
  }

  const server = http.createServer((req, res) => {
    const url = new URL(req.url, "http://relay.local");
    const route = `${req.method} ${url.pathname}`;

    if (route === "GET /health") return json(res, 200, { ok: true, smsEnabled, contactVerification, aiSummary });

    // Pairing is the only unauthenticated write, and it is rate-limited per IP.
    if (route === "POST /v1/pair") {
      if (!pairLimit(req.socket.remoteAddress || "unknown")) return json(res, 429, { error: "too_many_attempts" });
      return readBody(req, res, body => {
        if (typeof body.code !== "string" || !body.code.trim()) return json(res, 400, { error: "invalid_code" });
        const result = store.redeemCode(body.code, typeof body.name === "string" ? body.name : undefined);
        if (!result) return json(res, 403, { error: "code_invalid_or_expired" });
        return json(res, 200, { ...result, smsEnabled, contactVerification });
      });
    }

    const token = bearer(req);
    const identity = store.authenticate(token);
    if (!identity) return json(res, 401, { error: "unauthorized" });
    if (!apiLimit(token)) return json(res, 429, { error: "rate_limited" });

    if (identity.role === "watcher") {
      // A watcher can always stop watching; this ends its own access only.
      if (route === "DELETE /v1/watch") {
        store.leaveAsWatcher(identity.watcherID);
        return json(res, 200, { removed: true });
      }
      if (route !== "GET /v1/watch") return json(res, 403, { error: "forbidden" });
      const state = store.watcherState(identity.watcherID);
      if (!state || state.status === "revoked") return json(res, 403, { error: "access_revoked" });
      if (state.status === "pending") return json(res, 200, { status: "pending" });
      if (state.expires_at <= now()) return json(res, 403, { error: "access_expired" });
      return json(res, 200, { status: "approved", state: store.watcherView(identity.deviceID) });
    }

    // Wearer routes.
    if (route === "POST /v1/events") return readBody(req, res, body => handleEvent(identity, body, res));
    if (route === "GET /v1/watchers") return json(res, 200, { watchers: store.listWatchers(identity.deviceID) });
    // Daily AI summary: the app sends one day's aggregate numbers (no
    // readings, names, or locations); they are passed to the model and
    // neither stored nor logged. Off unless AI_SUMMARY_ENABLED.
    if (route === "POST /v1/summary") {
      if (!aiSummary) return json(res, 403, { error: "ai_summary_disabled" });
      if (!options.summarize && !env.ANTHROPIC_API_KEY) return json(res, 503, { error: "ai_summary_not_configured" });
      if (!summaryLimit(identity.deviceID)) return json(res, 429, { error: "rate_limited" });
      return readBody(req, res, async body => {
        const request = cleanSummaryRequest(body);
        if (!request) return json(res, 400, { error: "invalid_summary_request" });
        try {
          return json(res, 200, { summary: await summarize(request) });
        } catch (error) {
          log("AI summary failed:", error.message);
          return json(res, 502, { error: "summary_failed" });
        }
      });
    }
    if (route === "POST /v1/watchers/codes") return json(res, 201, store.createWatcherCode(identity.deviceID));
    // Contact confirmation: the relay texts a 6-digit code to the number; the
    // contact reads it back to the wearer, who enters it. Off by default.
    if (route === "POST /v1/contacts/verify" || route === "POST /v1/contacts/confirm") {
      if (!contactVerification) return json(res, 403, { error: "verification_disabled" });
      return readBody(req, res, async body => {
        const phone = typeof body.phone === "string" ? normalisePhone(body.phone) : null;
        if (!phone) return json(res, 400, { error: "invalid_phone" });
        if (route === "POST /v1/contacts/confirm") {
          const result = store.confirmContact(identity.deviceID, phone, body.code);
          return json(res, result === "confirmed" ? 200 : 400, result === "confirmed" ? { verified: true } : { error: `code_${result}` });
        }
        if (!verifyLimit(identity.deviceID)) return json(res, 429, { error: "rate_limited" });
        const code = store.createContactCheck(identity.deviceID, phone);
        try {
          await sendWithRetry(sendSMS, phone, `Thermyx: ${code} is the code to confirm you're a trusted contact for ${identity.deviceID}. Read it to them only if you agreed to get their safety alerts.`);
        } catch (error) {
          log(`Verification text to …${phone.slice(-4)} failed:`, error.message);
          return json(res, 502, { error: "send_failed" });
        }
        return json(res, 202, { sent: true, expiresInMinutes: 10 });
      });
    }
    // The wearer's "Delete my data": ends this phone's access, every
    // watcher's access, and removes the stored status and location.
    if (route === "DELETE /v1/device") {
      store.revokeDevice(identity.deviceID, `wearer:${identity.deviceID}`);
      return json(res, 200, { deleted: true });
    }

    const match = url.pathname.match(/^\/v1\/watchers\/([0-9a-f-]{36})(\/approve)?$/);
    if (match && req.method === "POST" && match[2]) {
      return store.approveWatcher(identity.deviceID, match[1]) ? json(res, 200, { approved: true }) : json(res, 404, { error: "not_found" });
    }
    if (match && req.method === "DELETE" && !match[2]) {
      return store.revokeWatcher(identity.deviceID, match[1]) ? json(res, 200, { revoked: true }) : json(res, 404, { error: "not_found" });
    }
    return json(res, 404, { error: "not_found" });
  });

  server.on("close", () => clearInterval(purgeTimer));
  return { server, store };
}

async function sendWithRetry(send, to, message) {
  try {
    await send(to, message);
  } catch {
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

module.exports = { createRelay, validateEvent, normalisePhone, composeMessage, cleanSummaryRequest };

if (require.main === module) {
  const relay = createRelay();
  const port = Number(process.env.PORT || 8787);
  relay.server.listen(port, () => log(`Thermyx relay listening on ${port} (texting ${process.env.SMS_ENABLED === "true" ? "ON" : "OFF"})`));
}
