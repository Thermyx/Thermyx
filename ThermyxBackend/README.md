# Thermyx Prototype 1 alert relay

This Node 18+ service is the shared-status bridge for a supervised Prototype 1
evaluation. It accepts authenticated risk events from the wearer app, exposes
the most recent event to a trusted-member app, and can send SMS through Twilio.
It does not call emergency services and is not a medical or emergency-response
service.

## Deployment

1. Deploy `server.js` to a Node 18+ host that terminates TLS and provides a
   public HTTPS URL. Do not expose the relay directly over HTTP outside a local
   same-network demo.
2. Set secrets in the host's secret manager or deployment dashboard — never in
   the repository or an app build:

   ```text
   THERMYX_TOKEN=<long random shared secret>
   TWILIO_ACCOUNT_SID=<Twilio account SID>
   TWILIO_AUTH_TOKEN=<Twilio auth token>
   TWILIO_FROM_NUMBER=<Twilio number in E.164 format>
   PORT=8787
   ```

   Twilio credentials are required only when SMS is enabled. The relay still
   accepts and serves authenticated status events without recipients.
3. Configure both apps with `https://<your-host>` and the same
   `THERMYX_TOKEN` under **Safety → Advanced**. Use a unique token per
   prototype environment and rotate it after any suspected disclosure.
4. Exercise a supervised end-to-end test: send a test event, confirm the
   trusted-member Watch screen updates, then confirm the intended test contact
   receives one SMS.

## API

- `POST /v1/alerts` accepts a bearer-authenticated risk event and retains its
  latest value by `deviceID` for the trusted-member view.
- `GET /v1/status/:deviceID` returns that latest event. It requires the same
  bearer token.

Both endpoints require `Authorization: Bearer <THERMYX_TOKEN>`. The service
holds status only in memory, so a restart clears all status. It has no durable
audit trail, delivery retry queue, consent workflow, or rate limiting; those
are required before any use beyond the supervised prototype.

## Local two-phone demo

Run the relay on a laptop connected to the same Wi-Fi as both phones:

```bash
export THERMYX_TOKEN='local-demo-token'
export PORT=8787
node server.js
```

Set the endpoint on both phones to `http://<laptop-LAN-IP>:8787`, choose
**User** on the insole phone and **Trusted member** on the second phone, and
use a disposable test token. Do not use personal contacts or production Twilio
credentials for this path.
