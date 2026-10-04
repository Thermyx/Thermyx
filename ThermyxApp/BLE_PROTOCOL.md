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
| 2 | Battery percentage: `0–100`; `0xFF` = not measured |
| 3–4 | Foot temperature in °C × 100, signed int16 |
| 5–6 | Ambient temperature in °C × 100, signed int16 |
| 7–8 | Gait stability × 10000, unsigned uint16; `0xFFFF` = not measured |
| 9–10 | Pressure balance (forefoot share of load) × 10000, unsigned uint16; `0xFFFF` = not measured |
| 11 | Flags: bits 0–1 which foot (see [Which foot an insole is on](#which-foot-an-insole-is-on)); bits 2–3 setting echo; bit 4 burn cutoff; bits 5–7 reserved, send `0` |

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

Foot and ambient temperatures outside −20…80 °C are treated as missing, so a
disconnected sensor can send `INT16_MIN` (`0x8000`) and the app shows a dash
rather than a number.

Three-zone sensing is a **hardware goal, not a launch dependency.** A v1 insole
with the two temperature sensors in the current prototype (one contact, one
ambient) is fully supported: the app
receives no zones, collapses the Home zone readouts to the single foot average,
and hides the zone heat map on Insights entirely. If the third and fourth
thermistors land later, the firmware switches to v2 and the zone map lights up
with no app changes.

A zone channel that is disconnected or out of range should report a value
outside −20…80 °C. The app treats any implausible zone as all three being
absent, rather than drawing a heat map off a broken channel.

## Commands

Commands are written with response to the command characteristic. The firmware
should keep sending telemetry at a defined interval, such as 1 Hz.

| Bytes | Command |
|---|---|
| `[1, mode]` | Set the mode, using the mode values above. `3` (ventilation) is the app's **Auto**: the firmware regulates towards the target temperature and reports the mode it is actually running. |
| `[2, lo, hi]` | Set Auto's target foot temperature: int16 °C × 100, little-endian. The app sends 26–38 °C; firmware should clamp to that range. Sent on connect and whenever the wearer moves the Advanced slider. Firmware that predates this command can ignore it. |

The app's control bar sends `cooling` for Cool, `ventilation` for Auto, and
`heating` for Heat. **The app will not send `heating` while its risk engine is
at High Risk or Critical** — it locks the Heat control out and commands cooling
instead. Firmware must still enforce its own independent cutoffs; the app-side
lockout is a second layer, not the primary safety mechanism.

The reference firmware (`firmware/thermyx_insole`) enforces: no heating at or
above **40 °C** foot contact (the app's burn-protection limit, which also
raises High risk on its own), no cooling at or below 15 °C, no heating or
cooling without a foot temperature, and no heating while no phone is
connected.

## Honest output

The app intentionally shows no values until it receives a valid packet, and
drops back to its empty state on disconnect rather than leaving the last
reading on screen as though it were live. The UUIDs and packet format are an
interface contract; changing firmware values requires changing the decoder and
testing them together.

### Version 3 — 22 bytes

Version 3 is version 2 with two IMU-derived movement channels appended. These
come from the GY-521 (MPU-6050) motion sensor already on the prototype's I2C
bus, so a v2 insole can move to v3 with a firmware update alone. A v1-sensor
insole can still send v3: it fills the zone fields with an out-of-range value
and the app ignores them.

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

**Bits 2–3: setting echo.** The setting the insole is following: `1` Cool,
`2` Auto, `3` Heat, `0` not reported. The app waits for every connected insole
to echo a new setting and says so plainly if one has not within six seconds.
Firmware that sends `0` here is still supported: the app then confirms from
byte 1 (Cool once it is cooling, Heat once it is heating or cut off, Auto on
the next packet).

**Bit 4: burn cutoff.** Set while the firmware is holding the heater off at
the burn limit, so the app can tell "Heat refused for safety" from "Heat
ignored".

Bits 5–7 remain reserved; send `0`.

This is backward compatible: a v1 firmware that sends `0` in the flags byte, as
the original spec instructed, simply falls through to manual assignment.

A firmware may also advertise a peripheral name containing `left` or `right`,
which the app uses to pre-select the foot in the pairing list. The flags byte
is authoritative when both are present.

Nothing in the app assumes a pair. One insole connected and one not is an
ordinary state: the connected foot shows live data, the other shows its own
empty state, and no value from one foot is ever shown for the other.

## Single-sensor test board (XIAO ESP32-C3)

A second, much simpler firmware is supported alongside the insole protocol
above, for bench tests with one analog input. The app scans for both and
handles each on its own path (`ThermyxSensorProtocol`,
`Models/ThermyxAnalogInput.swift`).

| Item | Value |
|---|---|
| Device name | `Thermyx` |
| Service UUID | `7a1b0001-3c5d-4e6f-8a9b-0c1d2e3f4a5b` |
| Characteristic UUID | `7a1b0002-3c5d-4e6f-8a9b-0c1d2e3f4a5b` (READ, NOTIFY) |
| Value | UTF-8 text of an integer `0`–`4095` (12-bit ADC, 0–3.3 V), e.g. `2048` |
| Rate | About every 500 ms |

- The app connects to the board **by itself** whenever Bluetooth is on and no
  board is connected: no list, no tap. It reads the value once on connect,
  then subscribes to notifications. A dropped board is reconnected
  automatically; a board the user disconnects stays disconnected until the
  next scan.
- Anything that is not a whole number in 0–4095 is rejected, not clamped.
- The board occupies one foot slot (left, unless a full insole is remembered
  there) and takes no commands; Cool / Auto / Heat need a full insole.
- **What the value means is set in the app, never assumed** (Safety →
  Advanced → Test board): *Test input* (raw + percent, the default),
  *FSR402 pressure* (approximate force in N and pressure in kPa; see below), or *Temperature*, which only appears once a
  calibration is set in code (`AnalogTemperatureCalibration.current`, with
  ready-made `.ntcDivider()` and `.linear(…)` options). A test input or FSR
  value is kept in its own history and never feeds temperature charts, risk
  levels, alerts, or Apple Health.

### FSR402 conversion

Wiring: 3.3 V → FSR402 → ADC node → 10 kΩ → GND, 12-bit ADC over 0–3.3 V.

1. V = raw / 4095 × 3.3
2. raw < 15 is no touch: 0 N
3. R_fsr = 10,000 × (3.3 − V) / V
4. G = 1,000,000 / R_fsr µS (the app computes 100 × V / (3.3 − V), so
   raw 4095 gives an infinite conductance instead of dividing by zero)
5. F = G / 80 N, clamped to 0–20 N, × the calibration scale
   (Safety → Advanced → Test board, default 1.00)
6. Pressure = F / 0.1267 kPa (12.7 mm round active area)

Force is the main value and kPa is secondary, both labelled "approx.". The
raw ADC count appears only as a debug line on Safety → Advanced.
