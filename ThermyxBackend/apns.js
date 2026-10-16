// Apple Push Notification service, with no dependencies: an ES256 JWT signed
// with the team's .p8 key (Apple's "token-based" auth) over node:http2.
//
// Off until configured. Needs a paid Apple Developer account, because only
// it can create an APNs key and a Push Notifications capability. See
// README.md ("Push to watchers").
//
//   APNS_KEY_FILE   path to AuthKey_XXXXXXXXXX.p8 (or APNS_KEY, its contents)
//   APNS_KEY_ID     the key's 10-character ID
//   APNS_TEAM_ID    the Developer team's 10-character ID
//   APNS_TOPIC      the app's bundle identifier (com.thermyx.app.a)
const crypto = require("node:crypto");
const fs = require("node:fs");
const http2 = require("node:http2");

const b64url = input => Buffer.from(input).toString("base64url");
const HOSTS = { production: "https://api.push.apple.com", development: "https://api.sandbox.push.apple.com" };
/// Apple asks for a new token no more often than every 20 minutes and no
/// less often than every hour.
const TOKEN_LIFETIME_MS = 40 * 60_000;

/** A provider token: header.claims signed with ES256 (raw r||s, not DER). */
function signToken({ key, keyId, teamId }, issuedAtSeconds) {
  const header = b64url(JSON.stringify({ alg: "ES256", kid: keyId }));
  const claims = b64url(JSON.stringify({ iss: teamId, iat: issuedAtSeconds }));
  const signature = crypto.sign("sha256", Buffer.from(`${header}.${claims}`), { key, dsaEncoding: "ieee-p1363" });
  return `${header}.${claims}.${signature.toString("base64url")}`;
}

/** Reads the APNs settings; returns null unless all of them are present. */
function apnsConfig(env) {
  const key = env.APNS_KEY || (env.APNS_KEY_FILE && fs.existsSync(env.APNS_KEY_FILE) ? fs.readFileSync(env.APNS_KEY_FILE, "utf8") : null);
  if (!key || !env.APNS_KEY_ID || !env.APNS_TEAM_ID || !env.APNS_TOPIC) return null;
  return { key, keyId: env.APNS_KEY_ID, teamId: env.APNS_TEAM_ID, topic: env.APNS_TOPIC };
}

/**
 * Returns `send(token, environment, notification)`, which resolves to
 * `{ ok: true }` or `{ ok: false, status, reason, gone }`. `gone` means the
 * token is dead (uninstalled, or for the other environment) and should be
 * forgotten.
 */
function createApnsSender(config, now = () => Date.now()) {
  const sessions = new Map();
  let jwt = null;
  let jwtAt = 0;

  function providerToken() {
    if (!jwt || now() - jwtAt >= TOKEN_LIFETIME_MS) {
      jwt = signToken(config, Math.floor(now() / 1000));
      jwtAt = now();
    }
    return jwt;
  }

  function session(environment) {
    const existing = sessions.get(environment);
    if (existing && !existing.closed && !existing.destroyed) return existing;
    const created = http2.connect(HOSTS[environment]);
    created.on("error", () => sessions.delete(environment));
    created.on("close", () => sessions.delete(environment));
    created.unref();
    sessions.set(environment, created);
    return created;
  }

  function send(deviceToken, environment, notification) {
    if (!HOSTS[environment]) return Promise.resolve({ ok: false, status: 0, reason: "bad_environment", gone: false });
    return new Promise(resolve => {
      let done = false;
      const finish = result => { if (!done) { done = true; resolve(result); } };
      try {
        const request = session(environment).request({
          ":method": "POST",
          ":path": `/3/device/${deviceToken}`,
          authorization: `bearer ${providerToken()}`,
          "apns-topic": config.topic,
          "apns-push-type": "alert",
          "apns-priority": notification.priority === "low" ? "5" : "10",
          "apns-expiration": String(Math.floor(now() / 1000) + (notification.ttlSeconds ?? 3600)),
          ...(notification.collapseId ? { "apns-collapse-id": notification.collapseId.slice(0, 64) } : {}),
          "content-type": "application/json"
        });
        let status = 0;
        let body = "";
        request.setEncoding("utf8");
        request.on("response", headers => { status = headers[":status"]; });
        request.on("data", chunk => { body += chunk; });
        request.on("end", () => {
          if (status === 200) return finish({ ok: true });
          let reason = "unknown";
          try { reason = JSON.parse(body).reason || reason; } catch { /* an empty body */ }
          // 410 = no longer registered; 400 BadDeviceToken / DeviceTokenNotForTopic = wrong environment or app.
          const gone = status === 410 || (status === 400 && ["BadDeviceToken", "DeviceTokenNotForTopic"].includes(reason));
          finish({ ok: false, status, reason, gone });
        });
        request.on("error", error => finish({ ok: false, status: 0, reason: error.code || "network", gone: false }));
        request.setTimeout(10_000, () => { request.close(); finish({ ok: false, status: 0, reason: "timeout", gone: false }); });
        request.end(JSON.stringify(notification.payload));
      } catch (error) {
        finish({ ok: false, status: 0, reason: error.code || "network", gone: false });
      }
    });
  }

  send.close = () => { for (const s of sessions.values()) s.destroy(); sessions.clear(); };
  return send;
}

module.exports = { signToken, apnsConfig, createApnsSender };
