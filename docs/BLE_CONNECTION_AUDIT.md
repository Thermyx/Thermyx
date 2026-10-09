# Bluetooth connection audit: "the phone connects, the app doesn't"

Branch `xiao-test-sensor`, checked against `ThermyxBLEService.swift`,
`ThermyxProtocol.swift`, the Connect a device screen, and
`firmware/thermyx_insole_esp32`. Written 2026-10-08.

## The symptom

Tapping Scan or Thermyx Left in the app makes iOS show the board as
connected, the ESP32 sees a connection, but the app stays "Offline" and
Cool / Heat do nothing. Closing the app drops the connection.

That last detail matters: **the connection is the app's own**. iOS drops
an app's Bluetooth links when the app closes; a pairing made in Settings
would survive it. So the radio link works. What fails is the app turning
that link into a connected insole. In this app an insole only counts as
connected **after its first telemetry packet decodes**
(`decodeTelemetry` → `adopt`). Every bug below breaks one step on the way
there: connect → find the service → subscribe → receive → decode → adopt.

Status key: **Fixed** (commit on this branch), **Open**, **Check**
(environment or process, not code).

---

## 1. Packets cut from 22 to 20 bytes by the default MTU. Fixed in `0511eb1`

**Severity: critical, the most likely cause.**

Telemetry v3 is 22 bytes. A BLE notification carries MTU − 3 bytes, and
the ESP32 Arduino BLE stack answers iOS's MTU request with 23 unless the
sketch calls `BLEDevice::setMTU()`. So each packet arrived as 20 bytes,
`ThermyxProtocol.decode` returned `.tooShort`, the app set "Received an
incomplete telemetry packet" and never adopted the insole. The link stayed
up with nothing on screen, exactly as reported.

- Firmware (ESP32 and XIAO): `BLEDevice::setMTU(185)` after `init`.
- App: a v3 packet cut to 18–21 bytes now decodes its v2 fields
  (temperature, foot, mode, setting echo); cadence and standing read as
  not measured. Test: `testDecodesAVersionThreePacketCutToTwentyBytes`.

Either half alone fixes the symptom. Both need a rebuild or reflash.

## 2. Stale "sensor board" memory for the same ESP32. Fixed in `d6925d9`

**Severity: high.**

An ESP32 keeps its Bluetooth address, and iOS keeps the same peripheral
identifier for it, whatever firmware it runs. After the board ran the
TMP102 test sketch and was connected from the list, the app saved it in
`BoardMemory` as the sensor board. Then, with the insole firmware:

1. On launch and each time Bluetooth came on, `reconnectRememberedBoard`
   connected to it **as a board** (the "phone connects by itself").
2. `didConnect` asked only for the sensor service, found none, and
   `rejectBoard` cancelled the connection.
3. A Thermyx Left tap in that window shared the same `CBPeripheral`, so
   it was cancelled too, or routed down the board path.

Now `didConnect` asks for both services and `didDiscoverServices` decides:
an insole service makes it an insole and clears any board memory for that
identifier (`becomeInsole`); a sensor service makes it the board
(`becomeBoard`). Tapping a device as an insole also drops a stale board
claim on it.

## 3. iOS's cached copy of the old services. Check (message added)

**Severity: high if the ESP32 was flashed with different firmware.**

iOS caches a peripheral's name and GATT service list by identifier. After
reflashing from the sensor sketch (service `7a1b…`) to the insole firmware
(`7b7e…`), iOS can keep returning the old services. The app then connects
and finds no insole service. It's a well-known iOS behaviour with
reflashed boards, and the usual fix is on the phone, not in code:

1. Settings → Bluetooth → Thermyx → ⓘ → **Forget This Device** (if listed).
2. Turn Bluetooth off and on, or restart the iPhone if it persists.

How to spot it: since `ffbcc7c` the Insoles card on Connect a device says
"connected, but it has no Thermyx service" when this happens.

## 4. Demo Mode and the "Thermyx Demo" scheme have no real radio. Check, warning added in `911e23e`

**Severity: high, but process.**

The Thermyx Demo scheme launches with `-ThermyxUIPreview simulator`, and
`ThermyxBLEService.init` then never creates a `CBCentralManager`. Demo
Mode switched on in Advanced does the same at runtime, and `didConnect`
cancels any real connection while the simulator runs. Either way, no real
device can connect, and the simulated "Thermyx Left (simulated)" row is
easy to mistake for the board.

- Always run the **ThermyxApp** scheme for hardware.
- The orange "SIMULATED — NOT LIVE SENSOR DATA" strip means Demo Mode.
- Connect a device now shows a "Demo Mode is on" card with a button to
  turn it off.

## 5. No visible state between "link up" and "first packet". Fixed in `ffbcc7c`

**Severity: medium. It made bugs 1–3 look like "the phone took it".**

Before, the only connected state was a decoded packet, so every failure
above looked the same: Offline. The Insoles card now shows each step
(connecting, service found, subscribed, waiting for first reading,
receiving readings) or the step that failed, and lists connected insoles.

## 6. Only one connection allowed by the firmware. Fixed in `f9b1100`

**Severity: medium.**

ESP32 Arduino BLE stops advertising once any central connects. If iOS
(a Settings pairing) or another app (LightBlue, nRF Connect) held the
link, the Thermyx app couldn't find or join it. The firmware now restarts
advertising in `onConnect` and counts clients; Heat drops to Auto only
when no one is connected. The app's Scan also lists Thermyx devices iOS
already holds ("On iPhone") via `retrieveConnectedPeripherals`.

## 7. `userDisconnects` can keep an ID and suppress reconnects. Fixed

**Severity: medium.**

`rejectBoard`, `startDemoMode` and `connectBoard` add an identifier to
`userDisconnects` and expect a later `didDisconnect` to remove it. If that
callback never comes (the connection was only pending, so cancelling it
produces no disconnect), the ID stays. Later, a real drop of that device
as an insole hits `userDisconnects.remove(identifier) != nil` in
`didDisconnectPeripheral` and is treated as a user disconnect, so the app
does **not** reconnect.

Suggested fix: clear the ID in `connect(to:)` and `connectBoard` (the
user's tap overrides an old disconnect), and on `didConnect`.

## 8. Insole connected but no foot temperature: Home looks offline. Fixed

**Severity: medium.**

`HomeView` shows the live layout only when `heroTemperatureC` is non-nil.
If the TMP102 is missing or miswired, the firmware still sends packets
with "no temperature", the insole is adopted (header says "Left only"),
but Home shows the empty "No sensor connected" state. Easy to read as
"not connected".

Suggested fix: when an insole is connected without a foot temperature,
show it on Home with "Foot sensor not reporting" rather than the empty
state. Check the Serial line: `foot sensor missing (check SDA 21 / SCL 22…)`.

## 9. Kind decided by the first advertisement. Fixed by `d6925d9`

**Severity: low now, high before.**

The list classifies a device from its advertised services, and a filtered
scan marks anything without the insole UUID as a sensor board. If the
first packet seen lacked the service list, an insole was listed as a
board, and tapping it ran `connectBoard`, which then rejected it. Routing
by discovered services (#2) makes this harmless; the list label can still
be briefly wrong.

## 10. Scanning keeps running while connecting. Fixed

**Severity: low.**

`connect(to:)` never stops the scan (duplicates on). It doesn't break
connections, but a continuous scan competes for radio time while
connecting and keeps the list redrawing. Suggested fix:
`central.stopScan()` in `connect(to:)`, as `connectBoard` already does.

## 11. Silent no-op when a tapped device isn't known. Fixed

**Severity: low.**

`connect(to:)` and `connectBoard` return without a message if
`peripherals[device.id]` is missing. Rows are always registered when
listed, so this shouldn't happen, but if it does the tap does nothing at
all. Suggested fix: set `insoleStep` / `errorMessage` ("Scan again").

## 12. Packets without a declared foot are dropped. Fixed

**Severity: low with current firmware.**

If flags bits 0–1 are 0 and the app has no pending foot (name without
"left"/"right"), `decodeTelemetry` reports "connected without saying
which foot" and never adopts. The ESP32 firmware sets `THERMYX_FOOT 1`,
so this only bites with other firmware.

## 13. iOS may show an old name. Fixed

**Severity: cosmetic.**

`peripheral.name` is cached by iOS from the old firmware (e.g. "Thermyx"
instead of "Thermyx Left"). The list now prefers the advertised name, but
`names[foot]` after adoption uses `peripheral.name`. Forgetting the device
or toggling Bluetooth refreshes it.

---

## Fixes for 3, 7, 8, 10–13 (after `2a57ac3`)

- 3: the "no Thermyx service" step now tells you to forget the device and
  turn Bluetooth off and on if it was just reflashed.
- 7: a tap and a completed connection both clear an old disconnect
  request, so later drops reconnect again.
- 8: Home keeps the live layout while an insole is connected and says
  "Foot sensor not reporting" instead of showing the empty state.
- 10: `connect(to:)` stops the scan before connecting.
- 11: a tapped device that's gone says "no longer in range. Scan again."
- 12: a packet with no declared foot takes a free slot instead of being
  dropped.
- 13: the connected insole is named by its current advertised name.

Also fixed while here: history is saved as soon as the app goes to the
background (it was only saved on a 5-second debounce, so the last few
seconds could be lost on suspend).

## Test checklist (in order)

1. Build **ThermyxApp** (not Thermyx Demo) from `xiao-test-sensor` at
   `d6925d9` or later. No orange SIMULATED strip.
2. Flash `firmware/thermyx_insole_esp32` (has `setMTU(185)` and
   multi-connection). Serial shows `Thermyx Left ready (ESP32, …)`.
3. iPhone: forget Thermyx in Settings → Bluetooth; Bluetooth off/on.
   Quit LightBlue / nRF Connect.
4. App → Connect a device → Scan → Thermyx Left. Watch the Insoles card:
   - stops at **"no Thermyx service"** → #3 (cache): forget + restart phone.
   - stops at **"Waiting for the first reading"** with Serial `connected`
     → packets not arriving: check Serial for `foot …` lines; reflash.
   - red **"incomplete telemetry packet"** → app older than `0511eb1`.
   - **receiving readings** but Home empty → #8: check the TMP102 wiring.
5. Tap Cool / Heat: Serial prints `App command: …` and the LED lights.

## Sources

- ESP32 notifications limited to 20 bytes at the default MTU:
  [esp32.com forum](https://esp32.com/viewtopic.php?p=19870),
  [arduino-esp32 #10573](https://github.com/espressif/arduino-esp32/issues/10573)
- iOS caching GATT data and names after a firmware change:
  [Apple Developer Forums: clear BLE cache](https://developer.apple.com/forums/thread/76339),
  [Apple Developer Forums: GATT profile update](https://developer.apple.com/forums/thread/44505),
  [Apple Developer Forums: cached peripheral name](https://www.developer.apple.com/forums/thread/802961)
