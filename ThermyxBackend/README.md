# Thermyx Prototype 1 alert relay

This Node 18+ service is the shared-status bridge for a supervised Prototype 1
evaluation. It accepts authenticated events from the wearer app, exposes the
latest one to a trusted-member app, and texts the trusted circle through
Twilio. It does not call emergency services and is not a medical or
emergency-response service.

## Run it locally (demo)

```bash
cd ThermyxBackend
npm run demo          # THERMYX_TOKEN=local-demo-token, port 8787
npm test              # 9 tests, no network needed
```

In the app, under **Safety → Advanced → Shared backend**, set the URL to
`http://<this computer's LAN IP>:8787` (or `http://localhost:8787` from the iOS
Simulator on the same Mac) and the token to `local-demo-token`. Use a second
phone or simulator as **Trusted member** with the same device ID to watch.
Without Twilio credentials the relay still stores and serves status; texts
return `sms_not_configured`.

## Deployment

1. Deploy behind a host that terminates HTTPS (Render, Fly.io, Railway, a VPS
   behind Caddy). A `Dockerfile` is included; mount a volume at `/data` so
   status survives restarts.
2. Set secrets in the host's secret manager — never in the repository or an app
   build:

   ```text
   THERMYX_TOKEN=<long random shared secret>          # required; the relay refuses to start without it
   THERMYX_DEVICE_TOKENS={"thermyx-ab12cd":"<token>"} # optional; locks a device to its own token
   TWILIO_ACCOUNT_SID=<Twilio account SID>             # only needed to send texts
   TWILIO_AUTH_TOKEN=<Twilio auth token>
   TWILIO_FROM_NUMBER=<Twilio number in E.164 format>
   PORT=8787
   STATUS_FILE=/data/status.json                       # default ./data/status.json
   SMS_REMINDER_MINUTES=5                              # repeat-text gap at the same level
   ```

3. Configure both apps with `https://<your-host>` and the token under
   **Safety → Advanced**. The app stores the token in the Keychain. Use a unique
   token per prototype environment and rotate it after any suspected disclosure.
4. Run a supervised end-to-end test: trigger an alert, confirm the watcher's
   screen updates, then confirm the test contact receives one text.

## API

Every endpoint except `/health` requires `Authorization: Bearer <token>`.

- `POST /v1/alerts` — an event from the wearer app:

  ```json
  {
    "deviceID": "thermyx-ab12cd",
    "kind": "alert",
    "level": "High risk",
    "reasons": ["Ambient temperature is elevated."],
    "recipients": ["+12025550148"],
    "timestamp": 780000000,
    "readings": { "footTemperatureC": 38.4 },
    "foot": "right",
    "left": { "footTemperatureC": 36.1 },
    "right": { "footTemperatureC": 38.4 },
    "location": { "latitude": 29.7604, "longitude": -95.3698, "accuracyM": 30 }
  }
  ```

  `kind` is `status` (the once-a-minute heartbeat; never texts), `alert`,
  `sos` (Call 911 pressed), or `ok` (the wearer checked in). `level` is one of
  `Normal`, `Caution`, `High risk`, `Critical`. Missing `kind` means `alert`.
- `GET /v1/status/:deviceID` — the latest event for that device (phone
  numbers removed), or `{ "event": null }`.
- `GET /health` — liveness check.

## Texting rules

- `status` events never text.
- `alert` events text on the first escalation, again on any higher level, and
  at most once per `SMS_REMINDER_MINUTES` at the same level. A `Normal` event
  resets this, so the next escalation texts immediately.
- `sos` and `ok` always text.
- Up to five recipients; numbers are normalised to E.164 (10-digit numbers are
  treated as US).
- A failed send is retried once and logged (only the last four digits of the
  number are logged).
- A map link is added when the event carries a location.

## Limits

Latest status is persisted to a JSON file; there is no history, audit trail,
consent workflow, or push notifications (watchers poll every 2 s while their
app is open and get local notifications on escalation). Those are needed
before any use beyond the supervised prototype.
