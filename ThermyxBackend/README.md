# Thermyx Prototype 1 alert relay

The relay lets a wearer's phone share its current safety state with watchers
the wearer has approved, and (once tested) text the wearer's trusted contacts.
It does not call emergency services and is not a medical or emergency-response
service.

**Persistence is a competition prototype**: one SQLite file through Node's
built-in driver (Node 22.5+). It needs a persistent disk and backups if hosted,
and it is not durable production infrastructure.

## Access model

| Who | How they get access | What they can do |
|---|---|---|
| Team member | Shell access to the relay machine | `npm run admin wearer-code` makes a one-time code. There is no admin web endpoint. |
| Wearer's phone | Redeems a wearer code once, receives its own device token | Post its state, invite watchers, approve / renew / revoke them |
| Watcher's phone | Redeems a watcher code the wearer made, receives its own read-only token | Nothing until the wearer approves. Then: current level, alert/SOS/OK, last update time, and a location only during an active event the wearer consented to share |

- **Pairing codes** are single use, expire after **10 minutes**, are either a
  wearer code or a watcher code, and every creation and redemption is audited.
  Pairing is rate-limited to 10 attempts a minute per address.
- **Watcher access** starts as *pending*, lasts **90 days** after approval
  (approving again renews it), and is cut off immediately when revoked.
- **Tokens and codes** are stored only as SHA-256 hashes.
- **Location** is stored only when the wearer consented and the event is High
  risk, Critical, or SOS. It expires after **1 hour** and is cleared as soon
  as the event ends.
- **Retention**: expired codes after a day; audit and text logs after 30 days;
  a device's status after 7 days without an update. Phone numbers, sensor
  readings and reasons are never stored.
- **Logs** never contain tokens, codes, phone numbers (beyond the last four
  digits of a failed send), or locations.

## Turn on automatic texting

1. Make a Twilio account and get a phone number. A trial account can only
   text numbers you have verified in Twilio, which is enough to test with the
   team. Texting the public from a US number needs Twilio's A2P 10DLC or
   toll-free verification first.
2. `cp .env.example .env` and fill in `SMS_ENABLED=true`, `TWILIO_ACCOUNT_SID`,
   `TWILIO_AUTH_TOKEN` and `TWILIO_FROM_NUMBER`. The relay reads `.env` when
   it starts; git ignores it.
3. `npm start`, and keep the relay running (a computer that stays on, or a host).
4. In the app: Profile → Advanced → connect to the relay, turn on at least one
   trusted contact, then Profile → Trusted circle → **Send a test text**.

The app texts the circle when a foot is 38.5 °C or hotter for 2 minutes,
22 °C or colder for 5 minutes, at High risk or Critical, and on SOS, with at
most one reminder every 15 minutes while it lasts.

## Texting is OFF by default

Texts go out only when `SMS_ENABLED=true` **and** Twilio is configured. Keep
it off until the team has tested real delivery, throttling, the "I'm OK"
update, and location links with actual phones. While it is off, events are
still stored and watchers still see them; the app says texting is not on yet
and shows a labelled preview of the message instead.

## Run it locally (demo)

```bash
cd ThermyxBackend
npm run demo                # port 8787, database in ./data/demo.sqlite
npm run admin wearer-code   # in a second terminal: prints a one-time code
npm test                    # 22 tests, no network needed
```

In the app: **Safety → Advanced → Connect to relay**, enter
`http://<this computer's LAN IP>:8787` (or `http://localhost:8787` from the
iOS Simulator on the same Mac) and the code. Then **Safety → Watchers →
Invite** makes a watcher code for a second phone or simulator, which joins as
**Trusted member**.

## Deployment

1. Deploy behind a host that terminates HTTPS, with a **persistent volume**
   mounted at `/data` (the `Dockerfile` sets `DATABASE_FILE=/data/thermyx.sqlite`).
   Many hosts erase local files on redeploy; without a volume everyone would
   have to pair again.
2. Environment:

   ```text
   PORT=8787
   DATABASE_FILE=/data/thermyx.sqlite
   SMS_ENABLED=false                 # leave false until tested with real phones
   TWILIO_ACCOUNT_SID=...            # only when texting is enabled
   TWILIO_AUTH_TOKEN=...
   TWILIO_FROM_NUMBER=+1...
   SMS_REMINDER_MINUTES=5
   CONTACT_VERIFICATION_ENABLED=false  # needs SMS_ENABLED; leave off until tested
   AI_SUMMARY_ENABLED=false          # "true" for the daily AI summary
   ANTHROPIC_API_KEY=...             # only when the AI summary is enabled
   AI_MODEL=claude-haiku-4-5         # optional
   ```

3. Make a wearer code with `npm run admin wearer-code` in the host's shell.
4. Back up `/data/thermyx.sqlite` if the deployment matters.

## Admin commands

```bash
npm run admin wearer-code          # one-time wearer code
npm run admin devices              # paired devices and approved-watcher counts
npm run admin revoke-device <id>   # cut off a device and all its watchers
npm run admin audit 50             # recent audit records
```

## API

Every route except `/health` and `/v1/pair` needs `Authorization: Bearer <token>`.

| Route | Role | Purpose |
|---|---|---|
| `POST /v1/pair` `{code, name?}` | — | Redeem a code. Wearer → `{role, deviceID, token}`; watcher → `{role, watcherID, token, status: "pending"}` |
| `POST /v1/events` | wearer | `{level, kind, reasons?, recipients?, location?, locationConsent?}`. `kind` is `status` (heartbeat, never texts), `alert`, `sos`, or `ok` |
| `POST /v1/watchers/codes` | wearer | New one-time watcher code |
| `GET /v1/watchers` | wearer | Watchers: name, status (pending / approved / expired), dates |
| `POST /v1/watchers/:id/approve` | wearer | Approve or renew for 90 days |
| `DELETE /v1/watchers/:id` | wearer | Revoke now |
| `DELETE /v1/device` | wearer | Delete my data: ends this phone's and every watcher's access and removes the stored status and location |
| `POST /v1/contacts/verify` `{phone}` | wearer | Off by default. Texts the number a 6-digit code (10 min, 5 tries, 5 sends/hour) |
| `POST /v1/contacts/confirm` `{phone, code}` | wearer | Confirms the code the contact read back. Numbers are stored only as salted hashes, and only until confirmed or expired |
| `POST /v1/texts/test` `{recipients}` | wearer | Needs texting on. Texts the given numbers a test message (3 per hour) |
| `POST /v1/summary` | wearer | Off by default. One day's aggregate numbers (`day`, `wornMinutes`, heating/cooling minutes, temperatures, cadence, standing, peak risk, `unit`, `focus`) → `{summary}`. Only those fields reach the model; nothing is stored or logged. 20 per hour |
| `DELETE /v1/watch` | watcher | Stop watching (ends this watcher's own access) |
| `GET /v1/watch` | watcher | `{status: "pending"}` or `{status: "approved", state: {level, kind, updatedAt, location?}}` |
| `GET /health` | — | Liveness and whether texting is on |

## Daily AI summary is OFF by default

With `AI_SUMMARY_ENABLED=true` and `ANTHROPIC_API_KEY` set, the app's daily
summary page can ask for a few plain sentences about the day. The relay keeps
only whitelisted aggregate numbers (no readings, names, phone numbers or
locations), sends them to the model with instructions not to diagnose or
invent values, and returns the text. Nothing about the request is stored.

## Texting rules (when enabled)

- `status` events never text. `sos` and `ok` always do.
- `alert` events text on the first rise, again on any higher level, and at most
  once per `SMS_REMINDER_MINUTES` at the same level. Back at Normal resets this.
- Up to five recipients, normalised to E.164 (10-digit numbers are treated as US).
- A failed send is retried once; attempts are recorded in the audit trail.
