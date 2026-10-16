# Thermyx

iPhone app for the Thermyx smart insole: a BLE wearable that senses foot
temperature, pressure, and movement, and actively heats or cools within hard
safety limits.

Website: thermyx.web.app

## Thermyx is a pair

The app holds an independent BLE link to each insole and shows whatever it has.
One connected and one not is an ordinary, supported state — not an error and
not a mode to switch between.

- **Both connected**: equal soles side by side, medial edges facing, each with
  its own zone readouts and its own history.
- **One connected**: the live foot keeps the space it needs, and the missing
  one shrinks to a tab pinned at the screen margin. It stays visible and stays
  tappable — pair the second insole with one tap or a pull inward.
- **Neither**: both sit at equal size under a single pairing prompt.

**No value from one foot is ever shown for the other**, and no chart averages
the two into one line. Averaging would erase the asymmetry that running a pair
exists to reveal.

### What the pair makes possible

A single insole can only compare a foot against its own past. Two can compare
them against each other *now*, which is faster and far more specific. The
`BilateralReading` and `BalanceDetailView` surface:

- temperature gap between feet, over time;
- load gap, in percentage points of forefoot share;
- gait-stability gap;
- an `asymmetryIndex` combining them, and which foot is consistently warmer or
  more loaded across a window.

A gap that holds for **two minutes** raises **caution on its own** — favouring
one foot is both a fit problem and a fatigue signal. Shorter gaps are ordinary
walking noise and are ignored. It never escalates past caution by itself: a
difference between feet is not the same kind of evidence as a foot that is
simply too hot.

## Safety behaviour

- **Burn protection.** A foot-contact (or any zone) temperature of **40 °C** or
  more is High risk on its own and locks out heating, whether the wearer chose
  Heat or Auto started heating by itself. The firmware enforces the same limit
  independently.
- **Background monitoring.** The app keeps its Bluetooth links with the screen
  locked (`bluetooth-central` background mode plus state restoration), and
  reconnects a dropped insole automatically.
- **Stale data.** An insole that stays connected but stops sending for 5 s has
  its readings cleared, so nothing freezes on screen looking live.
- **Alerts.** The wearer is notified when the level rises. A heartbeat is
  posted every minute so a watcher sees "No update for N min" when the
  wearer's phone goes quiet. **Texting trusted contacts is off** until the
  relay's `SMS_ENABLED` is turned on after testing with real phones (and A2P
  10DLC registration); until then the app shows a labelled "Preview · not
  sent" of the message.
- **Recovery loop** (Home → Insights). When a level is Caution or above, Home
  offers a **Thermal Recovery Test**: stop and sit, cool the feet (one tap to
  switch the insoles to Cool), loosen the shoes, sip water, then hold still
  for 3 minutes while Thermyx measures whether the warmer foot is cooling
  (half a degree or more, on a steady reading, while still enough to count; a
  Critical level shows Call 911 first and never waits on the test). The result
  is Recovered, Improving, Not improving yet, or Hard to tell, with the
  temperature change, stillness and whether weight on the two feet evened out.
  The wearer then ticks what they did (rested, cooled down, changed footwear,
  loosened laces, hydrated, stopped activity) and it goes into the **Safety
  plan** on Insights, which compares how fast the foot cooled with and without
  each action once five recoveries are measured ("After short rest breaks,
  your foot cooled about twice as fast as when carrying on"), only when the
  difference is clear and each side has at least two. Events can also be
  logged afterwards. The **Readiness profile** above it answers "is today
  different for me?": the usual temperature range for sitting, standing and
  walking (the middle 80% of the last 28 days of calm hours, else the
  calibration's), where the warmer foot is now, usual weight on each foot, the
  comfort target and whether recoveries are getting quicker. None of it is
  medical advice, it never changes a risk level or delays an alert, and the
  demo keeps its own recoveries in memory. Logic: `ThermyxRecovery.swift`,
  `ThermyxReadiness.swift`; screens: `RecoveryViews.swift`,
  `ReadinessViews.swift`.
- **The session stays put.** iOS suspends the app (and its timers) in the
  background, so the stale-reading check now counts from when the app came
  back, not across the gap, and a demo that was running comes back after a
  relaunch (admin accounts; Exit demo clears it). Only one Live Activity is
  ever on the Lock Screen: the old one is ended first, and a paused demo says
  "Simulated · paused" instead of "Not connected". A demo can't tick while iOS
  has the app suspended; real insoles keep reporting through Bluetooth's
  background mode.
- **Trusted circle handoff.** Contacts are texted, and approved watchers see a
  status card, with the same facts: the wearer's chosen name, level, which
  foot (zone only from boards that sense it), its temperature at the insole
  and trend, "Data confirmed" or "Limited data: check on them directly" (both
  insoles fresh and a steady stream), a low battery or weak connection, local
  time, what Thermyx asked the wearer to do, and what to do by level. Then
  follow-ups: "Still Critical after 2 minutes" (then every 5), "recovering",
  "back to Normal", and the time they checked in. Location is on by default
  for High risk, Critical and SOS, explained once in "What your circle gets"
  before the first contact or watcher is added; texts say "Location not
  shared" when it's off. If the phone goes quiet for 3 minutes mid-event, the
  relay itself texts the circle. Watchers can also get a real push with the
  app closed (APNs; needs the paid Apple Developer team, see
  `ThermyxBackend/README.md` and `Config/`). Texts are composed in
  `ThermyxBackend/message.js`; `ThermyxCircleMessage.swift` mirrors it for the
  preview, and both are tested against the same fixtures.
- **Critical.** A full-screen alert offers Call 911 (opens the phone's dialer)
  and "I'm OK" immediately. Only the automatic contact text waits 60 s.
  Location goes to the relay only with the wearer's consent and only during a
  High, Critical, or SOS event, and expires after an hour.
- **Why am I seeing this?** Every level from Caution up explains itself: each
  signal with its value and rule, which foot, data age, a confidence rating,
  and the next step. Per-insole health (live / stale / off, battery, signal)
  shows there and on Advanced.
- **Personal baseline.** Calibrates over 10 calm minutes, then learns slowly.
  A reading well above the wearer's usual, steadiness well below it, or a fast
  rise can add Caution. It can never lower a level the fixed rules set, and
  never goes past Caution on its own.

## Relay access model

The phone pairs with the relay using a one-time, 10-minute code made by
`npm run admin wearer-code`, and receives its own device token. Watchers join
with a one-time invite the wearer makes, see nothing until the wearer approves
them, appear in a "Who can see your status" list with one-tap remove, and lose
access after 90 days unless renewed. **Delete my data** (Safety → Advanced)
removes everything on the phone and the wearer's record on the relay; **What
leaves your phone?** on the same screen lists exactly what is shared. Details:
[`ThermyxBackend/README.md`](ThermyxBackend/README.md).

## The rule this app is built around

**Thermyx never displays a reading it did not measure.**

When a value is missing, the screen shows an empty state — a dashed insole
outline, "No insole connected", a Scan button — not a plausible-looking number.
Every chart, tile, and readout follows this: `nil` renders as an empty state or
a dash, never an estimate. The same rule governs what goes to Apple Health, and
what the Learning Center claims.

This is not a stylistic preference. Thermyx is an investigational heat-risk
warning aid. A fabricated number on a safety screen is the one failure mode
that matters.

## Layout

```
ThermyxApp/
  DesignSystem/       Colour, type, spacing, shape, and shared components.
                      Every token lives here; no view carries a literal hex.
    FootOutline.swift   The real left and right foot outlines (v2 design).
    Components/FootMap  Foot maps: only measured values on live screens.
  Models/             Readings, risk levels, roles, contacts, units, the
                      Learn article model, and ThermalSimulation (the
                      Simulator's model).
  Services/           BLE ingestion, settings, retained history, HealthKit,
                      weather, alert delivery, widgets and Live Activity.
  ViewModels/         ThermyxViewModel (live state), InsightsDigest (chart
                      derivations), TrustedMemberViewModel.
  Views/
    Onboarding/       The interactive insole and sign-in, profile, About you,
                      insoles, calibration.
    Simulator/        The Thermal Safety Simulator tab.
    User/             Home, Insights, Learn and the article reader, Safety,
                      Device, Advanced, the spotlight tutorial.
    Trusted/          Watch, Insights, Settings.
  Resources/
    Fonts/            Archivo and Geist Mono (SIL OFL).
    Models/           The insole's hardware model (insole.glb, from the website).
    Content/          Learn articles (with APA 7 references), photo credits,
                      Privacy Policy, Terms.
    Media/            Optional onboarding walkthrough video (see its README).
  Assets.xcassets/Photos  Learn photographs (Wikimedia Commons).
ThermyxWidgets/       Home Screen and Lock Screen widgets, Live Activity,
                      Dynamic Island (their configurations only).
Shared/               Types shared by the app and the widget extension:
                      the snapshot, the mode buttons' intents, the foot
                      outline and colour scales, and every widget view.
```

**Navigation.** Five tabs: Home, Insights, Learn, Simulator, Safety (Device is
pushed from Safety's gear). The thermal control sits above the tab bar on every
wearer screen: one button that steps Auto → Cool → Heat → Off (touch and hold
for all four; taps reach the insoles only once the wearer stops tapping, so
stepping past Heat never sends heat), and a stepper for Auto's target. The
Trusted Member role gets its own three tabs and **no** control: a watcher can
see and can call, but cannot actuate someone else's insole.

## Building

The project is generated from `project.yml`. **Add new files there, not to the
`.xcodeproj`**, then:

```sh
brew install xcodegen      # once
xcodegen generate
open ThermyxApp.xcodeproj
```

From the command line:

```sh
xcodebuild -project ThermyxApp.xcodeproj -scheme ThermyxApp \
  -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

Device builds need a development team, because HealthKit is an entitlement.
Simulator builds do not.

Xcode 26 downloads the Metal compiler separately. If a build stops at the
Topography shader with "missing Metal Toolchain", run
`xcodebuild -downloadComponent MetalToolchain` once (no admin needed), or
accept Xcode's prompt.

### Accounts: Google sign-in and Firebase

Onboarding starts with **Continue with Google**, through Firebase
Authentication (`Services/ThermyxAccountStore.swift`). Setup is in
`ThermyxApp/Resources/Firebase/README.md`: drop the project's
`GoogleService-Info.plist` there, enable the Google provider in Firebase, copy
its `REVERSED_CLIENT_ID` into `project.yml`, and run `xcodegen generate`.
Without the plist the app builds, but nobody can sign in.

- The account holds no readings. Profile, history and calibration stay on the
  phone, as the privacy policy says.
- **Admins** (`ThermyxAdmins` in the same file) are the only accounts that see
  test tools: the single-sensor board and the relay (Relay Mode), including
  during onboarding. There is no fake data for any account; simulated
  conditions are in the Simulator tab, labelled as such, for everyone.
- Safety → Device → Account has Sign out and Delete account (which deletes the
  Firebase user and revokes Google access, as App Review requires).
- In the simulator without a plist, skip sign-in with the preview harness
  (`-ThermyxUIPreview simulatorOnboarding`).

### Schemes and tests

- **ThermyxApp** runs the app normally.
- **Thermyx Demo** runs it with **simulated insoles** (see below).
- **⌘U** runs `ThermyxAppTests` (risk engine, burn limit, sustained asymmetry,
  suggestions, formatting, alert-event compatibility).

The alert relay has its own tests: `cd ThermyxBackend && npm test`.

## Where the data comes from

```
insole sensors
   → XIAO ESP32-C3 firmware (firmware/thermyx_insole)
   → BLE notification (BLE_PROTOCOL.md)
   → ThermyxBLEService.decodeTelemetry
   → ThermyxReading
   → ThermyxViewModel  ──→ live screens
                       └─→ ThermyxHistoryStore ──→ InsightsDigest ──→ charts
```

Nothing else writes a reading. There is no cache of "last known good" values,
no interpolation, and no seeded defaults. On disconnect the reading resets to
empty and every screen returns to its empty state rather than leaving a stale
number on screen looking live.

`ThermyxHistoryStore` folds readings into minute buckets (kept 7 days) and hour
buckets (kept 180 days), in a JSON file in Application Support. Charts need at
least three buckets before they draw anything; below that they show an empty
state instead of a line through two points.

## Development preview harness

`DesignSystem/ThermyxPreviewHarness.swift` injects synthetic readings so
layouts can be reviewed without hardware. It is fenced three ways:

1. The entire file is inside `#if DEBUG`.
2. Even in Debug it does nothing unless launched with `-ThermyxUIPreview <state>`.
3. When it *is* running, a full-width orange strip reading
   **PREVIEW DATA · NOT LIVE READINGS** insets the top of every screen, so a
   screenshot taken with it on cannot be mistaken for live data.

```sh
xcrun simctl launch booted com.thermyx.app.a -ThermyxUIPreview homeZones
```

Use the `-ThermyxUIPreview` flag with one of these states:

- Onboarding: `onboardingWelcome` (signed out), `onboardingRole`,
  `onboardingAbout`, `onboardingPair`, `onboardingCalibrate`; with simulated
  insoles, `simulatorPair` and `simulatorCalibrate` (fake insole connected).
  Add `-ThermyxStartCalibration` to start calibration by itself,
  `-ThermyxScrollToEnd` to open pages scrolled down, and `-ThermyxAdmin` to
  run as an admin account (it also shows Advanced's Admin panel).
- Any pushed screen, and Safety: `-ThermyxScrollTo <id>` opens it scrolled to
  a section (`end`, or ids such as `ai`, `permissions`, `health`, `circle`).
- `-ThermyxNoPrompts` keeps every permission prompt away, Apple Health's
  included, for clean screenshots.
- Home: `home`, `homeZones`, `homeOneFoot`, `homeCaution`, `profile`, `tour`
- Insights: `insights`, `health`, `temperature`, `movement`, `movementAdvanced`,
  `balance`, `weekly`, `learning`, `article`
- Safety: `safety`, `advanced`, `legal`
- Trusted Member: `trusted`, `trustedSample`, `trustedSampleInsights`,
  `trustedHandoff` (the status card mid-event), `trustedRecovered` (after a
  check-in, easing)
- Recovery: `recoveryTest`, `recoveryHold`, `recoveryResult` (a hot afternoon;
  `-ThermyxRecoveryHold <seconds>` shortens the hold), `readiness`,
  `safetyPlan` (Insights, scrolled to them)
- Trusted circle: `circleSharing` ("What your circle gets" on Safety)

The harness seeds only synthetic readings and fictional people. Its phone
numbers are from NANPA's reserved `555-01xx` fictional range; they cannot
reach a real person.

## Going live

### Prototype 1 deployment checklist

Prototype 1 is for supervised field evaluation, not an emergency-response or
medical-device release. Before distributing it through TestFlight:

- Build and run the **Release** configuration from Xcode on a physical test
  device, then archive it through Xcode for TestFlight.
- Fill every bracketed field in both legal documents and replace placeholder
  Learning Center copy. Update the privacy policy for Google sign-in:
  the account's name and email are now held by Firebase.
- Deploy the relay behind HTTPS with a persistent volume, then pair each
  phone with a one-time code. No token is ever typed or committed.
- Keep the alert relay under supervised use. Its SQLite store is a
  competition prototype, not a durable notification, emergency, or audit
  system. Keep texting and contact verification off until tested with real
  phones.

The deployment and operator runbook for the relay is in
[`ThermyxBackend/README.md`](ThermyxBackend/README.md).

The app is already wired for real data; nothing needs to be swapped out. In
order:

**1. Firmware — the only blocker.** Flash each XIAO ESP32-C3 with
`firmware/thermyx_insole` (see [`firmware/README.md`](firmware/README.md) for
the pin map; set the foot before each upload). It implements
`ThermyxApp/BLE_PROTOCOL.md` but has not yet been compiled for the board or
run on hardware, so bring it up with the insole off the foot. Then: turn on the insole → open Thermyx → Home header or
the empty state's Scan button → pick the device → readings appear. **No app
changes are required.** Every empty state you see today is the app correctly
reporting that no insole has connected yet.

**2. Protocol version.** v1 (12 bytes, two thermistors) is fully supported and
is the recommended target for the first demo. The app collapses Home to a
single foot average, labels it "Single sensor · no zone breakdown", and hides
the Insights zone heat map entirely. If a third and fourth thermistor land
later, switch the firmware to v2 (18 bytes) and the zone map lights up with no
app changes.

**3. History and charts** populate themselves. The Day range needs about three
minutes of wear; Week and Month accumulate from there.

**4. Learning Center copy.** `Resources/Content/learning-articles.json` has all
six articles written, with their sources named at the end of each, but still
marked `"status": "placeholder"`: the sources could not be opened when they were
written, so nobody has yet checked each figure against its original
publication. Check them (the Charkoudian skin-blood-flow figure, the NIOSH
water guidance, the WMS frostbite rewarming range, and the CDC symptom lists),
then change each status to `"published"`. The draft banner and badges
disappear on their own once nothing is a placeholder.

**5. Insole artwork** — see *Sole geometry* below.

**6. Apple Health** is optional and off by default. Turn it on under Safety →
Advanced. Thermyx reads step count, walking steadiness, and workouts, and
writes sessions as `HKWorkout`. It deliberately does **not** request permission
to write body temperature: the insole measures contact temperature, not core
temperature, and writing it under that type would misrepresent it.

**7. Shared backend**, for the Trusted Member flow, is configured under
Advanced. It receives escalated risk events only; readings stay on the phone.

**8. Legal documents.** `Resources/Content/privacy-policy.md` and
`terms-of-service.md` are complete in substance and rendered natively in the
app (Safety → the Thermyx lockup). Five bracketed fields still need filling:

| Field | Appears in |
|---|---|
| `[THERMYX LEGAL ENTITY]` | Both |
| `[CONTACT EMAIL]` | Both |
| `[MAILING ADDRESS]` | Both |
| `[STATE]`, `[COUNTY/STATE]` | Terms § 13 |
| `[EFFECTIVE DATE]`, `[LAST UPDATED DATE]` | Both |

The app shows a "Before release" notice at the end of each document while any
bracket remains. Remove that notice in `LegalSheet` once they are filled.

**9. Trusted-member sample shift.** The watcher can opt into a worked example
(`TrustedSampleData`) so they can learn the screens before a real alert. It is
opt-in, off by default, and every screen carries an amber "Sample shift · not
<name>'s data" banner with one-tap exit while it runs. Unlike the preview
harness this ships — it is a user-facing teaching aid, not injected telemetry,
and it never masquerades as live.

### Simulated insoles

`-ThermyxUIPreview simulator` (the **Thermyx Demo** scheme) replaces the radio
with two simulated insoles inside `ThermyxBLEService`, so every control can be
checked on the iOS Simulator. This is **debug builds only**: the entry points
(`startDemoMode`, `startFakeInsoles`) are compiled out of Release, and nothing
in the app lets an account turn them on.

Admin Demo Mode, the fake insole, the watcher "sample shift" and the fake
calibration recording were removed in October 2026. Simulated conditions now
live in the **Simulator** tab, for everyone and clearly labelled; admins test
with Relay Mode and real hardware.

### Retiring the harness entirely

When the harness is no longer useful, delete it in this order and verify a
Release archive manually:

1. Delete `DesignSystem/ThermyxPreviewHarness.swift`.
2. `ThermyxApp.swift` — remove the `.previewHarness(…)` call and the `#if !DEBUG`
   shim beneath it.
3. `Services/ThermyxBLEService.swift` — remove the `#if DEBUG` preview
   injection, the debug-only simulated radio, and `ThermyxInsoleSimulator`.
4. Remove the `#if DEBUG` initial-state blocks in `Views/RootView.swift`,
   `Views/User/InsightsHubView.swift`, `Views/User/SafetyView.swift`,
   `Views/User/LearningCenterView.swift` and
   `Views/Onboarding/OnboardingFlow.swift`.
5. Delete the **Thermyx Demo** scheme.
6. Regenerate the Xcode project, build a Release archive, and verify that a
   preview launch argument has no effect.

### Welcome screen

The first screen (`Views/Onboarding/OnboardingWelcome.swift`) is the insole's
hardware model (`Resources/Models/insole.glb`, the website's
`hardware-model.glb`, loaded with GLTFKit2 in `InsoleStack.swift`), in the
website's materials with a faint ice halo. A drag spins it all the way round;
**Take apart** separates it into the website's vertical stacks (the site's
`explode.js` offsets); a tap outlines a part in a glow and shows the site's
description of it. Under it: what Thermyx is and Continue with Google. If
`Resources/Media/onboarding-walkthrough.mp4` exists, a "Watch the walkthrough"
link plays it full screen. Preview with `-ThermyxUIPreview onboardingWelcome`
(add `-ThermyxExplode` to open taken apart, `-ThermyxSelect Heat_Sink` to pick a
part). The model loads on the main queue: loading it on a background thread
corrupted SceneKit's node tree and crashed.

## Credits and licences

- **Archivo** — Omnibus Type, SIL Open Font License 1.1, static instances.
  Licence ships in the bundle as `OFL.txt`.
- **Geist Mono** — Vercel, SIL Open Font License 1.1 (v1.7.2 static
  instances), for figures. Licence ships as `OFL-Geist.txt`.
- **GLTFKit2** — Warren Moore, MIT, loads the insole model into SceneKit.
- **Photographs** (Learn) — Wikimedia Commons: U.S. government works (public
  domain), CC0, CC BY 2.0 and CC BY-SA 2.0. Each photo's author, licence and
  source page is in `Resources/Content/photo-credits.json` and shown in the
  app; Creative Commons images are cropped and resized for display.
- **Learn articles** — written for Thermyx. Every reference was checked
  against Crossref, PubMed or the publisher before it was listed (APA 7).
- **Open-Meteo** — outdoor air temperature during calibration and on Home
  (free API, no key; free tier is for non-commercial use). Only a location
  rounded to about 1 km is sent, and only when location is already allowed.
- **Topography** background — ported to Metal from the website's shader, a
  React Bits component (MIT).
- **SF Symbols** — Apple, used under the SF Symbols licence.
- **Brand marks**, as published and not recoloured: the Bluetooth logo
  (Bluetooth SIG), Google's "G" (Google), Claude's mark (Anthropic) — vector
  files from Wikimedia Commons — and the Apple Health icon supplied with the
  project. Each is a trademark of its owner, used only to name that service.
- **Swift Charts**, **HealthKit**, **CoreBluetooth**, **ActivityKit**,
  **WidgetKit**, **AVFoundation** — Apple system frameworks.
- Brand artwork (app icon, circular badge, horizontal wordmark) supplied by the
  Thermyx team. On dark grounds the app uses the website's light-ink logo
  (`ThermyxLogoLight`) and the insole mark cut from it (`ThermyxMark`).

## HealthKit on a simulator

HealthKit needs the `com.apple.developer.healthkit` entitlement, and Xcode
strips restricted entitlements from a build that has no signing team. A build
made with `CODE_SIGNING_ALLOWED=NO` will log:

```
[com.apple.HealthKit:auth] Missing com.apple.developer.healthkit entitlement.
```

The app handles this: `ThermyxHealthService.Availability.notEntitled` renders a
card saying the build is not signed for HealthKit, and nothing else changes.
To exercise the integration, open the project in Xcode and set a development
team on the ThermyxApp target — a free Apple ID is enough. Re-signing the
simulator build by hand does **not** work; the simulator refuses to launch an
app carrying a restricted entitlement with no matching profile.


## Sole geometry

`DesignSystem/SoleGeometry.swift` holds one canonical sole outline and the
coordinate system everything else is positioned in.

### Where the shape came from

The outline was extracted as exact Bézier control points from the supplied US
11–12 sizing templates — not traced from a raster — then rotated upright,
normalised, and re-expressed as a single SwiftUI `Shape`.

All three supplied sizes share the same profile to within **0.1% of aspect
ratio**, so one path scaled by foot length is accurate across the whole
supported range. Measured lengths:

| Size | Length | Width at the ball |
|---|---|---|
| US 11 | 290.9 mm | 122.6 mm |
| US 11.5 | 295.5 mm | 124.6 mm |
| US 12 | 298.7 mm | 125.9 mm |

The template is a **left** foot; the right is its mirror. Both are drawn as
seen looking down at the top of the insole, so each foot's medial (big toe)
side faces the other.

> ⚠️ **The source PDFs are third-party artwork.** They are printable sizing
> templates from *Unshoes Minimal Footwear*, complete with their branding and
> instructions. Nothing from those files ships in the app — no PDF, no logo, no
> raster. What ships is a set of coordinates re-expressed as our own vector.
> Even so, the outline's proportions originate from their template, and that is
> worth a decision before release: either confirm the geometry is fine to
> derive from, or replace it with an outline measured from your own insole.
> The swap is one `Shape`.

### Sole space

Everything drawn on a sole — heat blooms, sensor sites, fault markers — is
positioned in **sole space**:

- `y` runs `0` at the heel to `1` at the toe, as a fraction of foot length;
- `x` is the offset from the centreline in the same units, **positive toward
  the medial (big toe) side of whichever foot is being drawn**.

Because `x` is anatomical rather than screen-relative, a position is written
once and renders correctly mirrored on both feet. `SoleGeometry.point(x:y:foot:in:)`
does the conversion; `SoleSize.millimetres(_:)` converts a sole-space distance
into real millimetres for a given size.

### Sensor sites

The three FSR 402 pressure sensors in the prototype are defined in
`SoleGeometry.SensorSite`, one per thermal zone, on the zone's centreline.

| Site | Sole space (x, y) | Zone |
|---|---|---|
| Heel | 0.035, 0.14 | Heel |
| Arch | 0.000, 0.44 | Arch |
| Forefoot (under the metatarsal heads) | 0.020, 0.71 | Forefoot |

An earlier eight-sensor draft (medial and lateral heel and midfoot, three
metatarsal heads, hallux) was dropped along with the multiplexer it needed.

Thermal zone centres and radii live alongside them, so a three-zone heat bloom
fills its region without spilling into the next.

### Sizes

`SoleSize.all` lists every US size from 6 to 15 so the range is legible, but
only `SoleSize.supported` — **US 11, 11.5, and 12** — can be selected. The rest
render disabled. Hiding them would leave a wearer wondering whether their size
exists; showing them disabled says plainly that it does, just not yet. There is
no EU scale.


## Demo, Home and Insights (2026-10-15)

- **Demo mode** (`-ThermyxUIPreview <state>`, or the *Thermyx Demo* scheme):
  every app state now runs on the simulated insoles, which respond to Cool,
  Auto, Heat, Off and the target like the firmware (`Services/DemoWearer.swift`).
  A month of history is generated first (`DesignSystem/ThermyxDemoHistory.swift`) so Insights, the weekly report, activity and battery estimates
  all have believable data, and the live insoles carry on exactly where it
  ends. The orange footer has **Exit demo**: it disconnects the simulated
  insoles, puts the real history back, clears the demo calibration, and
  returns to real Bluetooth.
- **Auto status** says what the foot is doing ("Warming to 94°", "Holding
  88°", "Cooling one foot to 88°"), never "Cooling" for a foot below target.
- **Home**: the Thermyx mark in the header and each insole's battery drawn to
  scale; the Pressure / Temperature / Gait map tabs as before. The tutorial
  now has nine steps across all five tabs and places its card where it fits
  whole.
- **Feet over time** (Insights, `Views/User/FeetTimelapse.swift`): the feet
  for temperature, pressure and gait play through the chosen day, week or
  month, worn time only (10-minute, hourly or daily frames), with play/pause
  and a scrubber. Trends only, from the same single values as Home.
- **Demo mode for admins**: Advanced → Admin → Demo mode (or *Start demo* on
  Home with no insoles connected). Works in every build, admin accounts only.
  The real history is set aside in memory and never overwritten; Exit demo
  restores it.
- **Simulator**: conditions in one panel with Weather / Activity / Shoes / You
  / Insoles tabs, recovery actions as chips under the readout, and "How the
  simulator works" folded.
- **Insights**: heat exposure as bars (hourly on Day, daily on Week/Month,
  coloured by peak, dashed 38° line), an Activity card (steps, sitting,
  standing, walking), a weekly report with this week against last (`.week`),
  and a Sunday-evening reminder. Charts average into 5-minute (Day),
  30-minute (Week) and 6-hour (Month) windows.
- **AI summary**: once a day, the first time a session ends after 6 pm, or
  caught up for yesterday on the next launch. It sends the day's activity and
  the wearer's niche too; Claude frames it by Health or Performance.
- **Device**: time left and drain per insole, warnings at 10% and 5% (also on
  the widgets, Lock Screen and Dynamic Island), and a dashed "Calibrated" ring
  on the Auto target slider with a button back to it. "Mostly for" can be
  changed in Settings.
- **Shoe size**: US men's, US women's, UK or EU, converted through foot length;
  any size can be saved.
- **Cold reminders** come sooner (27 °C, 30 s) for poor circulation, Raynaud's,
  diabetes or neuropathy. Risk levels are unchanged. Health conditions are
  optional in onboarding.
- **Relay secrets**: copy `ThermyxBackend/.env.example` to `.env` (git-ignored)
  and put the Claude key there. The key never ships in the app.

## Widgets, Lock Screen and Dynamic Island

- **What they show:** the warmer foot's temperature, both soles live (tap to
  step Temperature → Pressure → Gait, the same single values as Home), a
  30-minute temperature curve coloured by temperature (comfort band, dashed
  38° line, the latest point haloed, as in the app's chart), both batteries,
  the mode and any concern. No rate or integral figures.
- **Sizes:** Home Screen small, medium and large; Lock Screen rectangular,
  circular and inline (monochrome: warmth reads as brightness); the Live
  Activity banner; the Dynamic Island compact (both soles, a mode dot, a
  battery mark when low), minimal and expanded.
- **Buttons:** Auto / Cool / Heat / Off on medium, large, the banner and the
  expanded island (`SetThermalModeIntent`, a Live Activity intent that runs
  in the app's process). A press leaves a request in the App Group
  (`ThermyxModeInbox`) and wakes the app, which applies it through the same
  `select` as the in-app control, so the heat lockout holds (Heat shows a lock
  at High risk and above). Requests expire after two minutes. Insole
  Bluetooth lives in the app, so a press works while the app is running or
  being kept alive by connected insoles.
- **Reviewing without a device:** `-ThermyxUIPreview widgets` draws every
  surface at its real size from sample data (debug builds). The views live in
  `Shared/ThermyxWidgetParts.swift` and `ThermyxWidgetLayouts.swift`.

## Permissions, AI Insights and charts

- **Permissions** (`Services/ThermyxPermissions.swift`,
  `Views/User/PermissionsSection.swift`): wherever an iOS switch blocks a
  feature there is a button that fixes it. Allow shows iOS's prompt; once
  declined, Open Settings goes to Thermyx's page; Apple Health opens the
  Health app; Bluetooth that is off gets Turn On. Safety → Device lists them
  all. They are read again whenever the app returns to the front.
- **AI Insights** (`aiInsightsEnabled`, off by default) gates the daily AI
  summary in Insights and the end-of-session summary notification. Requests
  go to the relay, which calls Anthropic's Claude API with its own key
  (`ThermyxBackend`, `POST /v1/summary`).
- **Charts are coloured by value** (`ChartValueScale` in
  `Components/ThermyxCharts.swift`): temperature on the foot maps' thermal
  ramp, load on the pressure maps' jet ramp, gaps and rates on diverging
  scales, steadiness from ember to ice. A line's gradient is stretched over
  its own range, so each point sits on its colour on the y axis.
- **Spacing** follows one rhythm (`Thermyx.Space`): 10 above a tab title, 20
  under it, 12 from a section's title to its content, 32 between sections,
  24 between groups on a form.

## Onboarding

The interactive insole and Google sign-in → Profile (how you'll use Thermyx, what it's
mostly for, units) → About you → insoles → calibration, then a spotlight
tutorial on Home. A watcher goes from Profile to who they watch.

- **About you** asks for name, age, sex (male or female), height, weight,
  shoe size, Insights focus and health conditions, all required. Apple Health
  can fill in age, sex, height and weight first.
- **Profile** ends with the **AI Insights** switch (deep purple, off by
  default). It flags that it uses a Claude API key, says what is sent, and
  links the Privacy Policy (section 2.8) and Terms of Service (section 16).
- **Insoles**: one search finds both; each row says Left or Right. Bluetooth
  permission is asked here, with an Allow button, not at launch; if the radio
  is off, Turn On shows iOS's own alert, which links to Bluetooth settings.
  **Scan again** stops the search, forgets every device heard so far and
  starts over.
- **Calibration** (`Views/Onboarding/Calibration.swift`, design O4): sit, stand
  and walk for 30 seconds each, indoors then outdoors, shown as a table. The
  live maps show only what the insoles measure. The readouts fill in live:
  foot temperature, rate of change (dT/dt, a least-squares slope over 10 s),
  accumulated change (∫ dT/dt dt, trapezoid rule), load, cadence and walking
  stability. Heating and cooling pause while it records. The model learns
  usual temperatures indoors and out, each step's dT/dt and ∫, load, cadence,
  and a walking-steadiness profile (`Models/ThermalCalculus.swift`).
- Calibration's **Before you start** checklist is folded to one row that
  says how many checks pass, and a strip of live readings (each foot, dT/dt,
  load or cadence) stays pinned above the buttons.
- **Tutorial** (`Views/User/SpotlightTutorial.swift`, design O5): dims Home
  except one control at a time, and for the Temperature map tab and the mode
  button waits for the wearer to try it. It runs once after onboarding;
  replay it from Safety → Device.

## Simulator

The **Simulator** tab (`Views/Simulator`, `Models/ThermalSimulation.swift`) is
an educational sandbox: pick a scenario (job site, race pace, winter patrol,
wet boots, ruck march, desk day) or set air temperature, humidity, sun,
activity, footwear and fit, pack weight, acclimatization, favouring a foot,
the simulated insoles' mode and target, connection, a sensor fault and the
battery, and apply recovery actions. Each simulated minute, a simple
illustrative model moves the feet; everything after that is the app's real
logic: `ThermyxRiskEngine` and `PersonalLayer` decide the level, the heat
lockout works as on Home, and Auto, Cool, Heat and the 40 °C burn cutoff
behave as the firmware does. The simulated insoles report only what real ones
measure (foot temperature, one arch load, motion). A passive twin runs
alongside, so the chart compares the same feet with and without Thermyx.
Every screen is labelled Simulated, and nothing is sent.

## Learn

Eight newspaper-style articles (`Resources/Content/learning-articles.json`):
what to do when a foot overheats, footwear fit and pressure, recovery after
heat, unreliable sensor data, heat illness, cold feet and frostbite,
hydration, and acclimatization. Each has a photograph, the disclaimer that
it's educational and not a diagnosis, and APA 7 references. The reader
offers text size, five colour themes (including sepia and yellow-on-black
high contrast), serif or sans type, wider spacing, read-aloud that follows
along, and a line reader. `LearningSuggestion` picks the lesson for what's
happening now (shown on Learn and, at Caution and above, on Home), from the
same live readings the risk engine sees.

