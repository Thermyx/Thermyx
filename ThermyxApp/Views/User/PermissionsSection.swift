import CoreBluetooth
import CoreLocation
import SwiftUI

/// Every iOS switch Thermyx depends on, in one list: what it's for, whether
/// it's on, and the one button that turns it on (iOS's prompt, Thermyx's
/// page in Settings, or the Health app). Read again each time the app comes
/// back to the front.
struct PermissionsSection: View {
    @EnvironmentObject private var viewModel: ThermyxViewModel
    @ObservedObject var health: ThermyxHealthService
    @ObservedObject private var permissions = ThermyxPermissions.shared
    @ObservedObject private var weather = ThermyxWeather.shared
    @ObservedObject private var ble: ThermyxBLEService
    @Environment(\.scenePhase) private var scenePhase

    init(ble: ThermyxBLEService, health: ThermyxHealthService) {
        self.ble = ble
        self.health = health
    }

    private var offCount: Int {
        [bluetooth, notifications, location, healthStatus, liveActivities].filter { $0 != .allowed }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.header) {
            SectionLabel("Permissions") {
                Text(offCount == 0 ? "All on" : "\(offCount) off")
                    .foregroundStyle(offCount == 0 ? Thermyx.Ink.ice : Thermyx.Ink.amber)
            }
            VStack(spacing: 0) {
                row(.asset("BluetoothLogo"), "Bluetooth", "Finds and talks to your insoles", bluetooth,
                    offTitle: ble.state == .poweredOff ? "Turn On" : nil,
                    allow: { ble.requestBluetooth() }, turnOn: { ble.promptPowerOn() })
                row(.symbol("bell.badge.fill"), "Notifications", "Warnings when the app isn't open", notifications,
                    allow: { Task { await permissions.requestNotifications() } })
                row(.symbol("location.fill"), "Location", "Outside air, and your location in an emergency if you allow it", location,
                    allow: { weather.requestPermission() })
                row(.asset("AppleHealth"), "Apple Health", "Steps, steadiness and workouts", healthStatus,
                    deniedTitle: "Open Health", denied: ThermyxPermissions.openHealth,
                    allow: { Task { await health.requestAuthorization() } })
                row(.symbol("platter.filled.bottom.iphone"), "Live Activities", "Mode and readings on the Lock Screen", liveActivities,
                    allow: ThermyxPermissions.openSettings, last: true)
            }
            .overlay(alignment: .top) { ThermyxDivider() }
            Text("Each switch can be changed later in Settings. Thermyx works without any of them, with less.")
                .font(ThermyxFont.captionSmall)
                .foregroundStyle(Thermyx.Ink.textFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task { await permissions.refresh() }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await permissions.refresh() }
            health.refreshAuthorizationState()
        }
    }

    // MARK: Status

    private var bluetooth: PermissionPrompt.Status {
        ble.isDemoMode ? .allowed : .init(ble.authorization, state: ble.state)
    }
    private var notifications: PermissionPrompt.Status { .init(permissions.notifications) }
    private var location: PermissionPrompt.Status { .init(weather.authorization) }
    private var liveActivities: PermissionPrompt.Status { permissions.liveActivitiesEnabled ? .allowed : .denied }
    private var healthStatus: PermissionPrompt.Status {
        switch health.availability {
        case .authorized: return .allowed
        case .denied: return .denied
        case .notDetermined: return .notAsked
        case .notEntitled, .unavailable: return .off
        }
    }

    // MARK: Row

    private func row(_ icon: PermissionPrompt.Icon, _ title: String, _ detail: String, _ status: PermissionPrompt.Status,
                     offTitle: String? = nil, deniedTitle: String = "Settings", denied: (() -> Void)? = nil,
                     allow: @escaping () -> Void, turnOn: (() -> Void)? = nil, last: Bool = false) -> some View {
        HStack(spacing: Thermyx.Space.m) {
            PermissionIcon(icon: icon)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(ThermyxFont.rowTitle)
                    .foregroundStyle(Thermyx.Ink.textPrimary)
                Text(statusLine(status, detail: detail, offTitle: offTitle))
                    .font(ThermyxFont.captionSmall)
                    .foregroundStyle(status == .allowed || status == .notAsked ? Thermyx.Ink.textMuted : Thermyx.Ink.amber)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Thermyx.Space.xs)
            switch status {
            case .allowed:
                Label("On", systemImage: "checkmark")
                    .labelStyle(.titleAndIcon)
                    .font(ThermyxFont.controlLabel)
                    .foregroundStyle(Thermyx.Ink.ice)
                    .accessibilityLabel("On")
            case .notAsked:
                Button("Allow", action: allow).buttonStyle(PermissionButtonStyle())
            case .denied:
                Button(deniedTitle) { (denied ?? ThermyxPermissions.openSettings)() }
                    .buttonStyle(PermissionButtonStyle(prominent: false))
            case .off:
                if let offTitle, let turnOn {
                    Button(offTitle, action: turnOn).buttonStyle(PermissionButtonStyle())
                }
            }
        }
        .padding(.vertical, Thermyx.Space.s)
        .frame(minHeight: 60)
        .overlay(alignment: .bottom) { ThermyxDivider() }
        .accessibilityElement(children: .combine)
    }

    private func statusLine(_ status: PermissionPrompt.Status, detail: String, offTitle: String?) -> String {
        switch status {
        case .allowed, .notAsked: return detail
        case .denied: return "Off for Thermyx"
        case .off: return offTitle == nil ? "Not available on this device" : "Off on this iPhone"
        }
    }
}
