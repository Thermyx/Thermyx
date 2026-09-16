# Thermyx BLE protocol v1

The XIAO firmware must advertise the following BLE service:

- Service: `7B7E0001-7A3B-4D2D-9C9E-000000000001`
- Telemetry characteristic: `7B7E0002-7A3B-4D2D-9C9E-000000000001`
- Command characteristic: `7B7E0003-7A3B-4D2D-9C9E-000000000001`

The app scans for the service, connects, discovers both characteristics, and enables notifications on telemetry.

Telemetry notifications are exactly 12 bytes, little-endian:

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

Commands are two bytes: `[1, mode]`, using the same mode values above. The firmware should acknowledge writes and continue sending telemetry at a defined interval, such as 1 Hz.

The app intentionally shows no values until it receives a valid version-1 packet. The UUIDs and packet format must be treated as an interface contract; changing firmware values requires changing the decoder and testing them together.
