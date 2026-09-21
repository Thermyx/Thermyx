# Thermyx BLE protocol

The XIAO firmware must advertise the following BLE service:

- Service: `7B7E0001-7A3B-4D2D-9C9E-000000000001`
- Telemetry characteristic: `7B7E0002-7A3B-4D2D-9C9E-000000000001`
- Command characteristic: `7B7E0003-7A3B-4D2D-9C9E-000000000001`

The app scans for the service, lists what it finds, connects to the device the
user picks, discovers both characteristics, and enables notifications on
telemetry.

## Telemetry

Two packet versions are in service. The app decodes both; firmware may ship
either. All multi-byte fields are little-endian.

### Version 1 — 12 bytes

| Byte(s) | Meaning |
|---|---|
| 0 | Protocol version: `1` |
| 1 | Mode: `0` off, `1` heating, `2` cooling, `3` ventilation |
| 2 | Battery percentage: `0–100` |
| 3–4 | Foot temperature in °C × 100, signed int16 |
| 5–6 | Ambient temperature in °C × 100, signed int16 |
| 7–8 | Gait stability × 10000, unsigned uint16 |
| 9–10 | Pressure balance × 10000, unsigned uint16 |
| 11 | Reserved flags byte; send `0` initially |

### Version 2 — 18 bytes

Version 2 is version 1 with three per-zone contact temperatures appended.
Bytes 0–11 are unchanged, except that byte 0 carries `2` and bytes 3–4 are the
**average** of the three zones.

| Byte(s) | Meaning |
|---|---|
| 0–11 | As version 1, with version = `2` |
| 12–13 | Forefoot temperature in °C × 100, signed int16 |
| 14–15 | Arch temperature in °C × 100, signed int16 |
| 16–17 | Heel temperature in °C × 100, signed int16 |

Three-zone sensing is a **hardware goal, not a launch dependency.** A v1 insole
with the two thermistors in the current prototype is fully supported: the app
receives no zones, collapses the Home zone readouts to the single foot average,
and hides the zone heat map on Insights entirely. If the third and fourth
thermistors land later, the firmware switches to v2 and the zone map lights up
with no app changes.

A zone channel that is disconnected or out of range should report a value
outside −20…80 °C. The app treats any implausible zone as all three being
absent, rather than drawing a heat map off a broken channel.

## Commands

Commands are two bytes: `[1, mode]`, using the same mode values above. The
firmware should acknowledge writes and continue sending telemetry at a defined
interval, such as 1 Hz.

The app's control bar sends `cooling` for Cool, `ventilation` for Auto, and
`heating` for Heat. **The app will not send `heating` while its risk engine is
at High Risk or Critical** — it locks the Heat control out and commands cooling
instead. Firmware must still enforce its own independent cutoffs; the app-side
lockout is a second layer, not the primary safety mechanism.

## Honest output

The app intentionally shows no values until it receives a valid packet, and
drops back to its empty state on disconnect rather than leaving the last
reading on screen as though it were live. The UUIDs and packet format are an
interface contract; changing firmware values requires changing the decoder and
testing them together.

### Version 3 — 22 bytes

Version 3 is version 2 with two IMU-derived movement channels appended. These
need **no new hardware** — the XIAO nRF52840 Sense already carries the IMU — so
a v2 insole can move to v3 with a firmware update alone.

| Byte(s) | Meaning |
|---|---|
| 0–17 | As version 2, with version = `3` |
| 18–19 | Cadence in steps per minute × 10, unsigned uint16 |
| 20–21 | Standing fraction × 10000, unsigned uint16 |

**Standing fraction** is the proportion of the reporting window during which the
insole was loaded but not stepping, `0`–`10000`. It is a per-window proportion
rather than a running total so that the app can aggregate it into its minute and
hour buckets without double counting across reconnects.

Both fields use `0xFFFF` as an explicit "not measured" sentinel. A firmware that
cannot compute one should send `0xFFFF` rather than `0` — the app treats zero as
a genuine zero (standing still, or not walking) and the sentinel as no data, and
renders an empty state for the latter.

## Which foot an insole is on

Thermyx runs as a pair. The app holds an independent link to each insole and
needs to know which foot each one serves.

**Byte 11 (the flags byte) carries it**, in bits 0–1:

| Value | Meaning |
|---|---|
| `0` | Unspecified — the app asks the user to assign the foot at pairing |
| `1` | Left |
| `2` | Right |

Bits 2–7 remain reserved; send `0`.

This is backward compatible: a v1 firmware that sends `0` in the flags byte, as
the original spec instructed, simply falls through to manual assignment.

A firmware may also advertise a peripheral name containing `left` or `right`,
which the app uses to pre-select the foot in the pairing list. The flags byte
is authoritative when both are present.

Nothing in the app assumes a pair. One insole connected and one not is an
ordinary state: the connected foot shows live data, the other shows its own
empty state, and no value from one foot is ever shown for the other.
