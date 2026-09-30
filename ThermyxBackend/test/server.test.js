const test = require("node:test");
const assert = require("node:assert");
const os = require("node:os");
const fs = require("node:fs");
const path = require("node:path");
const { createRelay, normalisePhone, composeMessage } = require("../server.js");

function start(extraEnv = {}, options = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "thermyx-"));
  const sent = [];
  let clock = 1_000_000;
  const relay = createRelay({
    env: { THERMYX_TOKEN: "secret", STATUS_FILE: path.join(dir, "status.json"), ...extraEnv },
    sendSMS: options.sendSMS || (async (to, body) => { sent.push({ to, body }); }),
    now: () => clock
  });
  return new Promise(resolve => {
    relay.server.listen(0, () => {
      const base = `http://127.0.0.1:${relay.server.address().port}`;
      resolve({
        base, sent, dir, relay,
        advance: ms => { clock += ms; },
        close: () => new Promise(r => relay.server.close(r))
      });
    });
  });
}

async function post(base, body, token = "secret") {
  const response = await fetch(`${base}/v1/alerts`, {
    method: "POST",
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: typeof body === "string" ? body : JSON.stringify(body)
  });
  return { status: response.status, body: await response.json() };
}

const alert = (level, extra = {}) => ({ deviceID: "thermyx-abc123", level, recipients: ["+1 (202) 555-0148"], reasons: ["Test."], ...extra });

test("refuses to start without a token", () => {
  assert.throws(() => createRelay({ env: {} }), /THERMYX_TOKEN/);
});

test("rejects bad auth, bad bodies, missing device IDs", async () => {
  const r = await start();
  try {
    assert.equal((await post(r.base, alert("Caution"), "wrong")).status, 401);
    assert.equal((await post(r.base, alert("Caution"), "undefined")).status, 401);
    assert.deepEqual((await post(r.base, "null")).body, { error: "invalid_body" });
    assert.deepEqual((await post(r.base, "not json")).body, { error: "invalid_json" });
    assert.deepEqual((await post(r.base, { level: "Caution" })).body, { error: "invalid_device_id" });
    assert.deepEqual((await post(r.base, alert("Hot"))).body, { error: "invalid_level" });
    assert.equal(r.sent.length, 0);
  } finally { await r.close(); }
});

test("status heartbeats are stored but never text anyone", async () => {
  const r = await start();
  try {
    const res = await post(r.base, alert("Normal", { kind: "status" }));
    assert.equal(res.status, 202);
    assert.equal(r.sent.length, 0);
    const status = await (await fetch(`${r.base}/v1/status/thermyx-abc123`, { headers: { Authorization: "Bearer secret" } })).json();
    assert.equal(status.event.level, "Normal");
    assert.equal(status.event.recipients, undefined, "phone numbers are not echoed to watchers");
  } finally { await r.close(); }
});

test("texts once per level, again on escalation, again after the reminder gap", async () => {
  const r = await start();
  try {
    await post(r.base, alert("High risk"));
    await post(r.base, alert("High risk"));
    await post(r.base, alert("High risk"));
    assert.equal(r.sent.length, 1, "repeat events at the same level are throttled");
    await post(r.base, alert("Critical"));
    assert.equal(r.sent.length, 2, "escalation texts immediately");
    r.advance(5 * 60_000);
    await post(r.base, alert("Critical"));
    assert.equal(r.sent.length, 3, "reminder after five minutes");
    assert.equal(r.sent[0].to, "+12025550148");
  } finally { await r.close(); }
});

test("SOS and I'm OK always go out, with a map link when location is given", async () => {
  const r = await start();
  try {
    await post(r.base, alert("Critical", { kind: "sos", location: { latitude: 29.7604, longitude: -95.3698 } }));
    await post(r.base, alert("Normal", { kind: "ok" }));
    assert.equal(r.sent.length, 2);
    assert.match(r.sent[0].body, /maps\.google\.com\/\?q=29\.76040,-95\.36980/);
    assert.match(r.sent[1].body, /checked in/);
  } finally { await r.close(); }
});

test("status survives a restart", async () => {
  const r = await start();
  await post(r.base, alert("Caution", { kind: "status" }));
  await r.close();
  const again = createRelay({ env: { THERMYX_TOKEN: "secret", STATUS_FILE: path.join(r.dir, "status.json") } });
  assert.equal(again.latestEvents.get("thermyx-abc123").level, "Caution");
});

test("per-device tokens lock a device to its own token", async () => {
  const r = await start({ THERMYX_DEVICE_TOKENS: JSON.stringify({ "thermyx-abc123": "device-token" }) });
  try {
    assert.equal((await post(r.base, alert("Caution"), "secret")).status, 401);
    assert.equal((await post(r.base, alert("Caution"), "device-token")).status, 202);
    const res = await fetch(`${r.base}/v1/status/thermyx-abc123`, { headers: { Authorization: "Bearer secret" } });
    assert.equal(res.status, 401);
  } finally { await r.close(); }
});

test("a failed send is retried once", async () => {
  let calls = 0;
  const r = await start({}, { sendSMS: async () => { calls += 1; if (calls === 1) throw new Error("flaky"); } });
  try {
    const res = await post(r.base, alert("High risk"));
    assert.equal(res.body.delivered, 1);
    assert.equal(calls, 2);
  } finally { await r.close(); }
});

test("phone normalisation and message text", () => {
  assert.equal(normalisePhone("(202) 555-0148"), "+12025550148");
  assert.equal(normalisePhone("+44 20 7946 0958"), "+442079460958");
  assert.equal(normalisePhone("12"), null);
  assert.match(composeMessage({ deviceID: "d", level: "High risk", reasons: ["Hot."] }), /Thermyx High risk on d\. Hot\./);
});
