# Thermyx

iPhone app for the Thermyx smart insole: a BLE wearable that senses foot
temperature, pressure, and movement, and actively heats or cools within hard
safety limits.

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

A sustained gap raises **caution on its own** — favouring one foot is both a fit
problem and a fatigue signal. It never escalates past caution by itself: a
difference between feet is not the same kind of evidence as a foot that is
simply too hot.

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

## Where the data comes from

```
insole sensors
   → XIAO nRF52840 firmware
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
- Configure the production backend URL and token in the app only after the
  backend is deployed behind HTTPS. Store the token in device settings; never
  commit it.
- Keep the alert relay under supervised use. It stores latest status only in
  memory and is not a durable notification, emergency, or audit system.

The deployment and operator runbook for the relay is in
[`ThermyxBackend/README.md`](ThermyxBackend/README.md).

The app is already wired for real data; nothing needs to be swapped out. In
order:

**1. Firmware — the only blocker.** Flash the XIAO with firmware implementing
`ThermyxApp/BLE_PROTOCOL.md`. The UUIDs, byte order, scaling, and mode values
must match exactly. Then: turn on the insole → open Thermyx → Home header or
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

**4. Learning Center copy.** `Resources/Content/learning-articles.json` ships
six real headlines with outline bodies, each marked `"status": "placeholder"`.
Write and cite each one, then change its status to `"published"`. The draft
banner and badges disappear on their own once nothing is a placeholder. **No
statistics have been filled in anywhere — do not ship a figure that has not
been checked against its original publication.**

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

### Retiring the harness entirely

When hardware is reliable enough that the harness is no longer useful, delete
it in this order and verify a Release archive manually:

1. Delete `DesignSystem/ThermyxPreviewHarness.swift`.
2. `ThermyxApp.swift` — remove the `.previewHarness(…)` call and the `#if !DEBUG`
   shim beneath it.
3. `Services/ThermyxBLEService.swift` — remove the `#if DEBUG` extension at the
   end of the file.
4. Remove the `#if DEBUG` initial-state blocks in `Views/RootView.swift` (tab
   selection and the notification-prompt guard),
   `Views/User/InsightsHubView.swift` and `Views/User/SafetyView.swift`
   (navigation paths), and `Views/Onboarding/OnboardingFlow.swift` (step).
5. Regenerate the Xcode project, build a Release archive, and verify that a
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

The eight FSR positions from the prototype are defined in
`SoleGeometry.SensorSite`, placed against the outline's measured width profile.
Every site clears the edge by at least **0.054 of foot length** — about 16 mm at
US 12, comfortably more than an FSR 402 needs.

| Site | Sole space (x, y) | Zone |
|---|---|---|
| Lateral heel | −0.022, 0.13 | Heel |
| Medial heel | 0.096, 0.13 | Heel |
| Lateral midfoot | −0.094, 0.42 | Arch |
| Medial midfoot | 0.083, 0.44 | Arch |
| 5th metatarsal | −0.137, 0.66 | Forefoot |
| 3rd metatarsal | −0.001, 0.70 | Forefoot |
| 1st metatarsal | 0.140, 0.72 | Forefoot |
| Hallux | 0.143, 0.90 | Forefoot |

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
