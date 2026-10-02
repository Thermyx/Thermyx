// Prototype persistence for the Thermyx relay: one SQLite file through Node's
// built-in driver (Node 22.5+). This is a competition prototype, not durable
// production infrastructure: it needs a persistent disk, backups if hosted,
// and the retention job below running.
//
// Secrets are never stored in the clear. Device tokens and pairing codes are
// kept only as SHA-256 hashes, and nothing here holds phone numbers or sensor
// readings.
const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");
const { DatabaseSync } = require("node:sqlite");

const SCHEMA_VERSION = 2;

// Lifetimes.
const CODE_TTL_MS = 10 * 60_000;                 // pairing codes: 10 minutes, single use
const WEARER_TOKEN_TTL_MS = 365 * 24 * 3_600_000; // wearer device token: 1 year
const WATCHER_TTL_MS = 90 * 24 * 3_600_000;       // watcher access: 90 days, renewable
const LOCATION_TTL_MS = 60 * 60_000;              // shared location: 1 hour at most
const AUDIT_RETENTION_MS = 30 * 24 * 3_600_000;
const STATUS_RETENTION_MS = 7 * 24 * 3_600_000;
const CONTACT_CODE_TTL_MS = 10 * 60_000;          // contact confirmation codes: 10 minutes
const CONTACT_CODE_ATTEMPTS = 5;

// Codes: 8 characters from an alphabet without look-alikes (no 0/O, 1/I/L).
const CODE_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789";
const DEVICE_ALPHABET = "abcdefghjkmnpqrstuvwxyz23456789";

const sha256 = value => crypto.createHash("sha256").update(value).digest("hex");

function randomFrom(alphabet, length) {
  const bytes = crypto.randomBytes(length);
  let out = "";
  for (let i = 0; i < length; i++) out += alphabet[bytes[i] % alphabet.length];
  return out;
}

const normaliseCode = code => String(code || "").toUpperCase().replace(/[^A-Z0-9]/g, "");
const formatCode = code => `${code.slice(0, 4)}-${code.slice(4)}`;

function openStore(file, now = () => Date.now()) {
  if (file !== ":memory:") fs.mkdirSync(path.dirname(file), { recursive: true });
  const db = new DatabaseSync(file);
  db.exec("PRAGMA journal_mode = WAL; PRAGMA foreign_keys = ON;");
  migrate(db);

  const iso = ms => new Date(ms).toISOString();

  function audit(actor, action, subject = null) {
    db.prepare("INSERT INTO audit (at, actor, action, subject) VALUES (?, ?, ?, ?)").run(now(), actor, action, subject);
  }

  function issueToken(role, deviceID, watcherID, ttl) {
    const token = crypto.randomBytes(32).toString("base64url");
    db.prepare("INSERT INTO tokens (hash, role, device_id, watcher_id, created_at, expires_at) VALUES (?, ?, ?, ?, ?, ?)")
      .run(sha256(token), role, deviceID, watcherID, now(), now() + ttl);
    return token;
  }

  function createCode(role, deviceID, actor) {
    const code = randomFrom(CODE_ALPHABET, 8);
    db.prepare("INSERT INTO pairing_codes (hash, role, device_id, created_by, created_at, expires_at) VALUES (?, ?, ?, ?, ?, ?)")
      .run(sha256(code), role, deviceID, actor, now(), now() + CODE_TTL_MS);
    audit(actor, `create_${role}_code`, deviceID);
    return { code: formatCode(code), expiresAt: iso(now() + CODE_TTL_MS) };
  }

  return {
    db,

    /** Admin only (CLI): a code a new wearer's phone redeems once. */
    createWearerCode() {
      return createCode("wearer", null, "admin");
    },

    /** A wearer invites a watcher. The watcher still needs approval. */
    createWatcherCode(deviceID) {
      return createCode("watcher", deviceID, `wearer:${deviceID}`);
    },

    /** Redeems a code exactly once. Returns null for unknown, used, or expired codes. */
    redeemCode(rawCode, watcherName) {
      const hash = sha256(normaliseCode(rawCode));
      const row = db.prepare("SELECT * FROM pairing_codes WHERE hash = ?").get(hash);
      if (!row || row.used_at || row.expires_at <= now()) {
        audit("anonymous", "redeem_code_rejected", row ? row.role : null);
        return null;
      }
      // Mark used first, guarded, so two simultaneous redemptions cannot both win.
      const claimed = db.prepare("UPDATE pairing_codes SET used_at = ? WHERE hash = ? AND used_at IS NULL").run(now(), hash);
      if (claimed.changes !== 1) return null;

      if (row.role === "wearer") {
        let deviceID;
        do { deviceID = `thermyx-${randomFrom(DEVICE_ALPHABET, 6)}`; }
        while (db.prepare("SELECT 1 FROM devices WHERE id = ?").get(deviceID));
        db.prepare("INSERT INTO devices (id, created_at) VALUES (?, ?)").run(deviceID, now());
        const token = issueToken("wearer", deviceID, null, WEARER_TOKEN_TTL_MS);
        audit(`wearer:${deviceID}`, "paired_wearer", deviceID);
        return { role: "wearer", deviceID, token };
      }

      const watcherID = crypto.randomUUID();
      const name = String(watcherName || "Unnamed watcher").trim().slice(0, 60) || "Unnamed watcher";
      db.prepare("INSERT INTO watchers (id, device_id, name, status, created_at) VALUES (?, ?, ?, 'pending', ?)")
        .run(watcherID, row.device_id, name, now());
      const token = issueToken("watcher", row.device_id, watcherID, WATCHER_TTL_MS);
      audit(`watcher:${watcherID}`, "paired_watcher_pending", row.device_id);
      return { role: "watcher", watcherID, token, status: "pending" };
    },

    /** Resolves a bearer token to its identity, or null if unknown, expired, or revoked. */
    authenticate(token) {
      if (!token) return null;
      const row = db.prepare("SELECT * FROM tokens WHERE hash = ?").get(sha256(token));
      if (!row || row.revoked_at || row.expires_at <= now()) return null;
      return { role: row.role, deviceID: row.device_id, watcherID: row.watcher_id };
    },

    listWatchers(deviceID) {
      return db.prepare("SELECT id, name, status, created_at, approved_at, expires_at FROM watchers WHERE device_id = ? AND status != 'revoked' ORDER BY created_at")
        .all(deviceID)
        .map(w => ({
          id: w.id,
          name: w.name,
          status: w.status === "approved" && w.expires_at <= now() ? "expired" : w.status,
          createdAt: iso(w.created_at),
          approvedAt: w.approved_at ? iso(w.approved_at) : null,
          expiresAt: w.expires_at ? iso(w.expires_at) : null
        }));
    },

    /** Approves (or renews) a watcher for another 90 days. */
    approveWatcher(deviceID, watcherID) {
      const result = db.prepare("UPDATE watchers SET status = 'approved', approved_at = ?, expires_at = ? WHERE id = ? AND device_id = ? AND status != 'revoked'")
        .run(now(), now() + WATCHER_TTL_MS, watcherID, deviceID);
      if (result.changes !== 1) return false;
      db.prepare("UPDATE tokens SET expires_at = ? WHERE watcher_id = ? AND revoked_at IS NULL").run(now() + WATCHER_TTL_MS, watcherID);
      audit(`wearer:${deviceID}`, "approve_watcher", watcherID);
      return true;
    },

    /** Removes a watcher's access immediately. */
    revokeWatcher(deviceID, watcherID) {
      const result = db.prepare("UPDATE watchers SET status = 'revoked', revoked_at = ? WHERE id = ? AND device_id = ? AND status != 'revoked'")
        .run(now(), watcherID, deviceID);
      if (result.changes !== 1) return false;
      db.prepare("UPDATE tokens SET revoked_at = ? WHERE watcher_id = ?").run(now(), watcherID);
      audit(`wearer:${deviceID}`, "revoke_watcher", watcherID);
      return true;
    },

    leaveAsWatcher(watcherID) {
      db.prepare("UPDATE watchers SET status = 'revoked', revoked_at = ? WHERE id = ? AND status != 'revoked'").run(now(), watcherID);
      db.prepare("UPDATE tokens SET revoked_at = ? WHERE watcher_id = ? AND revoked_at IS NULL").run(now(), watcherID);
      audit(`watcher:${watcherID}`, "watcher_left", watcherID);
    },

    watcherState(watcherID) {
      return db.prepare("SELECT status, expires_at FROM watchers WHERE id = ?").get(watcherID);
    },

    /**
     * Records the wearer's current state. Location is kept only when the
     * wearer consented and a safety event is active, and only for an hour.
     */
    updateStatus(deviceID, { level, kind, location, locationConsent }) {
      const activeEvent = kind === "sos" || level === "High risk" || level === "Critical";
      const consented = Boolean(locationConsent);
      const previous = db.prepare("SELECT lat, lon, accuracy_m, location_expires_at FROM status WHERE device_id = ?").get(deviceID);

      let loc = { lat: null, lon: null, acc: null, exp: null };
      if (activeEvent && consented && location) {
        loc = {
          lat: location.latitude, lon: location.longitude,
          acc: typeof location.accuracyM === "number" ? location.accuracyM : null,
          exp: now() + LOCATION_TTL_MS
        };
      } else if (activeEvent && consented && previous && previous.lat != null && previous.location_expires_at > now()) {
        // Same event, no fresh fix this time: keep the earlier one until it expires.
        loc = { lat: previous.lat, lon: previous.lon, acc: previous.accuracy_m, exp: previous.location_expires_at };
      }
      // Anything else (event over, consent withdrawn) clears the location.

      db.prepare(`INSERT INTO status (device_id, level, kind, updated_at, lat, lon, accuracy_m, location_expires_at)
                  VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                  ON CONFLICT(device_id) DO UPDATE SET level = excluded.level, kind = excluded.kind,
                    updated_at = excluded.updated_at, lat = excluded.lat, lon = excluded.lon,
                    accuracy_m = excluded.accuracy_m, location_expires_at = excluded.location_expires_at`)
        .run(deviceID, level, kind, now(), loc.lat, loc.lon, loc.acc, loc.exp);
    },

    /** The minimal view a watcher gets: state, kind, freshness, and an active-event location. */
    watcherView(deviceID) {
      const row = db.prepare("SELECT * FROM status WHERE device_id = ?").get(deviceID);
      if (!row) return null;
      const view = { level: row.level, kind: row.kind, updatedAt: iso(row.updated_at) };
      if (row.lat != null && row.location_expires_at > now()) {
        view.location = { latitude: row.lat, longitude: row.lon, accuracyM: row.accuracy_m, expiresAt: iso(row.location_expires_at) };
      }
      return view;
    },

    lastText(deviceID) {
      return db.prepare("SELECT severity, at FROM sms_log WHERE device_id = ? AND delivered > 0 AND kind = 'alert' ORDER BY at DESC LIMIT 1").get(deviceID);
    },

    clearLastText(deviceID) {
      db.prepare("DELETE FROM sms_log WHERE device_id = ? AND kind = 'alert'").run(deviceID);
    },

    recordText(deviceID, kind, severity, delivered, failed) {
      db.prepare("INSERT INTO sms_log (device_id, kind, severity, at, delivered, failed) VALUES (?, ?, ?, ?, ?, ?)")
        .run(deviceID, kind, severity, now(), delivered, failed);
      audit(`wearer:${deviceID}`, "sms_attempt", `${kind}: ${delivered} delivered, ${failed} failed`);
    },

    revokeDevice(deviceID, actor = "admin") {
      const result = db.prepare("UPDATE tokens SET revoked_at = ? WHERE device_id = ? AND revoked_at IS NULL").run(now(), deviceID);
      db.prepare("UPDATE watchers SET status = 'revoked', revoked_at = ? WHERE device_id = ? AND status != 'revoked'").run(now(), deviceID);
      db.prepare("DELETE FROM status WHERE device_id = ?").run(deviceID);
      db.prepare("DELETE FROM contact_checks WHERE device_id = ?").run(deviceID);
      audit(actor, "revoke_device", deviceID);
      return result.changes;
    },

    listDevices() {
      return db.prepare(`SELECT d.id, d.created_at,
          (SELECT COUNT(*) FROM watchers w WHERE w.device_id = d.id AND w.status = 'approved') AS watchers,
          (SELECT updated_at FROM status s WHERE s.device_id = d.id) AS last_update
        FROM devices d ORDER BY d.created_at`).all()
        .map(d => ({ id: d.id, createdAt: iso(d.created_at), approvedWatchers: d.watchers, lastUpdate: d.last_update ? iso(d.last_update) : null }));
    },

    auditTrail(limit = 50) {
      return db.prepare("SELECT at, actor, action, subject FROM audit ORDER BY id DESC LIMIT ?").all(limit)
        .map(a => ({ ...a, at: iso(a.at) }));
    },

    /** Deletes what is no longer needed. Runs on start and every ten minutes. */
    purgeExpired() {
      const t = now();
      db.prepare("DELETE FROM pairing_codes WHERE expires_at < ?").run(t - 24 * 3_600_000);
      db.prepare("UPDATE status SET lat = NULL, lon = NULL, accuracy_m = NULL, location_expires_at = NULL WHERE location_expires_at IS NOT NULL AND location_expires_at <= ?").run(t);
      db.prepare("DELETE FROM status WHERE updated_at < ?").run(t - STATUS_RETENTION_MS);
      db.prepare("DELETE FROM audit WHERE at < ?").run(t - AUDIT_RETENTION_MS);
      db.prepare("DELETE FROM sms_log WHERE at < ?").run(t - AUDIT_RETENTION_MS);
      db.prepare("DELETE FROM contact_checks WHERE expires_at < ?").run(t);
      db.prepare("DELETE FROM tokens WHERE expires_at < ? OR revoked_at < ?").run(t - AUDIT_RETENTION_MS, t - AUDIT_RETENTION_MS);
    },

    /** Starts a contact confirmation; returns the 6-digit code to text. */
    createContactCheck(deviceID, phone) {
      const code = String(crypto.randomInt(0, 1_000_000)).padStart(6, "0");
      db.prepare(`INSERT INTO contact_checks (device_id, phone_hash, code_hash, created_at, expires_at, attempts)
        VALUES (?, ?, ?, ?, ?, 0)
        ON CONFLICT (device_id, phone_hash) DO UPDATE SET code_hash = excluded.code_hash,
          created_at = excluded.created_at, expires_at = excluded.expires_at, attempts = 0`)
        .run(deviceID, sha256(`${deviceID}:${phone}`), sha256(`${deviceID}:${code}`), now(), now() + CONTACT_CODE_TTL_MS);
      audit(`wearer:${deviceID}`, "contact_check_sent", null);
      return code;
    },

    /** "confirmed", "wrong", or "expired" (also after too many attempts). */
    confirmContact(deviceID, phone, code) {
      const key = sha256(`${deviceID}:${phone}`);
      const row = db.prepare("SELECT * FROM contact_checks WHERE device_id = ? AND phone_hash = ?").get(deviceID, key);
      if (!row || row.expires_at <= now() || row.attempts >= CONTACT_CODE_ATTEMPTS) {
        if (row) db.prepare("DELETE FROM contact_checks WHERE device_id = ? AND phone_hash = ?").run(deviceID, key);
        return "expired";
      }
      if (row.code_hash !== sha256(`${deviceID}:${String(code || "").replace(/\D/g, "")}`)) {
        db.prepare("UPDATE contact_checks SET attempts = attempts + 1 WHERE device_id = ? AND phone_hash = ?").run(deviceID, key);
        return "wrong";
      }
      db.prepare("DELETE FROM contact_checks WHERE device_id = ? AND phone_hash = ?").run(deviceID, key);
      audit(`wearer:${deviceID}`, "contact_confirmed", null);
      return "confirmed";
    },

    close() { db.close(); }
  };
}

/// Schema migrations, applied in order and recorded in `schema_version`.
function migrate(db) {
  db.exec("CREATE TABLE IF NOT EXISTS schema_version (version INTEGER NOT NULL)");
  const current = db.prepare("SELECT MAX(version) AS v FROM schema_version").get().v || 0;
  if (current < 1) {
    db.exec(`
      CREATE TABLE devices (id TEXT PRIMARY KEY, created_at INTEGER NOT NULL);
      CREATE TABLE tokens (
        hash TEXT PRIMARY KEY, role TEXT NOT NULL CHECK (role IN ('wearer','watcher')),
        device_id TEXT NOT NULL, watcher_id TEXT,
        created_at INTEGER NOT NULL, expires_at INTEGER NOT NULL, revoked_at INTEGER);
      CREATE TABLE pairing_codes (
        hash TEXT PRIMARY KEY, role TEXT NOT NULL CHECK (role IN ('wearer','watcher')),
        device_id TEXT, created_by TEXT NOT NULL,
        created_at INTEGER NOT NULL, expires_at INTEGER NOT NULL, used_at INTEGER);
      CREATE TABLE watchers (
        id TEXT PRIMARY KEY, device_id TEXT NOT NULL, name TEXT NOT NULL,
        status TEXT NOT NULL CHECK (status IN ('pending','approved','revoked')),
        created_at INTEGER NOT NULL, approved_at INTEGER, expires_at INTEGER, revoked_at INTEGER);
      CREATE TABLE status (
        device_id TEXT PRIMARY KEY, level TEXT NOT NULL, kind TEXT NOT NULL, updated_at INTEGER NOT NULL,
        lat REAL, lon REAL, accuracy_m REAL, location_expires_at INTEGER);
      CREATE TABLE sms_log (
        id INTEGER PRIMARY KEY AUTOINCREMENT, device_id TEXT NOT NULL, kind TEXT NOT NULL,
        severity INTEGER NOT NULL, at INTEGER NOT NULL, delivered INTEGER NOT NULL, failed INTEGER NOT NULL);
      CREATE TABLE audit (
        id INTEGER PRIMARY KEY AUTOINCREMENT, at INTEGER NOT NULL,
        actor TEXT NOT NULL, action TEXT NOT NULL, subject TEXT);
      CREATE INDEX watchers_by_device ON watchers (device_id);
      CREATE INDEX tokens_by_watcher ON tokens (watcher_id);
      INSERT INTO schema_version (version) VALUES (1);
    `);
  }
  if ((db.prepare("SELECT MAX(version) AS v FROM schema_version").get().v || 0) < 2) {
    // Contact confirmation codes. The number is stored only as a hash salted
    // with the device ID, and the row is deleted once confirmed or expired.
    db.exec(`
      CREATE TABLE contact_checks (
        device_id TEXT NOT NULL, phone_hash TEXT NOT NULL, code_hash TEXT NOT NULL,
        created_at INTEGER NOT NULL, expires_at INTEGER NOT NULL, attempts INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (device_id, phone_hash));
      INSERT INTO schema_version (version) VALUES (2);
    `);
  }
  if ((db.prepare("SELECT MAX(version) AS v FROM schema_version").get().v || 0) !== SCHEMA_VERSION) {
    throw new Error("Unexpected database schema version");
  }
}

module.exports = { openStore, normaliseCode, CODE_TTL_MS, WATCHER_TTL_MS, LOCATION_TTL_MS };
