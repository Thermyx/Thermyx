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
| Watcher's phone | Redeems a watcher code the wearer made, receives its own read-only token | Nothing until the wearer approves. Then the status card: level, freshness, the wearer's chosen name, which foot, its temperature and trend, data confidence, a low battery or weak connection, the current event's timeline (alert, follow-ups, SOS, check-in, recovery, silence), and a location only during an active event the wearer shares it for |

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
  a device's status after 7 days without an update. Only the latest status
  card and the current event's timeline are kept: no reading history, and
  phone numbers are never written to disk.
- **Logs** never contain tokens, codes, phone numbers (beyond the last four
  digits of a failed send), or locations.

## What contacts are texted (`message.js`)

Plain sentences, most important first: who and how serious, what the insoles
saw (foot, zone only from boards that sense it, temperature *at the insole*
and its trend), whether the data is confirmed, the wearer's local time, a low
battery or weak connection, the location (High risk, Critical and SOS: a map
link, or "Location not shared"/"unavailable"), what Thermyx told the wearer,
and what to do by level. For example:

```
Thermyx Critical Alert — Miheer
Right forefoot temperature is elevated and still rising: 101.1°F at the insole.
Data confirmed at 4:18 PM CDT.
Location: https://maps.google.com/?q=29.76043,-95.36981
Thermyx told them to stop and get help.
Call them now. If they don't answer or seem unresponsive, call 911.
Thermyx will text again when they check in or readings recover.
```

Follow-ups (`kind: "update"`) go only after an alert or SOS reached someone in
the same event, at most once a minute: "Still Critical after 2 minutes",
"Readings are recovering: now Caution", "Readings are back to Normal". A
check-in says when. During a texted High risk, Critical or SOS event, the relay
holds the recipients **in memory** and texts once if the wearer's phone goes
quiet for `SILENCE_MINUTES` (default 3), then "back in touch" when it returns;
the numbers are forgotten when the event ends or after an hour (and on a
restart). `test/message-fixtures.json` holds worked examples; the app's
preview is tested against the same file.

**Cost.** The texts use only plain SMS characters (no "°" or "—", and iOS's
narrow space in "4:18 PM" is replaced), so a segment holds 160 characters and a
full alert is about 3 segments. A name with an accent or emoji switches that
text to Unicode (70 a segment, so about 6).

## Getting texting live (Twilio, US)

US carriers block texts from unregistered numbers (error 30034), so this comes
before `SMS_ENABLED=true`:

1. Make a Twilio account, **upgrade** it (a trial only texts numbers you've
   verified, and prefixes every text), and buy a US number.
2. Register it. For a team without a company, the realistic route is an
   **A2P 10DLC Sole Proprietor** campaign (Console → Messaging → Regulatory
   Compliance → A2P 10DLC): a Customer Profile, a Brand, then a Campaign. A
   registered business can use the Standard route; a **toll-free** number
   needs its own verification. Approval takes days to weeks, so start now.
3. The campaign asks for: the use case (account notification / safety alerts),
   2–3 sample messages (paste ones from `test/message-fixtures.json`), how
   people opt in, and links to the Privacy Policy and Terms. Contacts are
   added by the wearer, so **turn on `CONTACT_VERIFICATION_ENABLED`**: the
   contact reads a code back, which is their opt-in. Say so in the form.
   Twilio answers STOP and HELP for you.
4. Put `TWILIO_ACCOUNT_SID`, `TWILIO_AUTH_TOKEN`, `TWILIO_FROM_NUMBER` in
   `.env`. Test with `SMS_ENABLED=true` on real phones (alert, follow-up,
   check-in, silence), then leave it on.

Rules and fees change; check Twilio's current A2P 10DLC and toll-free pages.

## Push to watchers (APNs)

Watchers get a real push notification, even with the app closed. It needs a
**paid Apple Developer account**: a free Personal Team can't sign the Push
Notifications entitlement, so the app builds without it by default and a
watcher simply gets alerts while the app is open (the Watch tab says so).

Once, on the paid team:

1. developer.apple.com → Certificates, Identifiers & Profiles → **Keys** → +
   → tick **Apple Push Notifications service (APNs)** → download
   `AuthKey_XXXXXXXXXX.p8` (you can only download it once). One key covers
   development and production.
2. Identifiers → `com.thermyx.app.a` → enable **Push Notifications** (and
   **Time Sensitive Notifications**).
3. In the app repo: `cp Config/Local.xcconfig.example Config/Local.xcconfig`,
   run `xcodegen generate`, and build with the paid team selected.
4. On the relay, in `.env`:
   ```
   APNS_KEY_FILE=/path/to/AuthKey_XXXXXXXXXX.p8
   APNS_KEY_ID=XXXXXXXXXX        # the key's ID (also in its file name)
   APNS_TEAM_ID=YYYYYYYYYY       # Membership → Team ID
   APNS_TOPIC=com.thermyx.app.a
   ```
   `GET /health` then shows `"push": true`. Keep the `.p8` out of git.

An Xcode-run build gets a *development* token and a TestFlight or App Store
build a *production* one; the app reports which, and the relay uses the matching
Apple server. Pushes follow the same rules as texts: an alert on a rise, "still"
follow-ups, recovering / back to Normal, check-ins, SOS, and "no update"
when the wearer's phone goes quiet. High risk, Critical and SOS are marked
Time Sensitive so they break through Focus. A token Apple reports dead is
dropped; a revoked or expired watcher's token is deleted with their access.
(Critical Alerts, which ignore the silent switch, need a separate Apple
approval and aren't used.)

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
npm test                    # 20 tests, no network needed
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
| `POST /v1/events` | wearer | `{level, kind, recipients?, location?, locationConsent?, detail?}`. `kind` is `status` (heartbeat, never texts), `alert`, `sos`, `ok`, or `update` (a follow-up). `detail` is the status card; every field is checked against its allowed values (`cleanDetail`) and anything else is dropped |
| `PUT /v1/watch/push` `{token, environment}` | watcher | This phone's APNs token (`development` or `production`). Pushed to only once approved |
| `DELETE /v1/watch/push` | watcher | Stop pushes to this phone |
| `POST /v1/watchers/codes` | wearer | New one-time watcher code |
| `GET /v1/watchers` | wearer | Watchers: name, status (pending / approved / expired), dates |
| `POST /v1/watchers/:id/approve` | wearer | Approve or renew for 90 days |
| `DELETE /v1/watchers/:id` | wearer | Revoke now |
| `DELETE /v1/device` | wearer | Delete my data: ends this phone's and every watcher's access and removes the stored status and location |
| `POST /v1/contacts/verify` `{phone}` | wearer | Off by default. Texts the number a 6-digit code (10 min, 5 tries, 5 sends/hour) |
| `POST /v1/contacts/confirm` `{phone, code}` | wearer | Confirms the code the contact read back. Numbers are stored only as salted hashes, and only until confirmed or expired |
| `POST /v1/summary` | wearer | Off by default. One day's aggregate numbers (`day`, `wornMinutes`, heating/cooling minutes, temperatures, cadence, standing, peak risk, `unit`, `focus`) → `{summary}`. Only those fields reach the model; nothing is stored or logged. 20 per hour |
| `DELETE /v1/watch` | watcher | Stop watching (ends this watcher's own access) |
| `GET /v1/watch` | watcher | `{status: "pending"}` or `{status: "approved", state: {level, kind, updatedAt, location?}}` |
| `GET /health` | — | Liveness and whether texting is on |

## Secrets in `.env`

Copy `.env.example` to `.env` beside `server.js` and fill it in. The relay
reads it at startup (variables already in the environment win). `.env` is
git-ignored. The Claude API key belongs here, on the server; the app only
ever talks to the relay, so there's no key in the app to extract.

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
