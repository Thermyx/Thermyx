#!/usr/bin/env node
// Team-only commands, run on the relay's own machine. There is no admin web
// endpoint: if you can run this, you already have the server.
//
//   node admin.js wearer-code          one-time, 10-minute code to pair a wearer's phone
//   node admin.js devices              paired devices and their approved watchers
//   node admin.js revoke-device <id>   cut off a device and all of its watchers
//   node admin.js audit [n]            last n audit records (default 50)
const path = require("node:path");
const { openStore } = require("./store");

const store = openStore(process.env.DATABASE_FILE || path.join(__dirname, "data", "thermyx.sqlite"));
const [command, arg] = process.argv.slice(2);

switch (command) {
  case "wearer-code": {
    const { code, expiresAt } = store.createWearerCode();
    console.log(`Wearer pairing code: ${code}`);
    console.log(`Single use. Expires ${expiresAt}. Enter it in Thermyx under Safety → Advanced → Connect to relay.`);
    break;
  }
  case "devices":
    console.table(store.listDevices());
    break;
  case "revoke-device":
    if (!arg) { console.error("Usage: node admin.js revoke-device <device-id>"); process.exitCode = 1; break; }
    console.log(`Revoked ${store.revokeDevice(arg)} token(s) for ${arg}.`);
    break;
  case "audit":
    console.table(store.auditTrail(Number(arg) || 50));
    break;
  default:
    console.log("Commands: wearer-code | devices | revoke-device <id> | audit [n]");
}
store.close();
