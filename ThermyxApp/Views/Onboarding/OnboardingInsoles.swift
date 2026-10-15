import CoreBluetooth
import SwiftUI

/// Onboarding, wearer: find and connect the insoles. One search finds both;
/// each insole says which foot it is.
struct InsolesStep: View {
    @EnvironmentObject private var viewModel: ThermyxViewModel
    @ObservedObject var settings: ThermyxSettingsStore
    let onContinue: () -> Void
    let onLater: () -> Void

    var body: some View {
        InsoleSearch(ble: viewModel.ble, settings: settings, onContinue: onContinue, onLater: onLater)
    }
}

private struct InsoleSearch: View {
    @EnvironmentObject private var viewModel: ThermyxViewModel
    @ObservedObject var ble: ThermyxBLEService
    @ObservedObject var settings: ThermyxSettingsStore
    let onContinue: () -> Void
    let onLater: () -> Void

    @Environment(\.isThermyxAdmin) private var isAdmin
    @State private var choosingFoot: ThermyxBLEService.DiscoveredDevice?
    @State private var showingRelay = false

    /// Insoles only. The single-sensor test board is an admin tool.
    private var found: [ThermyxBLEService.DiscoveredDevice] {
        ble.discovered.filter { $0.kind == .insole || (isAdmin && $0.kind == .sensorBoard) }
    }

    var body: some View {
        OnboardingPage(eyebrow: "Your insoles", title: "Searching for *nearby insoles*",
                       subtitle: "Switch both insoles on and keep them close to your phone. They'll appear here.") {
            InsolePairFigure(connected: ble.connected, searching: ble.connected.count < 2)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Thermyx.Space.s)

            VStack(alignment: .leading, spacing: Thermyx.Space.s) {
                if !ble.isDemoMode {
                    PermissionPrompt(symbol: "dot.radiowaves.left.and.right", title: "Bluetooth",
                                     detail: "Thermyx uses Bluetooth to find and talk to your insoles.",
                                     status: .init(ble.authorization)) { ble.requestBluetooth() }
                    if ble.authorization == .allowedAlways && ble.state == .poweredOff {
                        notice("Turn on Bluetooth in Control Center to find your insoles.")
                    }
                }
                ForEach(Foot.allCases.filter(ble.connected.contains)) { foot in
                    connectedRow(foot)
                }
                ForEach(found) { device in
                    deviceRow(device)
                }
                if found.isEmpty && ble.connected.count < 2 && ble.state == .poweredOn {
                    searchingRow
                }
                if let step = ble.insoleStep {
                    Text(step)
                        .font(ThermyxFont.captionSmall)
                        .foregroundStyle(Thermyx.Site.textMuted)
                }
                if let error = ble.errorMessage, ble.isDemoMode || ble.authorization == .allowedAlways {
                    Text(error)
                        .font(ThermyxFont.captionSmall)
                        .foregroundStyle(Thermyx.Ink.amber)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .animation(SiteMotion.settle, value: found.map(\.id))
            .animation(SiteMotion.settle, value: ble.connected)
            .animation(SiteMotion.settle, value: ble.authorization)

            if isAdmin { developerTools }
        } actions: {
            Button(action: onContinue) {
                Label(ble.connected.count == 1 ? "Continue with one insole" : "Continue", systemImage: "arrow.right")
                    .labelStyle(TrailingIconLabelStyle())
            }
            .buttonStyle(SitePrimaryButtonStyle())
            .disabled(ble.connected.isEmpty)
            Button("Set up insoles later", action: onLater)
                .buttonStyle(SiteTextButtonStyle())
        }
        .onAppear(perform: scanIfNeeded)
        .onChange(of: ble.connected) { _, _ in scanIfNeeded() }
        .onChange(of: ble.state) { _, state in
            // Bluetooth just came on (or was just allowed): search again.
            guard state == .poweredOn else { return }
            if viewModel.isScanning { viewModel.toggleScan() }
            scanIfNeeded()
        }
        .onDisappear { if viewModel.isScanning { viewModel.toggleScan() } }
        .sensoryFeedback(.success, trigger: ble.connected.count)
        .confirmationDialog("Which foot is this insole for?", isPresented: Binding(
            get: { choosingFoot != nil }, set: { if !$0 { choosingFoot = nil } }
        ), titleVisibility: .visible, presenting: choosingFoot) { device in
            ForEach(Foot.allCases) { foot in
                Button(foot.label) { viewModel.connect(to: device, as: foot) }
            }
        }
    }

    /// Keeps searching until both feet are connected.
    private func scanIfNeeded() {
        guard ble.connected.count < 2, !viewModel.isScanning else { return }
        viewModel.toggleScan()
    }

    // MARK: Rows

    private var searchingRow: some View {
        HStack(spacing: Thermyx.Space.m) {
            ProgressView().tint(Thermyx.Site.textMuted)
            Text("Searching for nearby insoles…")
                .font(ThermyxFont.body)
                .foregroundStyle(Thermyx.Site.textMuted)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Thermyx.Space.xl)
        .frame(minHeight: 60)
        .siteGlass(radius: Thermyx.Radius.control)
        .accessibilityElement(children: .combine)
    }

    private func deviceRow(_ device: ThermyxBLEService.DiscoveredDevice) -> some View {
        Button {
            if device.kind == .insole, device.advertisedFoot == nil {
                choosingFoot = device
            } else {
                viewModel.connect(to: device)
            }
        } label: {
            HStack(spacing: Thermyx.Space.m) {
                SignalGlyph(strong: device.isStrong)
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name)
                        .font(ThermyxFont.rowTitle)
                        .foregroundStyle(Thermyx.Site.text)
                        .lineLimit(1)
                    Text(subtext(device))
                        .font(ThermyxFont.captionSmall)
                        .foregroundStyle(Thermyx.Site.textMuted)
                }
                Spacer(minLength: Thermyx.Space.xs)
                Text("Connect")
                    .font(ThermyxFont.controlLabel)
                    .foregroundStyle(Thermyx.Ink.ice)
            }
            .padding(.horizontal, Thermyx.Space.xl)
            .frame(minHeight: 64)
            .siteGlass(radius: Thermyx.Radius.control)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .transition(.opacity.combined(with: .move(edge: .bottom)))
        .accessibilityLabel("\(device.name), \(subtext(device))")
        .accessibilityHint("Connects this insole")
    }

    private func subtext(_ device: ThermyxBLEService.DiscoveredDevice) -> String {
        if device.kind == .sensorBoard { return "Test sensor board" }
        let foot = device.advertisedFoot?.label ?? "Choose a foot when you connect"
        return "\(foot) · \(device.isStrong ? "Strong signal" : "Weak signal")"
    }

    private func connectedRow(_ foot: Foot) -> some View {
        HStack(spacing: Thermyx.Space.m) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(Thermyx.Ink.ice)
            VStack(alignment: .leading, spacing: 2) {
                Text(ble.names[foot] ?? "Thermyx insole")
                    .font(ThermyxFont.rowTitle)
                    .foregroundStyle(Thermyx.Site.text)
                    .lineLimit(1)
                Text([foot.label, viewModel.reading[foot]?.batteryPercent.map { "\($0)% battery" }]
                        .compactMap { $0 }.joined(separator: " · "))
                    .font(ThermyxFont.captionSmall)
                    .foregroundStyle(Thermyx.Site.textMuted)
            }
            Spacer(minLength: Thermyx.Space.xs)
            Text("Connected")
                .font(ThermyxFont.captionSmall)
                .foregroundStyle(Thermyx.Ink.ice)
        }
        .padding(.horizontal, Thermyx.Space.xl)
        .frame(minHeight: 64)
        .siteGlass(radius: Thermyx.Radius.control, highlighted: true)
        .transition(.opacity)
        .accessibilityElement(children: .combine)
    }

    private func notice(_ text: String) -> some View {
        Text(text)
            .font(ThermyxFont.caption)
            .foregroundStyle(Thermyx.Ink.amber)
            .fixedSize(horizontal: false, vertical: true)
            .padding(Thermyx.Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .siteGlass(radius: Thermyx.Radius.control)
    }

    // MARK: Admin

    private var developerTools: some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.s) {
            SiteEyebrow("Admin · test tools", color: Thermyx.Ink.amber)
            FakeInsolePairControls(ble: ble)
            Button(showingRelay ? "Hide relay" : "Connect a relay") {
                withAnimation(SiteMotion.settle) { showingRelay.toggle() }
            }
            .buttonStyle(SiteTextButtonStyle(tint: Thermyx.Site.textMuted))
            if showingRelay {
                RelayConnectionCard(settings: settings, role: "wearer")
                    .transition(.opacity)
            }
        }
        .padding(.top, Thermyx.Space.m)
    }
}

/// Three bars, lit by signal strength.
private struct SignalGlyph: View {
    let strong: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<3, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(i < (strong ? 3 : 1) ? Thermyx.Ink.ice : Thermyx.Site.hairlineStrong)
                    .frame(width: 3, height: CGFloat(6 + i * 4))
            }
        }
        .frame(width: 20, height: 20)
        .accessibilityHidden(true)
    }
}

/// The pair, from above. Each sole outlines while searching and fills in
/// once its insole is connected.
struct InsolePairFigure: View {
    let connected: Set<Foot>
    var searching: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathe = false

    var body: some View {
        HStack(spacing: 28) {
            ForEach(Foot.allCases) { foot in
                let on = connected.contains(foot)
                VStack(spacing: Thermyx.Space.s) {
                    ZStack {
                        SoleShape(foot: foot)
                            .fill(on ? Thermyx.Ink.signal.opacity(0.22) : Color.white.opacity(0.03))
                        SoleShape(foot: foot)
                            .stroke(on ? Thermyx.Ink.signal : Thermyx.Site.textFaint, lineWidth: on ? 1.5 : 1)
                            .opacity(on ? 1 : (searching && !reduceMotion ? (breathe ? 0.9 : 0.3) : 0.6))
                    }
                    .frame(width: 128 * SoleShape.widthRatio, height: 128)
                    .shadow(color: on ? Thermyx.Ink.signal.opacity(0.45) : .clear, radius: 14)
                    Text(foot.label)
                        .narrowLabel(ThermyxFont.zoneLabel, tracking: ThermyxTracking.zoneLabel,
                                     color: on ? Thermyx.Ink.ice : Thermyx.Site.textFaint)
                }
                .animation(SiteMotion.settle, value: on)
            }
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { breathe = true }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(connected.isEmpty ? "No insoles connected yet"
                            : "\(Foot.allCases.filter(connected.contains).map(\.label).joined(separator: " and ")) connected")
    }
}
