# Thermyx insole firmware

Two builds of the same firmware:

- `thermyx_insole/` for the **Seeed XIAO ESP32-C3** (pin map below).
- `thermyx_insole_esp32/` for an **ESP32-WROOM-32 dev board** (e.g. ELEGOO
  ESP-32): GPIO pin map in the file header, TMP102 or TMP117 detected
  automatically, FSRs and MPU-6050 optional, and a status line on the Serial
  Monitor at 115200. Board: **ESP32 Dev Module**.

`thermyx_insole/thermyx_insole.ino` runs on a **Seeed XIAO ESP32-C3** and
implements [`ThermyxApp/BLE_PROTOCOL.md`](../ThermyxApp/BLE_PROTOCOL.md):
v3 telemetry (22 bytes, once a second), mode commands, and the
target-temperature command used by Auto.

> **Status:** written against the protocol and the prototype parts list, and
> syntax-checked, but **not yet compiled for the board or flashed**. Check the
> pin map against the real wiring before first power-up, and test the Peltier
> with the insole off the foot.

## Parts it expects

| Part | Connection |
|---|---|
| Peltier (CUI CP3495-46, or Dilwe TEC104901 for the proof of concept) | DRV8833 channel A: AIN1 = D6, AIN2 = D7 |
| 20 mm fan | DRV8833 channel B: BIN1 = D8, **BIN2 to GND** |
| DRV8833 nSLEEP | D10 (driven high) |
| TMP117 foot-contact sensor | I2C (D4 SDA, D5 SCL), address 0x48 |
| TMP117 ambient sensor | same bus, address 0x49 (ADD0 to V+) |
| GY-521 / MPU-6050 | same bus, address 0x68 |
| FSR402 heel / arch / forefoot | A0 / A1 / A2, each with a 10 kΩ resistor to GND |
| Battery sense (optional) | Off by default. A0–A2 are the board's only dependable analog pins and the FSRs use all three; "A3" (GPIO5) is on ADC2, which reads unreliably with Bluetooth on. Use an external ADC (e.g. ADS1115 on the I2C bus) or free an ADC1 pin, set `PIN_BATTERY`, then `HAS_BATTERY_SENSE 1`. The build stops with an error until you do. |

D9 is left unused on purpose: it is the ESP32-C3 boot strap pin.

**Pull-downs.** While the chip resets or boots, its pins float. The DRV8833's
inputs and nSLEEP have internal pull-downs, so the bridge stays off; for
margin, fit an external **10 kΩ pull-down on nSLEEP (D10)**. If a build drives
the Peltier or fan through MOSFETs instead, a pull-down on **every gate** is
required, not optional — the firmware cannot hold a pin low before it starts.

If the build uses NTC thermistors instead of TMP117s, replace `readTMP117`
with an ADC read and a Beta-equation conversion; everything else is the same.

## Flashing

1. Arduino IDE 2.x → Boards Manager → install **esp32 by Espressif** (3.x).
2. Board: **XIAO_ESP32C3**. No extra libraries are needed.
3. Set `THERMYX_FOOT` to `1` for the left insole or `2` for the right, then
   upload. Repeat for the other insole with the other value.
4. Open Thermyx → Scan. The insoles advertise as "Thermyx Left" and
   "Thermyx Right" and pair to the right foot automatically.

## Safety behaviour (enforced in firmware, whatever the app sends)

- **Never heats at or above 40 °C** foot contact; resumes below 38.5 °C.
- **Never cools at or below 15 °C.**
- **No heating or cooling without a foot temperature**: a missing sensor drops
  to fan-only.
- **No unsupervised heating**: if the phone disconnects while Heat is
  selected, the insole falls back to Auto.
- Heating runs at a lower duty than cooling.
- **A hung loop resets the chip**: a 4-second task watchdog restarts it, and
  the outputs come back up off.

The watchdog, pull-down note and battery-pin warning come from Aaron Qin's
firmware work.

## What it reports

- Foot temperature: the contact TMP117. Zone fields carry the "absent" marker,
  so the app shows a single-sensor view and hides the zone map.
- Ambient temperature: the second TMP117.
- Gait stability: 1 − the coefficient of variation of recent step intervals,
  from the MPU-6050. Sent as "not measured" until a few steps are seen.
- Pressure balance: forefoot share of the three FSRs.
- Cadence and standing fraction (v3).
- Battery: "not measured" (`0xFF`) unless battery sense is fitted.
- Flags byte: the foot (bits 0–1), the setting it is following (bits 2–3:
  1 Cool, 2 Auto, 3 Heat), and whether the burn cutoff is holding heat off
  (bit 4). The app uses the setting to confirm that a Cool / Auto / Heat tap
  actually took effect.
