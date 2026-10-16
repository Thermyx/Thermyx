# Thermyx Privacy Policy

**Effective date:** 2026

**Last updated:** October 15, 2026

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
- **Nothing leaves your phone unless you turn it on.** The outbound data flows
  are all optional: the trusted circle, which sends escalated risk events to a
  relay you connect; **AI Insights**, which sends one day's totals and averages
  to Anthropic's Claude API through that relay (section 2.8); and local
  weather, which sends a rounded location to Open-Meteo during calibration
  (section 2.5). Signing in with Google creates an account, covered in section
  2.9.
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

### 2.2a Recovery tests and your safety plan

If you run a Thermal Recovery Test or log what you did after an alert, the
result (the start and end temperature at the insole, how still you were, and
the steps you ticked) is stored on your device. It is never sent to the relay
or your trusted circle, and it is deleted by **Delete my data**. The safety
plan and readiness profile are calculated on your device from your own
history, describe what is usual for you, and are not medical advice.

### 2.3 Trusted contacts

If you add someone to your trusted circle, the name and phone number you enter
are stored locally on your device. Numbers are transmitted only when an alert
you configured actually fires, and only to the backend address you configured,
which texts them and does not store them. During an active High risk, Critical
or SOS event the backend keeps the numbers in memory, so it can tell your
contacts if your phone stops updating; they are forgotten when the event ends,
or after an hour at most.

**What your circle is told.** Alerts, and the status card approved watchers
see, contain: the name you choose for alerts; the risk level; which foot (and,
on insoles that sense zones, heel, arch or forefoot); that foot's contact
temperature at the insole and whether it is rising or falling; whether the
data is confirmed or limited; a low insole battery or weak connection, only
when that applies; your local time; what Thermyx asked you to do; and when you
checked in as OK. They never receive your history, a live stream of readings,
your profile or health conditions, or control of your insoles. The backend
keeps only the latest status card and a short timeline of the current event
for your watchers. If you are a watcher and allow notifications, your phone's
Apple push token is sent to the backend so alerts reach you with the app
closed; it is used only for that, and sent on to Apple to deliver the alert.

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

The Service requests location for two things, and only once you allow it:
the emergency and trusted circle features, if you have opted in, and the
outdoor half of calibration, which looks up the outside air temperature. For
the weather, the location is rounded to about 1 km and sent to Open-Meteo
(open-meteo.com), a free weather service, which returns the current
conditions. For emergencies, location is shared with your circle only at High risk,
Critical, or SOS, and only while "Share my location in emergencies" is on. It
is on by default once you add a trusted contact or invite a watcher, explained
before you do, and you can turn it off at any time; alerts then say "Location
not shared". The Service does not track
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

### 2.8 AI Insights (optional, off by default)

AI Insights writes a short summary of a day of wear, with two or three
suggestions, using **Claude, a model made by Anthropic, PBC** ("Anthropic"),
through the Claude API. The request goes from your phone to the relay you
connected, and the relay calls the Claude API with **its own API key**; your
phone never holds that key.

It runs **only if you turn it on** (during setup, or in Safety → Device → AI
Insights) and only while it stays on, and **at most once a day**: in the
evening, after you take the insoles off, or the next time you open the app
for a day that didn't get one. Each request contains **only that day's totals
and averages**: the date, time worn, minutes heating and cooling, average,
peak and lowest foot temperature, average air temperature, hours spent warm,
estimated steps, minutes walking, standing and sitting, average cadence and
walking steadiness, the highest risk level reached and the number of safety
events, your temperature unit, whether Insights should lead with health or
performance, and which of the app's fixed options you chose for what Thermyx
is mostly for (for example "Outdoor work"). It does **not** contain live readings, your name,
your email, your trusted contacts, your location, or Apple Health data.

The relay passes the request to Anthropic and returns the reply; it does not
store or log the numbers or the summary. The summary is kept on your phone for
that day. Anthropic processes the request under its own commercial terms and
privacy policy (anthropic.com/legal), which say that data sent through its API
is not used to train its models; it may keep requests for a limited time under
those terms, for example to monitor for misuse. Turning AI Insights off stops
all further requests.

### 2.9 Your Thermyx account

Signing in with Google gives Thermyx your Google account's name, email address
and a user identifier, through Google's Firebase Authentication. They are used
only to sign you in and to recognise team accounts. Deleting your account
removes it from Firebase.

### 2.10 What the Service does not collect

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
| Write your daily AI Insights summary | One day's totals and averages | Your consent (AI Insights, off by default) |
| Air temperature during calibration | Location rounded to about 1 km | Your consent (location permission) |

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

**Anthropic.** If you turn on AI Insights, each day's totals and averages are
processed by Anthropic to write the summary, as described in section 2.8.

We do not maintain a central database of user readings.

## 5. Sharing

We do not sell personal information, and we do not share it for cross-context
behavioural advertising. We share information only:

- with the backend you configured, as described above;
- with Anthropic, only if you turn on AI Insights, and only the day's totals
  and averages described in section 2.8;
- with Open-Meteo, a rounded location, only when calibration looks up the
  outside air temperature;
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
| Relay: latest status card and the current event's timeline | 7 days after the last update |
| Relay: a watcher's push notification token | Until they stop watching or are removed |
| Relay: contacts' numbers during an active event | In memory only, until the event ends (1 hour at most) |
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
off Health, location, AI Insights, or the trusted circle.

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
backend is hosted, which is your choice. If you turn on AI Insights, the day's
totals and averages are processed by Anthropic, which operates in the United
States.

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
