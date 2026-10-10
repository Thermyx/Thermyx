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
- **Alerts.** The wearer is notified when the level rises. Approved watchers
  see the current level and how fresh it is; a heartbeat is posted every
  minute so a watcher sees "No update for N min" when the wearer's phone goes
  quiet. **Texting trusted contacts is off** until the relay's `SMS_ENABLED`
  is turned on after testing with real phones; until then the app shows a
  labelled "Preview · not sent" of the message.
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
    SoleGeometry.swift  The sole outline, its coordinate system, and sizes.
  Models/             ThermyxReading, risk levels, roles, contacts, units,
                      Learning Center content model.
  Services/           BLE ingestion, settings, retained history, HealthKit,
                      alert delivery.
  ViewModels/         ThermyxViewModel (live state), InsightsDigest (chart
                      derivations), TrustedMemberViewModel.
  Views/
    Onboarding/       Three animated steps: intro, role, pair.
    User/             Home, Insights hub, Temperature, Movement, Learning,
                      Article, Safety, Advanced.
    Trusted/          Watch, Insights, Settings.
  Resources/
    Fonts/            Archivo + Archivo Narrow (SIL OFL).
    Content/          Learning Center articles, Privacy Policy, Terms.
```

**Navigation.** Three tabs — Home, Insights, Safety. A thermal control bar
(Cool / Auto / Heat) sits above the tab bar on those three plus Advanced;
pushed reading screens omit it so charts get the height. The Trusted Member
role gets its own three tabs and **no** control bar: a watcher can see and can
call, but cannot actuate someone else's insole.

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
xcrun simctl launch booted com.thermyx.app -ThermyxUIPreview homeZones
```

Use the `-ThermyxUIPreview` flag with one of these states:

- Onboarding: `onboardingRole`, `onboardingPair`
- Home: `home`, `homeZones`, `homeOneFoot`, `homeCaution`, `profile`, `tour`
- Insights: `insights`, `health`, `temperature`, `movement`, `movementAdvanced`,
  `balance`, `learning`, `article`
- Safety: `safety`, `advanced`, `legal`
- Trusted Member: `trusted`, `trustedSample`, `trustedSampleInsights`

The harness seeds only synthetic readings and fictional people. Its phone
numbers are from NANPA's reserved `555-01xx` fictional range; they cannot
reach a real person.

## Going live

### Prototype 1 deployment checklist

Prototype 1 is for supervised field evaluation, not an emergency-response or
medical-device release. Before distributing it through TestFlight:

- Build and run the **Release** configuration from Xcode on a physical test
  device, then archive it through Xcode for TestFlight.
- Fill every bracketed field in both legal documents, replace placeholder
  Learning Center copy, and confirm the onboarding video is approved.
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
with two simulated insoles inside `ThermyxBLEService`, so every control works on
the iOS Simulator: scan, pair, disconnect, Cool / Auto / Heat (the temperature
responds), the Auto target slider, the heat lockout, and alerts.
`simulatorOnboarding` does the same from the start of onboarding. A
**Simulated conditions** card at the top of Safety → Advanced sets the air
temperature and whether the wearer is tiring, which is enough to walk the risk
level up every rung.

The same simulated pair ships as **Demo Mode** (Safety → Advanced → Demo
Mode), so the app can be shown without hardware in any build. It is off at
every launch, disconnects real insoles while it runs, and never sends
anything to the relay or writes to history, Apple Health, or the personal
baseline. Every screen carries "Simulated — not live sensor data" while it
runs, in debug and release builds alike.

### Retiring the harness entirely

When hardware is reliable enough that the harness is no longer useful, delete
it in this order and verify a Release archive manually:

1. Delete `DesignSystem/ThermyxPreviewHarness.swift`.
2. `ThermyxApp.swift` — remove the `.previewHarness(…)` call and the `#if !DEBUG`
   shim beneath it.
3. `Services/ThermyxBLEService.swift` — remove the `#if DEBUG` preview
   injection. (The simulator itself stays: it powers Demo Mode.)
4. Remove the `#if DEBUG` initial-state blocks in `Views/RootView.swift` (tab
   selection and the notification-prompt guard),
   `Views/User/InsightsHubView.swift` and `Views/User/SafetyView.swift`
   (navigation paths), `Views/Onboarding/OnboardingFlow.swift` (step), and
   `Views/User/AdvancedView.swift` is unaffected: its Demo Mode section stays.
5. Delete the **Thermyx Demo** scheme.
6. Regenerate the Xcode project, build a Release archive, and verify that a
   preview launch argument has no effect.

## Credits and licences

- **Archivo** and **Archivo Narrow** — Omnibus Type, SIL Open Font License 1.1.
  Static instances cut from the Google Fonts variable sources with `fonttools`.
  Licence ships in the bundle as `OFL.txt`.
- **SF Symbols** — Apple, used under the SF Symbols licence.
- **Swift Charts**, **HealthKit**, **CoreBluetooth** — Apple system frameworks.
- Brand artwork (app icon, circular badge, horizontal wordmark) supplied by the
  Thermyx team. The horizontal wordmark is navy ink and is used only on light
  grounds — on the app background it sits at roughly 1.4:1. It is never
  recoloured in code; a light-ink export is needed before it can go on dark.

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


## The onboarding walkthrough

The first onboarding screen plays `Resources/Media/onboarding-walkthrough.mp4`:
muted, looping, no controls, no audio session, and it never interrupts what the
user is listening to. Under Reduce Motion it holds on the poster frame. If the
file is missing from the bundle it falls back to the animated sole rather than
showing a black rectangle.

**The bundled file is a placeholder** — a simulator capture of this app running
on preview data. `Resources/Media/README.md` covers what should replace it and
the constraints for the replacement.
