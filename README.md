# Thermyx

Thermyx is a SwiftUI iPhone app and Node.js demo backend for a BLE-connected smart insole. The app supports a User view, a Trusted Member view, live telemetry, safety scoring, and shared risk events.

## Project

- `ThermyxApp.xcodeproj` — Xcode project
- `ThermyxApp/` — SwiftUI app, BLE service, telemetry models, onboarding, and dashboards
- `ThermyxBackend/` — local shared-status and optional SMS relay
- `project.yml` — XcodeGen project definition

## Two-phone demo

Run the backend on a laptop connected to the same Wi-Fi as both phones. Set a shared `THERMYX_TOKEN`, then enter the laptop's local address and token during onboarding. Select **User** on the phone connected to the insole and **Trusted member** on the second phone.

The User phone connects to the XIAO over BLE and publishes status events. The Trusted Member phone reads the latest event from the backend.
