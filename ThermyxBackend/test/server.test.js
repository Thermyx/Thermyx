const test = require("node:test");
const assert = require("node:assert");
const { createRelay, normalisePhone, composeMessage } = require("../server.js");
const { openStore } = require("../store.js");

async function start({ env = {}, sendSMS } = {}) {
  let clock = 1_800_000_000_000;
  const now = () => clock;
  const store = openStore(":memory:", now);
  const sent = [];
  const relay = createRelay({
    env, store, now,
    sendSMS: sendSMS || (async (to, body) => { sent.push({ to, body }); })
  });
  await new Promise(resolve => relay.server.listen(0, resolve));
  const base = `http://127.0.0.1:${relay.server.address().port}`;
  const call = async (method, path, { token, body } = {}) => {
    const response = await fetch(base + path, {
      method,
      headers: { "Content-Type": "application/json", ...(token ? { Authorization: `Bearer ${token}` } : {}) },
      body: body === undefined ? undefined : typeof body === "string" ? body : JSON.stringify(body)
    });
    return { status: response.status, body: await response.json() };
  };
  return {
    store, sent, call,
    advance: ms => { clock += ms; },
    close: () => new Promise(resolve => relay.server.close(resolve))
  };
}

/** Pairs a wearer and an approved watcher; returns both tokens. */
async function pairBoth(r, { approve = true } = {}) {
  const { code } = r.store.createWearerCode();
  const wearer = (await r.call("POST", "/v1/pair", { body: { code } })).body;
  const invite = (await r.call("POST", "/v1/watchers/codes", { token: wearer.token })).body;
  const watcher = (await r.call("POST", "/v1/pair", { body: { code: invite.code, name: "Casey" } })).body;
  if (approve) await r.call("POST", `/v1/watchers/${watcher.watcherID}/approve`, { token: wearer.token });
  return { wearer, watcher };
}

test("wearer codes work once and expire after 10 minutes", async () => {
  const r = await start();
  try {
    const { code } = r.store.createWearerCode();
    const first = await r.call("POST", "/v1/pair", { body: { code: code.toLowerCase() } });
    assert.equal(first.status, 200);
    assert.equal(first.body.role, "wearer");
    assert.match(first.body.deviceID, /^thermyx-[a-z2-9]{6}$/);
    assert.ok(first.body.token.length >= 40);
    assert.equal((await r.call("POST", "/v1/pair", { body: { code } })).status, 403, "single use");

    const stale = r.store.createWearerCode();
    r.advance(10 * 60_000 + 1);
    assert.equal((await r.call("POST", "/v1/pair", { body: { code: stale.code } })).status, 403, "expired");
  } finally { await r.close(); }
});

test("tokens and codes are stored only as hashes", async () => {
  const r = await start();
  try {
    const { code } = r.store.createWearerCode();
    const { token } = (await r.call("POST", "/v1/pair", { body: { code } })).body;
    const dump = JSON.stringify([
      r.store.db.prepare("SELECT * FROM tokens").all(),
      r.store.db.prepare("SELECT * FROM pairing_codes").all()
    ]);
    assert.ok(!dump.includes(token));
    assert.ok(!dump.includes(code.replace("-", "")));
  } finally { await r.close(); }
});

test("a watcher sees nothing until the wearer approves them", async () => {
  const r = await start();
  try {
    const { wearer, watcher } = await pairBoth(r, { approve: false });
    assert.equal(watcher.status, "pending");
    await r.call("POST", "/v1/events", { token: wearer.token, body: { level: "Caution", kind: "status" } });
    assert.deepEqual((await r.call("GET", "/v1/watch", { token: watcher.token })).body, { status: "pending" });

    const list = (await r.call("GET", "/v1/watchers", { token: wearer.token })).body.watchers;
    assert.equal(list.length, 1);
    assert.equal(list[0].name, "Casey");
    assert.equal(list[0].status, "pending");

    await r.call("POST", `/v1/watchers/${watcher.watcherID}/approve`, { token: wearer.token });
    const view = (await r.call("GET", "/v1/watch", { token: watcher.token })).body;
    assert.equal(view.status, "approved");
    assert.equal(view.state.level, "Caution");
  } finally { await r.close(); }
});

test("watchers get only level, kind, and freshness — no readings, reasons, or numbers", async () => {
  const r = await start();
  try {
    const { wearer, watcher } = await pairBoth(r);
    await r.call("POST", "/v1/events", {
      token: wearer.token,
      body: { level: "Caution", kind: "alert", reasons: ["Ambient temperature is elevated."], recipients: ["+12025550148"], readings: { footTemperatureC: 37 } }
    });
    const { state } = (await r.call("GET", "/v1/watch", { token: watcher.token })).body;
    assert.deepEqual(Object.keys(state).sort(), ["kind", "level", "updatedAt"]);
  } finally { await r.close(); }
});

test("location is shared only during a consented active event, and expires", async () => {
  const r = await start();
  try {
    const { wearer, watcher } = await pairBoth(r);
    const location = { latitude: 29.7604, longitude: -95.3698, accuracyM: 30 };
    const view = async () => (await r.call("GET", "/v1/watch", { token: watcher.token })).body.state;

    await r.call("POST", "/v1/events", { token: wearer.token, body: { level: "High risk", kind: "alert", location } });
    assert.equal((await view()).location, undefined, "no consent, no location");

    await r.call("POST", "/v1/events", { token: wearer.token, body: { level: "Caution", kind: "alert", location, locationConsent: true } });
    assert.equal((await view()).location, undefined, "Caution is not an active safety event");

    await r.call("POST", "/v1/events", { token: wearer.token, body: { level: "High risk", kind: "alert", location, locationConsent: true } });
    assert.equal((await view()).location.latitude, 29.7604);

    r.advance(61 * 60_000);
    r.store.purgeExpired();
    assert.equal((await view()).location, undefined, "expires after an hour");

    await r.call("POST", "/v1/events", { token: wearer.token, body: { level: "Critical", kind: "sos", location, locationConsent: true } });
    await r.call("POST", "/v1/events", { token: wearer.token, body: { level: "Normal", kind: "ok", locationConsent: true } });
    assert.equal((await view()).location, undefined, "cleared when the event ends");
  } finally { await r.close(); }
});

test("revoking a watcher cuts access immediately", async () => {
  const r = await start();
  try {
    const { wearer, watcher } = await pairBoth(r);
    assert.equal((await r.call("DELETE", `/v1/watchers/${watcher.watcherID}`, { token: wearer.token })).status, 200);
    assert.equal((await r.call("GET", "/v1/watch", { token: watcher.token })).status, 401);
    assert.equal((await r.call("GET", "/v1/watchers", { token: wearer.token })).body.watchers.length, 0);
  } finally { await r.close(); }
});

test("a wearer can delete their relay data; a watcher can leave", async () => {
  const r = await start();
  try {
    const { wearer, watcher } = await pairBoth(r);
    const second = await pairBoth(r);
    assert.equal((await r.call("DELETE", "/v1/watch", { token: second.watcher.token })).status, 200);
    assert.equal((await r.call("GET", "/v1/watch", { token: second.watcher.token })).status, 401);

    await r.call("POST", "/v1/events", { token: wearer.token, body: { level: "High risk", kind: "alert", locationConsent: true, location: { latitude: 1, longitude: 2 } } });
    assert.equal((await r.call("DELETE", "/v1/device", { token: wearer.token })).status, 200);
    assert.equal((await r.call("GET", "/v1/watchers", { token: wearer.token })).status, 401);
    assert.equal((await r.call("GET", "/v1/watch", { token: watcher.token })).status, 401);
    assert.equal(r.store.watcherView(wearer.deviceID), null);
    // Another wearer is untouched, and a watcher token cannot delete a device.
    assert.equal((await r.call("GET", "/v1/watchers", { token: second.wearer.token })).status, 200);
  } finally { await r.close(); }
});

test("watcher access expires after 90 days unless renewed", async () => {
  const r = await start();
  try {
    const { wearer, watcher } = await pairBoth(r);
    r.advance(89 * 24 * 3_600_000);
    await r.call("POST", `/v1/watchers/${watcher.watcherID}/approve`, { token: wearer.token }); // renew
    r.advance(30 * 24 * 3_600_000);
    assert.equal((await r.call("GET", "/v1/watch", { token: watcher.token })).status, 200, "renewed");
    r.advance(61 * 24 * 3_600_000);
    assert.equal((await r.call("GET", "/v1/watch", { token: watcher.token })).status, 401, "expired");
  } finally { await r.close(); }
});

test("roles are enforced: watchers cannot post events or manage watchers", async () => {
  const r = await start();
  try {
    const { wearer, watcher } = await pairBoth(r);
    assert.equal((await r.call("POST", "/v1/events", { token: watcher.token, body: { level: "Critical" } })).status, 403);
    assert.equal((await r.call("POST", "/v1/watchers/codes", { token: watcher.token })).status, 403);
    assert.equal((await r.call("GET", "/v1/watchers", { token: watcher.token })).status, 403);
    // One wearer cannot touch another wearer's watchers.
    const other = (await r.call("POST", "/v1/pair", { body: { code: r.store.createWearerCode().code } })).body;
    assert.equal((await r.call("DELETE", `/v1/watchers/${watcher.watcherID}`, { token: other.token })).status, 404);
    assert.equal((await r.call("GET", "/v1/watch", { token: watcher.token })).status, 200);
    assert.equal((await r.call("GET", "/v1/watchers", { token: "nonsense" })).status, 401);
    void wearer;
  } finally { await r.close(); }
});

test("invalid events are rejected", async () => {
  const r = await start();
  try {
    const { wearer } = await pairBoth(r);
    const post = body => r.call("POST", "/v1/events", { token: wearer.token, body });
    assert.deepEqual((await post("null")).body, { error: "invalid_body" });
    assert.deepEqual((await post("not json")).body, { error: "invalid_json" });
    assert.deepEqual((await post({ level: "Hot" })).body, { error: "invalid_level" });
    assert.deepEqual((await post({ level: "Caution", kind: "x" })).body, { error: "invalid_kind" });
    assert.deepEqual((await post({ level: "Caution", location: { latitude: 200, longitude: 0 } })).body, { error: "invalid_location" });
  } finally { await r.close(); }
});

test("texting is off by default and says so", async () => {
  const r = await start();
  try {
    const { wearer } = await pairBoth(r);
    const res = await r.call("POST", "/v1/events", { token: wearer.token, body: { level: "Critical", kind: "sos", recipients: ["+12025550148"] } });
    assert.equal(res.body.reason, "sms_disabled");
    assert.equal(r.sent.length, 0);
  } finally { await r.close(); }
});

test("with texting on: once per level, again on escalation, reminders after the gap", async () => {
  const r = await start({ env: { SMS_ENABLED: "true" } });
  try {
    const { wearer } = await pairBoth(r);
    const post = body => r.call("POST", "/v1/events", { token: wearer.token, body: { recipients: ["(202) 555-0148"], ...body } });
    await post({ level: "High risk" });
    await post({ level: "High risk" });
    assert.equal(r.sent.length, 1);
    await post({ level: "Critical" });
    assert.equal(r.sent.length, 2);
    r.advance(5 * 60_000);
    await post({ level: "Critical" });
    assert.equal(r.sent.length, 3);
    await post({ level: "Normal", kind: "status" });
    await post({ level: "Normal" });
    await post({ level: "Caution" });
    assert.equal(r.sent.length, 4, "back to Normal resets, so the next rise texts at once");
    assert.equal(r.sent[0].to, "+12025550148");
  } finally { await r.close(); }
});

test("pairing attempts are rate-limited per address", async () => {
  const r = await start();
  try {
    let last;
    for (let i = 0; i < 11; i++) last = await r.call("POST", "/v1/pair", { body: { code: "AAAA-AAAA" } });
    assert.equal(last.status, 429);
  } finally { await r.close(); }
});

test("audit trail records codes, pairing, approval, and revocation without secrets", async () => {
  const r = await start();
  try {
    const { wearer, watcher } = await pairBoth(r);
    await r.call("DELETE", `/v1/watchers/${watcher.watcherID}`, { token: wearer.token });
    const actions = r.store.auditTrail(20).map(a => a.action);
    for (const action of ["create_wearer_code", "paired_wearer", "create_watcher_code", "paired_watcher_pending", "approve_watcher", "revoke_watcher"]) {
      assert.ok(actions.includes(action), action);
    }
    assert.ok(!JSON.stringify(r.store.auditTrail(50)).includes(wearer.token));
  } finally { await r.close(); }
});

test("phone normalisation and message text", () => {
  assert.equal(normalisePhone("(202) 555-0148"), "+12025550148");
  assert.equal(normalisePhone("+44 20 7946 0958"), "+442079460958");
  assert.equal(normalisePhone("12"), null);
  assert.match(composeMessage({ level: "High risk", reasons: ["Hot."] }, "thermyx-ab12cd"), /Thermyx High risk on thermyx-ab12cd\. Hot\./);
  assert.doesNotMatch(composeMessage({ level: "High risk", location: { latitude: 1, longitude: 2 } }, "d"), /maps/, "no location without consent");
});
