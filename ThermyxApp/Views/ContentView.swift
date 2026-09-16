import SwiftUI
import UIKit

struct AppRootView: View {
    @ObservedObject var roles: ThermyxRoleStore
    @ObservedObject var settings: ThermyxSettingsStore
    var body: some View {
        Group {
            if roles.hasCompletedOnboarding, roles.role == .trustedMember { TrustedMemberRoot(roles: roles, settings: settings) }
            else if roles.hasCompletedOnboarding { ContentView(settings: settings) }
            else { OnboardingView(roles: roles, settings: settings) }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var viewModel: ThermyxViewModel
    @StateObject private var alerts = ThermyxAlertCoordinator()
    @ObservedObject var settings: ThermyxSettingsStore
    var body: some View {
        TabView {
            DashboardView().tabItem { Label("Today", systemImage: "waveform.path.ecg") }
            InsightsView().tabItem { Label("Insights", systemImage: "chart.xyaxis.line") }
            SafetyView(alerts: alerts, settings: settings).tabItem { Label("Safety", systemImage: "shield.checkered") }
            DeviceView().tabItem { Label("Device", systemImage: "sensor.tag.radiowaves.forward") }
        }
        .tint(.cyan).preferredColorScheme(.dark)
        .task { await alerts.requestPermission() }
        .onReceive(viewModel.$reading) { reading in
            alerts.evaluate(ThermyxRiskEngine.assess(reading), reading: reading, settings: settings)
        }
    }
}

struct TrustedMemberRoot: View {
    @ObservedObject var roles: ThermyxRoleStore
    @ObservedObject var settings: ThermyxSettingsStore
    @StateObject private var member = TrustedMemberViewModel()
    var body: some View {
        TabView {
            TrustedMemberDashboard(roles: roles, member: member).tabItem { Label("Watch", systemImage: "person.2.fill") }
            TrustedMemberInsights(member: member).tabItem { Label("Insights", systemImage: "chart.xyaxis.line") }
            TrustedMemberSettings(roles: roles, settings: settings).tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }.tint(.cyan).preferredColorScheme(.dark)
        .task { member.start(settings: settings, deviceID: settings.deviceID) }
        .onDisappear { member.stop() }
    }
}

struct TrustedMemberDashboard: View {
    @ObservedObject var roles: ThermyxRoleStore
    @ObservedObject var member: TrustedMemberViewModel
    var assessment: ThermyxRiskAssessment { guard let e = member.latestEvent else { return .unavailable }; return ThermyxRiskAssessment(level: ThermyxRiskLevel(rawValue: e.level) ?? .unavailable, reasons: e.reasons) }
    var body: some View { NavigationStack { ScrollView { VStack(alignment: .leading, spacing: 18) { HStack { Image("ThermyxLogo").resizable().scaledToFit().frame(width: 46, height: 46).clipShape(RoundedRectangle(cornerRadius: 12)); VStack(alignment: .leading) { Text("TRUSTED CIRCLE").font(.caption.bold()).tracking(2).foregroundStyle(.cyan); Text(roles.watchedUserName).font(.title2.bold()) }; Spacer(); Circle().fill(member.isConnected ? .green : .orange).frame(width: 11, height: 11) }.cardStyle(); RiskCard(assessment: assessment); if let event = member.latestEvent { HStack(spacing: 12) { MetricCard(title: "Foot temperature", value: event.readings.footTemperatureC.map { String(format: "%.1f °C", $0) } ?? "—", tint: .orange); MetricCard(title: "Battery", value: event.readings.batteryPercent.map { "\($0)%" } ?? "—", tint: .yellow) }; Text("Latest update \(event.timestamp.formatted(date: .omitted, time: .shortened))").font(.footnote).foregroundStyle(.white.opacity(0.55)) } else { EmptyInsightCard(title: "Waiting for the user", icon: "antenna.radiowaves.left.and.right", detail: "The trusted phone will show the insole's latest status here.") }; ActionCard(level: assessment.level) }.padding(20) }.background(AppTheme.background.ignoresSafeArea()).navigationTitle("Safety watch") } }
}

struct TrustedMemberInsights: View { @ObservedObject var member: TrustedMemberViewModel; var body: some View { NavigationStack { ScrollView { VStack(alignment: .leading, spacing: 16) { Text("Shared insights").font(.largeTitle.bold()); Text("Live signals shared by the Thermyx user.").foregroundStyle(.white.opacity(0.65)); if let r = member.latestEvent?.readings { MetricCard(title: "Movement stability", value: r.gaitStability.map { String(format: "%.0f%%", $0 * 100) } ?? "—", tint: .green); MetricCard(title: "Pressure balance", value: r.pressureBalance.map { String(format: "%.0f%%", $0 * 100) } ?? "—", tint: .cyan); MetricCard(title: "Ambient temperature", value: r.ambientTemperatureC.map { String(format: "%.1f °C", $0) } ?? "—", tint: .orange) } else { EmptyInsightCard(title: "No shared data yet", icon: "chart.xyaxis.line", detail: "Insights will appear when the user connects the insole.") } }.padding(20) }.background(AppTheme.background.ignoresSafeArea()).navigationTitle("Insights") } } }

struct TrustedMemberSettings: View { @ObservedObject var roles: ThermyxRoleStore; @ObservedObject var settings: ThermyxSettingsStore; var body: some View { NavigationStack { Form { Section("Connection") { Text("Pairing code: \(roles.pairingCode)"); TextField("Shared backend URL", text: $settings.backendURL); SecureField("Backend token", text: $settings.backendToken); TextField("Device ID", text: $settings.deviceID) }; Section { Button("Change role") { roles.reset() } } }.navigationTitle("Settings") } } }

struct ActionCard: View { let level: ThermyxRiskLevel; var body: some View { VStack(alignment: .leading, spacing: 8) { Label("What to do", systemImage: "checklist").font(.headline).foregroundStyle(.cyan); Text(level == .critical || level == .high ? "Ask the user to stop, move to a cooler place, hydrate, and seek help if symptoms continue." : "Stay available and check in if the user reports discomfort.").foregroundStyle(.white.opacity(0.72)) }.cardStyle() } }

struct DashboardView: View {
    @EnvironmentObject private var viewModel: ThermyxViewModel
    private var assessment: ThermyxRiskAssessment { ThermyxRiskEngine.assess(viewModel.reading) }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 12) {
                        Image("ThermyxLogo").resizable().scaledToFit().frame(width: 54, height: 54).clipShape(RoundedRectangle(cornerRadius: 14))
                        VStack(alignment: .leading) { Text("THERMYX").font(.caption.bold()).tracking(2).foregroundStyle(.cyan); Text("Personal climate control").font(.title2.bold()) }
                    }
                    ConnectionCard()
                    RiskCard(assessment: assessment)
                    HStack(spacing: 12) {
                        MetricCard(title: "Foot temperature", value: viewModel.reading.footTemperatureC.map { String(format: "%.1f °C", $0) } ?? "—", tint: .orange)
                        MetricCard(title: "Battery", value: viewModel.reading.batteryPercent.map { "\($0)%" } ?? "—", tint: .yellow)
                    }
                    HStack(spacing: 12) {
                        MetricCard(title: "Gait stability", value: viewModel.reading.gaitStability.map { String(format: "%.0f%%", $0 * 100) } ?? "—", tint: .green)
                        MetricCard(title: "Thermal mode", value: viewModel.reading.thermalMode.rawValue, tint: .cyan)
                    }
                    Text("No placeholder readings are shown. Connect the physical insole to populate this dashboard.").font(.footnote).foregroundStyle(.white.opacity(0.55))
                }.padding(20)
            }.background(AppTheme.background.ignoresSafeArea()).toolbar(.hidden, for: .navigationBar)
        }
    }
}

struct InsightsView: View {
    @EnvironmentObject private var viewModel: ThermyxViewModel
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Insights").font(.largeTitle.bold())
                    Text("Thermyx will summarize patterns only after it receives real sensor history.").foregroundStyle(.white.opacity(0.65))
                    EmptyInsightCard(title: "Temperature trend", icon: "thermometer.medium", detail: viewModel.reading.footTemperatureC == nil ? "Waiting for insole data" : "History will appear after enough readings are collected.")
                    EmptyInsightCard(title: "Movement pattern", icon: "figure.walk", detail: viewModel.reading.gaitStability == nil ? "Waiting for IMU data" : "Baseline comparison will appear after history is collected.")
                    EmptyInsightCard(title: "Pressure balance", icon: "shoeprints.fill", detail: viewModel.reading.pressureBalance == nil ? "Waiting for pressure data" : "Trend analysis will appear after history is collected.")
                }.padding(20)
            }.background(AppTheme.background.ignoresSafeArea())
        }
    }
}

struct SafetyView: View {
    @ObservedObject var alerts: ThermyxAlertCoordinator
    @ObservedObject var settings: ThermyxSettingsStore
    @StateObject private var form = SafetyFormModel()
    var body: some View {
        NavigationStack {
            Form {
                Section("Alert status") {
                    Label(alerts.notificationsAuthorized ? "Notifications enabled" : "Notifications not enabled", systemImage: alerts.notificationsAuthorized ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    Text("Alerts escalate only from real readings received by the connected insole.").font(.footnote).foregroundStyle(.secondary)
                }
                Section("Escalation plan") {
                    Text("Caution: notify the user.")
                    Text("High risk: notify the user and recommend stopping, hydrating, and cooling down.")
                    Text("Critical: deliver a prominent local alert and show emergency actions.")
                }
                Section("Trusted contact") {
                    TextField("Contact name", text: $form.name)
                    TextField("Phone number", text: $form.phone)
                    Button("Add trusted contact") { settings.addContact(name: form.name, phone: form.phone); form.clear() }
                    ForEach(settings.contacts) { contact in
                        Label("\(contact.name) · \(contact.phoneNumber)", systemImage: contact.enabled ? "checkmark.circle" : "pause.circle")
                    }
                    Text("Trusted members receive the user’s shared safety events through the connected Thermyx network.").font(.footnote).foregroundStyle(.secondary)
                    Button("Call 911") { UIApplication.shared.open(URL(string: "tel://911")!) }.tint(.red)
                }
                Section("Alert backend") {
                    TextField("HTTPS alert endpoint", text: $settings.backendURL)
                    SecureField("Backend token", text: $settings.backendToken)
                    TextField("Device ID", text: $settings.deviceID)
                    Text("The backend receives only escalated risk events and is responsible for sending approved family SMS or voice notifications.").font(.footnote).foregroundStyle(.secondary)
                }
            }.navigationTitle("Safety")
        }
    }
}

@MainActor
final class SafetyFormModel: ObservableObject {
    @Published var name = ""
    @Published var phone = ""
    func clear() { name = ""; phone = "" }
}

struct DeviceView: View {
    @EnvironmentObject private var viewModel: ThermyxViewModel
    var body: some View {
        NavigationStack {
            Form {
                Section("Connection") {
                    LabeledContent("Status", value: viewModel.connectionLabel)
                    Button(viewModel.isScanning ? "Stop scanning" : "Scan for Thermyx") { viewModel.toggleScan() }
                    if viewModel.ble.isConnected { Button("Disconnect", role: .destructive) { viewModel.ble.disconnect() } }
                }
                Section("Controls") {
                    Button("Heat") { viewModel.setMode(.heating) }
                    Button("Cool") { viewModel.setMode(.cooling) }
                    Button("Turn off") { viewModel.setMode(.off) }
                }
                Section("Firmware") { Text("BLE protocol is ready for the XIAO firmware UUIDs and telemetry packet to be finalized.").font(.footnote).foregroundStyle(.secondary) }
            }.navigationTitle("Device")
        }
    }
}

struct ConnectionCard: View {
    @EnvironmentObject private var viewModel: ThermyxViewModel
    var body: some View {
        HStack {
            Circle().fill(viewModel.ble.isConnected ? .green : .orange).frame(width: 10, height: 10)
            Text(viewModel.connectionLabel).font(.headline); Spacer()
            Button(viewModel.ble.isConnected ? "Disconnect" : "Connect") { viewModel.ble.isConnected ? viewModel.ble.disconnect() : viewModel.toggleScan() }.buttonStyle(.borderedProminent).tint(.cyan)
        }.cardStyle()
    }
}

struct RiskCard: View {
    let assessment: ThermyxRiskAssessment
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Heat-risk status").font(.caption.bold()).foregroundStyle(.white.opacity(0.62))
            Text(assessment.level.rawValue).font(.title2.bold()).foregroundStyle(assessment.level == .unavailable ? .white.opacity(0.6) : .cyan)
            Text(assessment.level.explanation).foregroundStyle(.white.opacity(0.75))
            ForEach(assessment.reasons, id: \.self) { Text("• \($0)").font(.footnote) }
        }.cardStyle()
    }
}

struct MetricCard: View {
    let title: String; let value: String; let tint: Color
    var body: some View { VStack(alignment: .leading, spacing: 8) { Text(title).font(.caption).foregroundStyle(.white.opacity(0.62)); Text(value).font(.title3.bold()).foregroundStyle(tint) }.frame(maxWidth: .infinity, alignment: .leading).cardStyle() }
}

struct EmptyInsightCard: View {
    let title: String; let icon: String; let detail: String
    var body: some View { HStack(spacing: 14) { Image(systemName: icon).font(.title2).foregroundStyle(.cyan); VStack(alignment: .leading, spacing: 4) { Text(title).font(.headline); Text(detail).font(.subheadline).foregroundStyle(.white.opacity(0.6)) } }.cardStyle() }
}

enum AppTheme { static let background = Color(red: 0.03, green: 0.07, blue: 0.13) }

private extension View {
    func cardStyle() -> some View { padding(16).background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 18, style: .continuous)).overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.white.opacity(0.09))) }
}
