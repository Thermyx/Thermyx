# Thermyx Privacy Policy

**Effective date:** 2026

**Last updated:** September 21, 2026

Thermyx Technologies ("Thermyx", "we", "us") makes the Thermyx smart insole
and the Thermyx iPhone application (together, the "Service"). This policy
explains what the Service collects, why, how long it is kept, who it is shared
with, and the choices you have. It applies to the app and to data the insole
sends to it.

Read this together with the Thermyx Terms of Service, which explain the limits
of what the Service can do.

## 1. The short version

- **Your readings stay on your phone by default.** Foot temperature, pressure,
  movement, and battery data are stored locally. We do not operate a cloud
  service that collects them.
- **Nothing leaves your phone unless you turn it on.** The only outbound data
  flow is the optional trusted-circle feature, which sends escalated risk events
  to a backend address that you configure.
- **We do not sell your data, and we do not use it for advertising.** We do not
  use it to build profiles for any purpose other than operating the Service for
  you.
- **Health data is handled under Apple's rules.** Data read from or written to
  Apple Health is never used for advertising, never sold, and never disclosed to
  a third party without your explicit permission.
- **You can export or delete everything** from Safety → Advanced.

## 2. Information the Service handles

### 2.1 Sensor data from the insole

When an insole is paired and connected over Bluetooth Low Energy, the app
receives telemetry packets containing:

- foot-contact temperature, and, on supported hardware, separate forefoot, arch,
  and heel temperatures;
- ambient temperature and humidity from the intake sensor;
- pressure distribution and balance across the sensing array;
- movement signals derived from the controller's inertial measurement unit,
  including gait stability, cadence, and standing time;
- heating, cooling, and blower state;
- battery level and sensor quality flags.

These are written to a local store on your device. The app aggregates them into
one-minute buckets retained for seven days and one-hour buckets retained for
180 days. Raw packets are not retained beyond that aggregation.

### 2.2 Profile information you enter

Your display name, shoe or insole size, pairing code, device identifier, and
your preferences (temperature unit, alert thresholds, and similar) are stored
locally in your device's standard application preferences.

### 2.3 Trusted contacts

If you add someone to your trusted circle, the name and phone number you enter
are stored locally on your device. They are transmitted only when an escalation
you configured actually fires, and only to the backend address you configured.

**You are responsible for having that person's permission** before adding them.
See section 8.

### 2.4 Apple Health data

Apple Health integration is **off by default**. If you turn it on and grant
permission, the Service:

- **reads** your step count, walking steadiness, and workout sessions, to place
  heat exposure in the context of what you were doing;
- **writes** completed Thermyx sessions as workout samples, so time on your feet
  and heat exposure appear alongside your other health data.

The Service does **not** request permission to write body temperature. The
insole measures contact temperature at the surface of the foot, which is not
core body temperature; recording it under that type would misrepresent it.

Apple Health data is read on demand and is not copied into our own storage
beyond what is needed to render the current screen.

### 2.5 Location

The Service requests location only in connection with the emergency and trusted
circle features, and only if you have opted in. Location is transmitted only
during an explicitly enabled emergency escalation. The Service does not track
your location in the background, does not build a location history, and does not
use location for any purpose other than the emergency flow you enabled.

### 2.6 Bluetooth

Bluetooth access is used solely to discover, connect to, and exchange data with
Thermyx insoles. The Service does not use Bluetooth for proximity marketing,
beacon tracking, or identifying nearby devices for any purpose other than
pairing.

### 2.7 Diagnostics

If you choose to share diagnostics through Apple's standard reporting
mechanisms, Apple may provide us crash logs and performance data. These are
governed by Apple's privacy policy and are not linked to your identity by us.

### 2.8 What the Service does not collect

We do not collect your contacts list, your photos, your microphone or camera,
your browsing activity, your advertising identifier, or your precise location
outside the emergency flow described above.

## 3. How information is used

| Purpose | Data used | Basis |
|---|---|---|
| Show live readings and risk state | Sensor data | Operating the Service you requested |
| Build your personal baseline and trends | Aggregated sensor history | Operating the Service you requested |
| Warn you, and optionally your trusted circle | Sensor data, risk state, contacts | Your consent, and protection of vital interests in an emergency |
| Place heat exposure in context | Apple Health read data | Your explicit consent |
| Record sessions in Apple Health | Session summaries | Your explicit consent |
| Emergency escalation | Location, contacts | Your explicit opt-in |

We do not use your data for advertising, for automated decisions producing legal
or similarly significant effects, or for training machine-learning models.

## 4. Where information is stored and who can see it

**On your device.** Sensor history, profile, preferences, and trusted contacts
are stored in the app's container, protected by iOS file protection and your
device passcode.

**On a backend you configure.** If — and only if — you enter a backend address,
escalated risk events are sent there. **That backend is operated by whoever runs
it, which in a self-hosted or school deployment may be you or your team, not
us.** We do not control it, and this policy does not govern what it does with
data it receives. Do not configure a backend you do not trust.

**Apple.** Apple Health data remains under Apple's control and your Health
permissions.

We do not maintain a central database of user readings.

## 5. Sharing

We do not sell personal information, and we do not share it for cross-context
behavioural advertising. We share information only:

- with the backend you configured, as described above;
- with your trusted contacts, in the form of the alerts you configured;
- with emergency services, when you use the SOS control;
- where required by law, after reviewing the demand and, where legally
  permitted, notifying you;
- with a successor entity in a merger or acquisition, subject to this policy.

## 6. Retention and deletion

| Data | Retained |
|---|---|
| One-minute reading buckets | 7 days, then deleted automatically |
| One-hour reading buckets | 180 days, then deleted automatically |
| Risk events | 30 days |
| Personal baseline | Until reset or deleted; discarded after 90 days unused |
| Profile, preferences, contacts | Until you change or delete them |
| Relay: current level and time | 7 days after the last update |
| Relay: location (only during a consented High, Critical, or SOS event) | 1 hour, and cleared when the event ends |

**Delete my data** is in Safety → Advanced. It removes your history, personal
baseline, and trusted contacts from the device immediately and irreversibly,
disconnects the relay, and deletes what the relay holds about you, which also
ends every watcher's access. **What leaves your phone?** on the same screen
lists exactly what is shared and when. Deleting the app
removes everything the app stored. Removing Health permissions stops all access;
samples already written to Health are managed in the Health app.

## 7. Your rights

Depending on where you live you may have the right to access, correct, delete,
port, or restrict processing of your personal information, and to object to
processing or withdraw consent.

Because your data is held on your own device, most of these are exercised
directly in the app: view it on the Insights screens, correct your profile in
settings, export or delete it under Advanced, and withdraw consent by turning
off Health, location, or the trusted circle.

**California (CCPA/CPRA).** We do not sell or share personal information as
those terms are defined. You have the right to know, delete, correct, and to
non-discrimination for exercising those rights.

**EEA/UK (GDPR).** Our lawful bases are consent (Article 6(1)(a)) for optional
features, performance of a contract (6(1)(b)) for operating the Service, and
protection of vital interests (6(1)(d)) for emergency escalation. Health data is
special-category data processed on the basis of explicit consent (Article
9(2)(a)). You may lodge a complaint with your supervisory authority.

To make a request, contact us at [CONTACT EMAIL]. We will respond within the
period required by applicable law.

## 8. Trusted contacts and other people's data

When you add a trusted contact you are giving us another person's name and phone
number. **You must have their permission.** You are responsible for telling them
what they will receive and why. If a trusted contact wants their details removed
they can ask you, or contact us at [CONTACT EMAIL].

## 9. Children

The Service is not directed to children under 13, and we do not knowingly
collect personal information from them. If you believe a child has provided us
information, contact [CONTACT EMAIL] and we will delete it. Where the Service is
used by a minor in a supervised setting, a parent or guardian is responsible for
consenting on their behalf.

## 10. Security

Readings are stored in the app's protected container on your device. Bluetooth
telemetry is exchanged over a local link with the insole. If you configure a
backend, use an HTTPS endpoint; the app will send an authorisation token if you
provide one.

No system is perfectly secure. Protect your device with a passcode, keep iOS up
to date, and do not configure a backend you do not control or trust.

## 11. International transfers

The Service does not transfer your data internationally, because it does not
send it to us. If you configure a backend, transfers depend on where that
backend is hosted, which is your choice.

## 12. Changes

If we change this policy materially we will update the date above and surface
the change in the app before the change takes effect. Continued use after a
change means you accept the updated policy.

## 13. Contact

Thermyx Technologies

aaronhanqin@gmail.com

---

*This document describes an investigational product. See the Terms of Service
for what Thermyx does not do and must not be relied upon for.*
