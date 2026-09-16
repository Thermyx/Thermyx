# Thermyx alert relay

This optional HTTPS backend receives escalated risk events from the iOS app and sends SMS notifications to user-approved contacts through Twilio. It does not call 911. The app must be configured with the deployed `https://.../v1/alerts` URL and the shared backend token.

Required environment variables:

```text
THERMYX_TOKEN=long-random-secret
TWILIO_ACCOUNT_SID=...
TWILIO_AUTH_TOKEN=...
TWILIO_FROM_NUMBER=+1...
PORT=8787
```

Run with Node 18+:

```bash
node server.js
```

Production requirements: HTTPS, authenticated deployment, consent and contact verification, rate limiting, audit logs, secrets storage, retry handling, and a privacy policy. Do not represent this relay as an emergency-response service.
# Thermyx two-phone demo backend

The backend is the shared bridge for the Congressional App demo:

1. Start the server on a laptop connected to the same Wi-Fi as both phones.
2. Set `THERMYX_TOKEN` to the same short demo token on the server and in both apps.
3. Enter the laptop's local address and port, such as `http://192.168.1.20:8787`, in onboarding on both phones.
4. Choose **User** on the phone connected to the Thermyx insole and **Trusted member** on the second phone.
5. Keep the trusted-member phone on the Watch screen. It polls the shared status endpoint and updates when the user phone publishes a reading or risk event.

The user phone publishes JSON events to `/v1/alerts`; the trusted phone reads the latest event from `/v1/status/:deviceID`. If Twilio variables are configured, the same risk event can also send SMS to trusted phone numbers.

Required environment values:

```text
THERMYX_TOKEN=demo-token
PORT=8787
```

Twilio variables are only needed for SMS delivery:

```text
TWILIO_ACCOUNT_SID=...
TWILIO_AUTH_TOKEN=...
TWILIO_FROM_NUMBER=...
```
