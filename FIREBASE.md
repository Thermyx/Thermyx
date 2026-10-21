# Firebase setup for Thermyx

Thermyx uses Firebase for three things:

| Feature | Firebase product | On by default? |
|---|---|---|
| Sign in with Google | Authentication | Needed to sign in |
| **Back up to my account** (profile, preferences, baseline, calibration model, recoveries) | Cloud Firestore, `users/{uid}/backup/*` | No. The wearer turns it on |
| **Population starting points** (anonymous monthly numbers in, typical values out) | Cloud Firestore, `priorSamples/*` | No. The wearer turns it on |

Raw sensor history, trusted contacts, the relay token and location never go to
Firebase. The code is in `ThermyxApp/Services/Cloud/`.

Project ID: `thermyx` (from `GoogleService-Info.plist`).

## One-time console steps

1. **Create the Firestore database.** Firebase console, Build, Firestore
   Database, Create database. Pick **Native mode**, **production mode**, and a
   location near your users. The location can't be changed later.
2. **Deploy the rules and indexes** (below). Until the rules are deployed, a
   database created in production mode refuses every request, so backup and
   priors simply fail quietly (the app shows "Couldn't back up just now").
3. **Check Authentication.** Google sign-in is already enabled. Nothing else
   to switch on. The rules need the `email_verified` claim, which Google
   accounts have.
4. **Time-to-live (TTL).** Deploying `firestore.indexes.json` turns on a TTL
   policy for `priorSamples.expireAt`, which removes anonymous numbers about
   five weeks after they are written. If you'd rather do it by hand: console,
   Firestore, Time-to-live, Create policy, collection group `priorSamples`,
   timestamp field `expireAt`. Without TTL, old numbers never expire and the
   privacy policy's retention line is wrong, so don't skip it.

## Deploying (no sudo, no global install)

You need Node (already installed). From the repo root:

```sh
npx firebase-tools login          # opens a browser, once
npx firebase-tools deploy --only firestore --project thermyx
```

`firebase.json` at the repo root points at `firestore.rules` and
`firestore.indexes.json`. Index builds take a few minutes; the console shows
their status under Firestore, Indexes.

No Node or no CLI? Paste `firestore.rules` into console, Firestore, Rules,
Publish, and create the six `priorSamples` indexes from
`firestore.indexes.json` by hand (or run the app, trigger the priors refresh,
and click the link in the missing-index error the console logs).

Nothing here has been deployed from this repo yet.

## Plan and cost

**The free Spark plan is enough.** Nothing in this setup needs Blaze.

- Firestore on Spark: 1 GiB stored, 50,000 reads and 20,000 writes and 20,000
  deletes per day. One wearer with backup on writes a few dozen documents a
  day at most (the baseline is throttled to one write per 10 minutes, and only
  while worn), reads four documents at launch, and does about 30 small
  aggregation queries a week if they opted into priors. Aggregation queries
  are billed as one read per 1,000 matching index entries, so they stay cheap
  until a cohort has tens of thousands of contributors.
- TTL deletes are billed like ordinary deletes: seven or fewer per
  contributor per month.
- **Needs Blaze (paid), optional, not set up:** Cloud Functions, the "Delete
  User Data" extension (it would delete `users/{uid}` automatically when an
  account is deleted from the console; the app already deletes the backup
  itself before deleting the account), and BigQuery export.
- **Optional hardening:** Firebase App Check (App Attest). Enforcement for
  Firestore works on Spark, but App Attest needs the paid Apple Developer
  program and an entitlement. It would make scripted writes to `priorSamples`
  harder. Not required.

## Data model

```
users/{uid}/backup/{settings|baseline|model|recoveries}
    schema: 1
    payload: string        // the part as JSON
    updatedAt: timestamp   // client clock, capped by the rules at now + 5 min
    deviceId: string       // random per install

priorSamples/{32-hex random id}
    v: 1
    metric: footSitting | footStanding | footWalking | steadiness
          | standingLean | walkingLean | steadinessGap
    cohort: "<usage>|<band>"   usage: outdoor-work | sports | cold | everyday | general
    usage, band                band: under-30 | 30-59 | 60-plus | unknown
    value: number          // rounded on the phone (0.1 degC, or 0.02)
    sq: number             // value squared, so a standard deviation can be derived
    expireAt: timestamp    // TTL
```

### Sync rules (what the app does)

- Offline first: the phone is always the source of truth; Firestore's offline
  cache queues writes.
- Last writer wins per document, by `updatedAt`; a tie goes to the larger
  `deviceId`.
- A phone that has never synced with the account restores into empty parts
  without asking, backs up parts the cloud lacks, and asks the wearer to pick
  when both sides have different data.
- Nothing syncs, reads or writes in Demo Mode or in the preview harness.
- Deleting the account, "Delete my data" and "Delete my cloud backup" delete
  the four documents and wait for the server to confirm.

### Priors

Writes: at most once a month per phone, one document per number, each with its
own random ID, no uid, no timestamp but the expiry. Documents can't be
changed or deleted after they are written (nothing in them says whose they are,
so nothing can authorise it); they expire by TTL.

Reads: Firestore aggregation queries (`count`, `average`, and `sum` of `sq`)
per metric, trying the cohort, then the usage type, then everyone, and using
the first with at least 20 contributors. Refreshed at most weekly and cached
on the phone.

## What a signed-in user can read and write

Said plainly, because aggregation queries need `list` access:

- **Readable by any signed-in user with a verified email:** every
  `priorSamples` document (a metric, a coarse cohort, one rounded number and
  its square, an expiry). There is no identifier in them. They cannot read
  `users/{uid}/backup/*` for anyone else, or even `get` a single sample by ID.
- **Writable by any signed-in user:** well-formed `priorSamples` documents with
  in-range values. A scripted client can add junk inside the allowed ranges.
  The rules can't tell; the app limits the damage (priors are used only when
  20+ contributors back them, and personal baselines can only add caution).
  Watch the document count in the console; if it looks wrong, delete the bad
  documents there.
- **Owner only:** `users/{uid}/backup/*`, readable, writable and deletable only
  by that uid, only for the four known parts, with the exact fields above.

The rules are in `firestore.rules`. They were checked against the Firestore
emulator with 30 allow/deny cases (owner vs other vs signed-out vs unverified,
extra fields, out-of-range values, bad sums of squares, update/delete refused,
count/average/sum queries allowed). That script is not kept in the repo.

## Checking it works

1. Run the app on a signed-in account, Device tab, turn on **Back up to my
   account**. In the console you should see `users/<uid>/backup/settings` and
   the other parts that have data.
2. Delete and reinstall, sign in: the Restore card appears on the Device tab.
3. Turn on **Help new wearers start smarter**. After enough calm wear
   (20+ minutes in an activity, a calibrated baseline), `priorSamples`
   documents appear once a month.
