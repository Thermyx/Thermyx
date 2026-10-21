// Thermyx prototype alert relay. Deploy behind HTTPS on Node 22.5+.
//
// Access model
//   - A team member runs `node admin.js wearer-code` on the server to make a
//     one-time, 10-minute wearer code. The wearer's phone redeems it once and
//     receives its own device token. No shared secret ships in the app.
//   - The wearer's phone makes one-time watcher codes. A watcher who redeems
//     one is "pending" and sees nothing until the wearer approves them. The
//     wearer can revoke any watcher at any time; approval lasts 90 days.
//   - Watchers see a status card: the safety level and how fresh it is, the
//     name the wearer chose, which foot, its temperature and trend, whether
//     the data is confirmed, a low battery or weak connection, the current
//     event's timeline (alert, check-in, recovery), and a location only during
//     an active safety event the wearer shares it for.
//   - Trusted contacts are texted the same facts as plain sentences
//     (message.js). Their numbers arrive with each event and are not stored;
//     during an active High risk, Critical or SOS event they are held in
//     memory so the relay can text "no update" if the wearer's phone goes
//     quiet, and forgotten when the event ends.
//   - Tokens and codes are stored hashed; logs never contain tokens, codes,
//     phone numbers, or locations.
//
// Environment
//   PORT                   default 8787
//   DATABASE_FILE          default ./data/thermyx.sqlite (needs a persistent disk)
//   SMS_ENABLED            "true" to allow texting; OFF by default until tested with real phones
//   TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN, TWILIO_FROM_NUMBER   (only when SMS_ENABLED)
//   SMS_REMINDER_MINUTES   repeat-text gap at the same level, default 5
//   SILENCE_MINUTES        during an active event, text "no update" after this
//                          long without hearing from the wearer's phone, default 3
//   APNS_KEY_FILE (or APNS_KEY), APNS_KEY_ID, APNS_TEAM_ID, APNS_TOPIC
//                          push notifications to approved watchers' phones.
//                          Needs a paid Apple Developer account; off until all
//                          four are set. See README.md.
//   CONTACT_VERIFICATION_ENABLED  "true" to text trusted contacts a code that
//                          confirms their number; also needs SMS_ENABLED. OFF by default.
//   AI_SUMMARY_ENABLED     "true" to allow the daily AI summary. OFF by default.
//   ANTHROPIC_API_KEY      needed when AI_SUMMARY_ENABLED. The key lives here,
//                          on the server, and never in the app, where it could
//                          be pulled out of the binary.
//   AI_MODEL               default claude-haiku-4-5
//
// Any of these can be kept in ThermyxBackend/.env (git-ignored; copy
// .env.example), which is read at startup. Real environment variables win.
const http = require("node:http");
const path = require("node:path");
const { openStore } = require("./store");
const { cleanDetail, composeMessage, composeSilence, composeReconnected, composePush, pushFromText, LEVELS } = require("./message");
const { apnsConfig, createApnsSender } = require("./apns");

const KINDS = ["status", "alert", "sos", "ok", "update", "help", "test"];
/// A wearer's own "send a test to my circle", at most this often.
const CIRCLE_TEST_GAP_MS = 10 * 60_000;
/// An active event's numbers are forgotten this long after the last update.
const ACTIVE_EVENT_TTL_MS = 60 * 60_000;
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
  if (event.test !== undefined && typeof event.test !== "boolean") return "invalid_test";
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
  "averageAmbientC", "hotHours", "cadence", "standingMinutes", "gait", "events",
  "steps", "walkingMinutes", "sittingMinutes"
];

/// What the wearer said Thermyx is mostly for, from the app's fixed list.
const USAGE = ["Outdoor work", "Sports and training", "Cold weather", "Everyday comfort"];

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
  if (Array.isArray(body.usage)) {
    const usage = body.usage.filter(u => USAGE.includes(u));
    if (usage.length) clean.usage = [...new Set(usage)];
  }
  clean.unit = body.unit === "F" ? "F" : "C";
  if (clean.wornMinutes === undefined) return null;
  return clean;
}

const SUMMARY_SYSTEM = [
  "You write a short daily summary for someone who wears Thermyx, a smart insole that senses foot temperature and movement and can heat or cool.",
  "Use only the numbers given. Never invent a value, and skip anything that is missing.",
  "Write 2 or 3 plain, friendly sentences in second person, then 2 or 3 short recommended actions for tomorrow, each on its own line starting with \"• \". No headings, no emoji. Keep the whole reply under 90 words.",
  "Temperatures are given in Celsius; present them in the requested unit (C or F) with one decimal.",
  "Do not diagnose or make medical claims. If something stands out (a lot of heat, a cold foot, a High risk or Critical level), suggest common-sense steps like resting, drinking water, or checking shoe fit, and suggest talking to a doctor if they're worried.",
  "Frame the day by the wearer's focus. Health: safety, comfort and circulation first (time above the comfort band, cold feet, rest and fluids). Performance: training, recovery and gait efficiency first (steps, cadence, walking steadiness, time on their feet). With no focus, use health.",
  "If they said what Thermyx is mostly for (usage), make the actions fit it, for example breaks in the shade for outdoor work, cool-down and recovery for training, warming up gradually for cold weather."
].join(" ");

const CHAT_SYSTEM = [
  "You are Thermyx's assistant, chatting with someone who wears Thermyx smart insoles (they sense foot temperature at the insole, an arch pressure sensor, steps and walking steadiness, and can heat or cool).",
  "You are given one day's totals and averages, and the conversation so far. Use only those numbers; never invent a value. If they ask about something the numbers don't cover, say so plainly.",
  "Talk like a friendly, knowledgeable person: warm, clear, everyday words, no jargon, no emoji, no markdown headings. Two to five sentences unless they ask for more.",
  "Temperatures are in Celsius; give them in the requested unit (C or F) with one decimal.",
  "You are not a doctor. Never diagnose. For anything worrying (feeling unwell, dizziness, a High risk or Critical level, numbness, pain), suggest resting, cooling down, drinking water, and talking to a doctor; for an emergency, tell them to call 911.",
  "Frame advice by their focus (health or performance) and what they use Thermyx for, when given."
].join(" ");

/// Keeps a chat's messages to plain text turns: at most 16, alternating,
/// each under 800 characters, ending with the wearer. Null when invalid.
function cleanChat(messages) {
  if (!Array.isArray(messages) || !messages.length || messages.length > 16) return null;
  const clean = [];
  for (const m of messages) {
    if (!m || (m.role !== "user" && m.role !== "assistant") || typeof m.content !== "string") return null;
    const content = m.content.replace(/[\u0000-\u0008\u000b-\u001f\u007f]/g, " ").trim().slice(0, 800);
    if (!content) return null;
    clean.push({ role: m.role, content });
  }
  if (clean[0].role !== "user" || clean.at(-1).role !== "user") return null;
  for (let i = 1; i < clean.length; i++) if (clean[i].role === clean[i - 1].role) return null;
  return clean;
}

function anthropicChat(env) {
  return async (day, messages) => {
    const response = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: { "x-api-key": env.ANTHROPIC_API_KEY, "anthropic-version": "2023-06-01", "content-type": "application/json" },
      body: JSON.stringify({
        model: env.AI_MODEL || "claude-haiku-4-5",
        max_tokens: 400,
        system: `${CHAT_SYSTEM}\nThe day's numbers: ${JSON.stringify(day)}`,
        messages
      })
    });
    if (!response.ok) throw new Error(`Anthropic request failed: ${response.status}`);
    const data = await response.json();
    const text = (data.content || []).filter(part => part.type === "text").map(part => part.text).join("").trim();
    if (!text) throw new Error("empty reply");
    return text;
  };
}

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
  const silenceMs = Number(env.SILENCE_MINUTES || 3) * 60_000;
  const apns = options.sendPush || (apnsConfig(env) ? createApnsSender(apnsConfig(env), now) : null);
  /// Pushes in flight; tests wait for them with `settle()`.
  const pending = new Set();
  /// The last push per device, in memory: the highest level pushed this
  /// event, when, and when the last follow-up went.
  const pushed = new Map();
  /// Active High risk, Critical or SOS events that were texted, by device:
  /// the recipients (memory only), the name and level for a "no update"
  /// text, when the phone last posted, and whether that text went out.
  const active = new Map();
  const sendSMS = options.sendSMS || twilioSend(env);
  const pairLimit = rateLimiter(10, 60_000, now);   // per IP: slows code guessing
  const apiLimit = rateLimiter(120, 60_000, now);   // per token
  const verifyLimit = rateLimiter(5, 60 * 60_000, now); // contact codes per wearer per hour
  const aiSummary = env.AI_SUMMARY_ENABLED === "true";
  const summarize = options.summarize || anthropicSummarize(env);
  const summaryLimit = rateLimiter(20, 60 * 60_000, now); // AI summaries per wearer per hour
  const chat = options.chat || anthropicChat(env);
  const chatLimit = rateLimiter(60, 60 * 60_000, now);    // chat turns per wearer per hour

  store.purgeExpired();
  const purgeTimer = setInterval(() => store.purgeExpired(), 10 * 60_000);
  purgeTimer.unref();
  const silenceTimer = setInterval(() => { checkSilence().catch(error => log("Silence check failed:", error.message)); }, 15_000);
  silenceTimer.unref();

  /// Texts the circle once when an active event goes quiet.
  async function checkSilence() {
    const t = now();
    for (const [deviceID, event] of active) {
      if (t - event.lastAt >= ACTIVE_EVENT_TTL_MS) { active.delete(deviceID); continue; }
      if (event.silenceSent || t - event.lastAt < silenceMs) continue;
      event.silenceSent = true;
      const minutes = Math.round((t - event.lastAt) / 60_000);
      const message = composeSilence({ ...event, location: event.locationConsent ? store.activeLocation(deviceID) : null }, minutes);
      pushWatchers(deviceID, pushFromText(message, true));
      if (smsEnabled && event.recipients.length) {
        const { delivered, failed } = await textAll(event.recipients, message);
        store.recordText(deviceID, "silence", LEVELS.indexOf(event.level), delivered, failed);
      }
      store.addTimelineEntry(deviceID, { kind: "silence", level: event.level, minutes });
    }
  }

  /// Sends a notification to every approved watcher's phone that has
  /// registered one. Never throws; a dead token is forgotten.
  function pushWatchers(deviceID, notification) {
    if (!apns) return 0;
    const targets = store.pushTargets(deviceID);
    for (const target of targets) {
      const job = Promise.resolve(apns(target.token, target.environment, notification))
        .then(result => {
          if (result && result.ok === false) {
            log(`Push to watcher ${target.watcher_id.slice(0, 8)} failed: ${result.reason || result.status}`);
            if (result.gone) store.forgetPushToken(target.token);
          }
        })
        .catch(error => log("Push failed:", error.message))
        .finally(() => pending.delete(job));
      pending.add(job);
    }
    return targets.length;
  }

  /// Whether this event is worth a push: an SOS or a check-in always; an
  /// alert on a rise (or at the reminder gap); a follow-up once the event
  /// has been pushed, at most once a minute.
  function pushDue(event, deviceID) {
    const kind = event.kind || "alert";
    if (kind === "status") return false;
    // An admin's test send goes every time it's pressed.
    if (event.test === true) return true;
    if (kind === "sos" || kind === "ok" || kind === "help") return true;
    if (kind === "test") return testDue(deviceID);
    const last = pushed.get(deviceID);
    if (kind === "update") return Boolean(last) && now() - (last.updateAt || 0) >= 60_000;
    const severity = LEVELS.indexOf(event.level);
    if (severity <= 0) return false;
    return !last || severity > last.severity || now() - last.at >= reminderMs;
  }

  /// The wearer's "test my circle": once per CIRCLE_TEST_GAP_MS.
  const lastCircleTest = new Map();
  function testDue(deviceID) {
    const last = lastCircleTest.get(deviceID);
    return !last || now() - last >= CIRCLE_TEST_GAP_MS;
  }

  async function textAll(recipients, message) {
    let delivered = 0;
    let failed = 0;
    for (const to of recipients) {
      try { await sendWithRetry(sendSMS, to, message); delivered += 1; }
      catch (error) { failed += 1; log(`SMS to …${to.slice(-4)} failed:`, error.message); }
    }
    return { delivered, failed };
  }

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

  /// Whether this event texts the circle. SOS and check-ins always do. An
  /// alert does on a rise, and again at the reminder gap. A follow-up
  /// ("still High risk", "recovering", "back to Normal") only follows an
  /// alert that was texted in this event, at most once a minute.
  function shouldText(event, deviceID) {
    const kind = event.kind || "alert";
    if (kind === "status") return false;
    if (event.test === true) return true;
    if (kind === "sos" || kind === "ok" || kind === "help") return true;
    if (kind === "test") return testDue(deviceID);
    const previous = store.lastText(deviceID);
    if (kind === "update") {
      if (!store.eventTexted(deviceID)) return false;
      const lastUpdate = store.lastTextOfKind(deviceID, "update");
      return !lastUpdate || now() - lastUpdate.at >= 60_000;
    }
    const severity = LEVELS.indexOf(event.level);
    if (severity <= 0) return false;
    if (!previous) return true;
    if (severity > previous.severity) return true;
    return now() - previous.at >= reminderMs;
  }

  async function handleEvent(identity, event, res) {
    const problem = validateEvent(event);
    if (problem) return json(res, 400, { error: problem });
    const kind = event.kind || "alert";
    const deviceID = identity.deviceID;
    const detail = cleanDetail(event.detail);
    const recipients = [...new Set((event.recipients || []).map(normalisePhone).filter(Boolean))].slice(0, MAX_RECIPIENTS);

    // Decide before the status (and the episode) changes underneath.
    const texts = recipients.length > 0 && smsEnabled && shouldText(event, deviceID);
    const pushing = Boolean(apns) && pushDue(event, deviceID);
    const tracked = active.get(deviceID);
    const reconnecting = Boolean(tracked && tracked.silenceSent);
    if (tracked) {
      tracked.lastAt = now();
      tracked.silenceSent = false;
      tracked.level = event.level === "Normal" ? tracked.level : event.level;
      if (recipients.length) tracked.recipients = recipients;
      if (detail && detail.name) tracked.name = detail.name;
      tracked.locationConsent = event.locationConsent === true;
    }

    if (event.test === true) store.noteTest(deviceID, kind);
    if (kind === "test" && (texts || pushing)) lastCircleTest.set(deviceID, now());
    // A circle test says nothing about how the wearer is: the status and
    // the event timeline stay as they were.
    if (kind !== "test") {
      store.updateStatus(deviceID, {
        level: event.level,
        kind,
        location: event.location,
        locationConsent: event.locationConsent === true,
        detail
      });
    }
    const endsEvent = event.level === "Normal" && !["ok", "sos", "help", "test"].includes(kind);
    // The event is over: forget the numbers and the episode's text history.
    if (endsEvent) {
      active.delete(deviceID);
      if (!texts) store.clearLastText(deviceID);
    }

    // Push to approved watchers, alongside the texts rather than after them.
    let watchersPushed = 0;
    if (pushing) {
      watchersPushed = pushWatchers(deviceID, composePush(event, detail));
      const last = pushed.get(deviceID) || { severity: 0, at: 0, updateAt: 0 };
      if (kind === "update") last.updateAt = now();
      else if (kind === "alert") { last.severity = Math.max(last.severity, LEVELS.indexOf(event.level)); last.at = now(); }
      else last.at = now();
      pushed.set(deviceID, last);
    } else if (reconnecting && apns) {
      watchersPushed = pushWatchers(deviceID, pushFromText(composeReconnected(event, detail), false));
    }
    if (endsEvent) pushed.delete(deviceID);
    // A pushed High risk, Critical, SOS or help request is watched for
    // silence even when nobody is texted.
    const severeNow = kind === "sos" || kind === "help" || event.level === "High risk" || event.level === "Critical";
    const watchLevel = event.level !== "Normal" ? event.level : kind === "help" ? "help request" : "SOS";
    if (watchersPushed && severeNow && kind !== "ok" && kind !== "test" && !active.has(deviceID)) {
      active.set(deviceID, {
        recipients: smsEnabled ? recipients : [], name: detail && detail.name,
        level: watchLevel,
        lastAt: now(), silenceSent: false, locationConsent: event.locationConsent === true
      });
    }

    if (!recipients.length || (kind === "status" && !reconnecting)) return json(res, 202, { stored: true, texted: 0, pushed: watchersPushed, smsEnabled });
    if (!smsEnabled) return json(res, 202, { stored: true, texted: 0, pushed: watchersPushed, smsEnabled: false, reason: "sms_disabled" });
    if (!texts && !reconnecting) return json(res, 202, { stored: true, texted: 0, pushed: watchersPushed, smsEnabled, reason: "throttled" });
    if (!options.sendSMS && TWILIO_KEYS.some(key => !env[key])) {
      log("SMS enabled but Twilio is not configured");
      return json(res, 503, { error: "sms_not_configured" });
    }

    const message = texts ? composeMessage(event, detail) : composeReconnected(event, detail);
    const { delivered, failed } = await textAll(recipients, message);
    store.recordText(deviceID, texts ? kind : "reconnect", LEVELS.indexOf(event.level), delivered, failed);
    if (texts && event.level === "Normal" && kind === "update") store.clearLastText(deviceID);

    // A texted High risk, Critical, SOS or help request is watched for silence.
    if (delivered && severeNow && kind !== "ok" && kind !== "test" && !active.has(deviceID)) {
      active.set(deviceID, {
        recipients, name: detail && detail.name, level: watchLevel,
        lastAt: now(), silenceSent: false, locationConsent: event.locationConsent === true
      });
    }
    return json(res, failed && !delivered ? 502 : 202, { stored: true, texted: delivered, failed, pushed: watchersPushed, smsEnabled });
  }

  const server = http.createServer((req, res) => {
    const url = new URL(req.url, "http://relay.local");
    const route = `${req.method} ${url.pathname}`;

    if (route === "GET /health") return json(res, 200, { ok: true, smsEnabled, contactVerification, aiSummary, push: Boolean(apns) });

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
      // The phone's push token, so alerts reach the watcher with the app closed.
      if (route === "PUT /v1/watch/push") {
        return readBody(req, res, body => {
          const environment = body.environment;
          if (typeof body.token !== "string" || !/^[0-9a-fA-F]{32,200}$/.test(body.token)) return json(res, 400, { error: "invalid_token" });
          if (environment !== "development" && environment !== "production") return json(res, 400, { error: "invalid_environment" });
          store.setPushToken(identity.watcherID, body.token.toLowerCase(), environment);
          return json(res, 200, { registered: true, pushEnabled: Boolean(apns) });
        });
      }
      if (route === "DELETE /v1/watch/push") {
        store.clearPushToken(identity.watcherID);
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
    // AI chat about one day: the same aggregate numbers as the summary, plus
    // the conversation. Neither is stored or logged.
    if (route === "POST /v1/chat") {
      if (!aiSummary) return json(res, 403, { error: "ai_summary_disabled" });
      if (!options.chat && !env.ANTHROPIC_API_KEY) return json(res, 503, { error: "ai_summary_not_configured" });
      if (!chatLimit(identity.deviceID)) return json(res, 429, { error: "rate_limited" });
      return readBody(req, res, async body => {
        const day = cleanSummaryRequest(body.day);
        const messages = cleanChat(body.messages);
        if (!day || !messages) return json(res, 400, { error: "invalid_chat_request" });
        try {
          return json(res, 200, { reply: await chat(day, messages) });
        } catch (error) {
          log("AI chat failed:", error.message);
          return json(res, 502, { error: "chat_failed" });
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

  server.on("close", () => { clearInterval(purgeTimer); clearInterval(silenceTimer); if (apns && apns.close) apns.close(); });
  return { server, store, checkSilence, settle: () => Promise.all([...pending]) };
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

module.exports = { createRelay, validateEvent, normalisePhone, composeMessage, cleanSummaryRequest, cleanChat };

if (require.main === module) {
  // Settings from .env beside this file, if there is one. Variables already
  // set in the environment take precedence.
  try {
    process.loadEnvFile(path.join(__dirname, ".env"));
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
  }
  const relay = createRelay();
  const port = Number(process.env.PORT || 8787);
  relay.server.listen(port, () => log(`Thermyx relay listening on ${port} (texting ${process.env.SMS_ENABLED === "true" ? "ON" : "OFF"})`));
}
