import SwiftUI

struct OnboardingFlow: View {
    @EnvironmentObject private var viewModel: ThermyxViewModel
    @ObservedObject var roles: ThermyxRoleStore
    @ObservedObject var settings: ThermyxSettingsStore

    @State private var step: Int = {
        #if DEBUG
        return ThermyxPreviewHarness.initialOnboardingStep
        #else
        return 0
        #endif
    }()
    @State private var selectedRole: ThermyxRole = .user
    @State private var name = ""
    @State private var watchedName = ""
    @State private var pairingCode = "THERMYX-01"
    @State private var calibrating = false

    private enum Screen { case intro, role, profile, connect, calibrate }

    /// The wearer: about you, connect the insole, then calibrate. A watcher
    /// finishes at pairing.
    private var screens: [Screen] {
        selectedRole == .user ? [.intro, .role, .profile, .connect, .calibrate] : [.intro, .role, .connect]
    }
    private var lastStep: Int { screens.count - 1 }
    private var screen: Screen { screens[min(step, lastStep)] }

    var body: some View {
        ZStack {
            AuroraBackground()

            VStack(spacing: Thermyx.Space.wide) {
                OnboardingHeader(step: step, total: lastStep + 1)

                Group {
                    switch screen {
                    case .intro: OnboardingIntro()
                    case .role: OnboardingRole(selection: $selectedRole)
                    case .profile: OnboardingProfile(name: $name, settings: settings)
                    case .calibrate: OnboardingCalibrate(baseline: viewModel.baseline, unit: settings.temperatureUnit) { calibrating = true }
                    case .connect:
                        OnboardingPair(
                            role: selectedRole,
                            name: $name,
                            watchedName: $watchedName,
                            pairingCode: $pairingCode,
                            settings: settings
                        )
                    }
                }
                .frame(maxHeight: .infinity)
                // Re-running the entrance stagger on each step is the point:
                // every screen rises in the same way.
                .id(step)

                Button(buttonTitle) { advance() }
                    .buttonStyle(ThermyxPrimaryButtonStyle())
                    .riseIn(delay: step == 0 ? 0.38 : 0.2)
            }
            .padding(.horizontal, Thermyx.Space.wide)
            .padding(.top, Thermyx.Space.m)
            .padding(.bottom, 32)
        }
        .onAppear {
            // Coming back through onboarding keeps what was entered before.
            if name.isEmpty { name = roles.profileName }
            if let role = roles.role { selectedRole = role }
            startScanIfNeeded(for: step)
        }
        .onChange(of: step) { _, newValue in
            startScanIfNeeded(for: newValue)
        }
        .onDisappear { if viewModel.isScanning { viewModel.toggleScan() } }
        .fullScreenCover(isPresented: $calibrating, onDismiss: { advance() }) {
            NavigationStack { CalibrationView(viewModel: viewModel, settings: settings) }
                .environmentObject(viewModel)
        }
    }

    /// Starts scanning as the pairing step appears, but only for the wearer —
    /// a watcher never touches the insole.
    private func startScanIfNeeded(for step: Int) {
        guard screens[min(step, lastStep)] == .connect, selectedRole == .user, !viewModel.anyConnected, !viewModel.isScanning else { return }
        viewModel.toggleScan()
    }

    private var buttonTitle: String {
        guard step == lastStep else { return "Continue" }
        if screen == .calibrate, viewModel.baseline.model == nil { return "Calibrate later" }
        return "Enter Thermyx"
    }

    private func advance() {
        if step < lastStep {
            withAnimation(.easeOut(duration: 0.25)) { step += 1 }
            return
        }
        roles.complete(
            role: selectedRole,
            name: name.trimmed.isEmpty ? (selectedRole == .user ? "Thermyx user" : "Trusted member") : name.trimmed,
            watched: watchedName.trimmed.isEmpty ? "Thermyx user" : watchedName.trimmed,
            code: pairingCode.trimmed.isEmpty ? "THERMYX-01" : pairingCode.trimmed
        )
    }
}

// MARK: - Header

struct OnboardingHeader: View {
    let step: Int
    let total: Int

    var body: some View {
        HStack(spacing: Thermyx.Space.s) {
            Image("ThermyxBadge")
                .resizable().scaledToFit()
                .frame(width: 48, height: 48)
            Text("Thermyx")
                .narrowLabel(ThermyxFont.wordmark, tracking: ThermyxTracking.wordmark, color: Thermyx.Ink.textPrimary)
            Spacer()
            HStack(spacing: 5) {
                ForEach(0..<total, id: \.self) { index in
                    Capsule()
                        .fill(index == step ? Thermyx.Ink.ice : Thermyx.Ink.textSupporting.opacity(0.3))
                        .frame(width: index == step ? 22 : 10, height: 4)
                }
            }
            .animation(.easeOut(duration: 0.25), value: step)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Thermyx, step \(step + 1) of \(total)")
    }
}

// MARK: - Step 1

struct OnboardingIntro: View {
    var body: some View {
        VStack(spacing: Thermyx.Space.l) {
            ZStack {
                ExpandingRings(color: Thermyx.Ink.ice.opacity(0.5), alternateColor: Thermyx.Ink.ember.opacity(0.45))
                OnboardingDemoVideo()
                    .frame(maxHeight: 450)
                    .shadow(color: .black.opacity(0.45), radius: 24, y: 10)
            }
            .frame(maxHeight: .infinity)

            VStack(alignment: .leading, spacing: Thermyx.Space.l) {
                Text("Climate control\nfor every step")
                    .font(ThermyxFont.onboardingHeadlineLarge)
                    .tracking(ThermyxTracking.onboardingHeadlineLarge)
                    .lineSpacing(-2)
                    .foregroundStyle(Thermyx.Ink.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .riseIn(delay: 0)
                    .accessibilityAddTraits(.isHeader)

                Text("A smart insole that senses your foot temperature, pressure, and movement — then heats or cools in real time.")
                    .font(ThermyxFont.bodyLarge)
                    .lineSpacing(4)
                    .foregroundStyle(Thermyx.Ink.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .riseIn(delay: 0.14)

                HStack(spacing: Thermyx.Space.xs) {
                    capabilityPill("Heat", tint: Thermyx.Ink.amber, fill: Thermyx.Tint.emberFill, border: Thermyx.Tint.emberBorder)
                    capabilityPill("Cool", tint: Thermyx.Ink.ice, fill: Thermyx.Tint.signalFill, border: Thermyx.Tint.signalBorder)
                    capabilityPill("Sense", tint: Thermyx.Ink.textSecondary, fill: Thermyx.Tint.neutralFill, border: Thermyx.Tint.neutralBorder)
                }
                .riseIn(delay: 0.26)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func capabilityPill(_ text: String, tint: Color, fill: Color, border: Color) -> some View {
        Text(text)
            .narrowLabel(ThermyxFont.statusPillLarge, tracking: 1.8, color: tint)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(fill, in: Capsule())
            .overlay { Capsule().strokeBorder(border, lineWidth: 1) }
    }
}

// MARK: - Step 2

struct OnboardingRole: View {
    @Binding var selection: ThermyxRole

    var body: some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.xxl) {
            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: Thermyx.Space.s) {
                Text("How will you use Thermyx?")
                    .font(ThermyxFont.onboardingHeadline)
                    .tracking(ThermyxTracking.onboardingHeadline)
                    .foregroundStyle(Thermyx.Ink.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text("You can switch roles later under Advanced.")
                    .font(ThermyxFont.body)
                    .foregroundStyle(Thermyx.Ink.textMuted)
            }
            .riseIn(delay: 0)

            VStack(spacing: Thermyx.Space.m) {
                roleCard(.user, title: "I wear the insole", detail: "Live comfort, safety, and thermal control.")
                roleCard(.trustedMember, title: "I'm watching someone", detail: "Get their safety events on your phone.")
            }
            .riseIn(delay: 0.14)

            Spacer(minLength: 0)
        }
    }

    private func roleCard(_ role: ThermyxRole, title: String, detail: String) -> some View {
        let isSelected = selection == role
        return Button {
            selection = role
        } label: {
            HStack(spacing: Thermyx.Space.l) {
                RoundedRectangle(cornerRadius: Thermyx.Radius.control, style: .continuous)
                    .fill(isSelected ? Thermyx.Tint.iceWash : Thermyx.Tint.neutralFill)
                    .frame(width: 44, height: 44)
                    .overlay {
                        Image(systemName: role.icon)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(isSelected ? Thermyx.Ink.ice : Thermyx.Ink.textSupporting)
                    }

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(ThermyxFont.cardTitle)
                        .foregroundStyle(Thermyx.Ink.textPrimary)
                    Text(detail)
                        .font(ThermyxFont.caption)
                        .foregroundStyle(Thermyx.Ink.textMuted)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: Thermyx.Space.xs)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 24, weight: .regular))
                    .foregroundStyle(isSelected ? Thermyx.Ink.signal : Thermyx.Ink.textSupporting.opacity(0.35))
            }
            .padding(Thermyx.Space.xxl)
            .frame(maxWidth: .infinity, minHeight: Thermyx.minimumTapTarget, alignment: .leading)
            .background(
                isSelected ? Thermyx.Tint.signalFill : Thermyx.Ink.deck,
                in: RoundedRectangle(cornerRadius: Thermyx.Radius.section, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: Thermyx.Radius.section, style: .continuous)
                    .strokeBorder(
                        isSelected ? Thermyx.Ink.signal : Thermyx.Ink.hairline,
                        lineWidth: isSelected ? Thermyx.Stroke.emphasis : Thermyx.Stroke.hairline
                    )
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}


/// Onboarding, wearer only, after connecting: offer calibration now or later.
struct OnboardingCalibrate: View {
    @EnvironmentObject private var viewModel: ThermyxViewModel
    @ObservedObject var baseline: PersonalBaselineStore
    let unit: TemperatureUnit
    let onStart: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.l) {
            Text("Teach Thermyx your normal")
                .font(ThermyxFont.onboardingHeadline)
                .foregroundStyle(Thermyx.Ink.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Wear the insole for about 6 minutes: sit, stand and walk indoors, then the same outside (that half can wait). Thermyx learns how warm your feet usually run for each, sets Auto to what feels comfortable, and learns to tell what you're doing. It all stays on this phone.")
                .font(ThermyxFont.body)
                .foregroundStyle(Thermyx.Ink.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if viewModel.ble.isFakeInsole {
                FakeInsoleNote(text: "Fake insole connected. Calibration will use its test data, and you can skip the wait.")
            }
            if let model = baseline.model {
                ThermyxCard { CalibrationNorms(model: model, unit: unit) }
            }
            Button(baseline.model == nil ? "Calibrate now" : "Calibrate again") { onStart() }
                .buttonStyle(ThermyxPrimaryButtonStyle())
                .disabled(!viewModel.anyConnected)
            if !viewModel.anyConnected {
                Text("Connect your insole first, or calibrate later from Home.")
                    .font(ThermyxFont.caption)
                    .foregroundStyle(Thermyx.Ink.textSupporting)
            }
            Spacer(minLength: 0)
        }
    }
}


/// Onboarding, wearer only: name and a few optional details. All of it stays
/// on this phone.
struct OnboardingProfile: View {
    @Binding var name: String
    @ObservedObject var settings: ThermyxSettingsStore

    @State private var age = ""
    @State private var height = ""
    @State private var heightInches = ""
    @State private var weight = ""
    @State private var showingSize = false

    private var imperial: Bool { settings.temperatureUnit == .fahrenheit }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Thermyx.Space.xl) {
                VStack(alignment: .leading, spacing: Thermyx.Space.s) {
                    Text("About you")
                        .font(ThermyxFont.onboardingHeadline)
                        .tracking(ThermyxTracking.onboardingHeadline)
                        .foregroundStyle(Thermyx.Ink.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    Text("Only your name is needed. The rest helps Thermyx explain your data, and it never leaves this phone.")
                        .font(ThermyxFont.body)
                        .foregroundStyle(Thermyx.Ink.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .riseIn(delay: 0)

                VStack(alignment: .leading, spacing: Thermyx.Space.m) {
                    field("Your name", text: $name, placeholder: "Name", keyboard: .default)
                    HStack(spacing: Thermyx.Space.m) {
                        field("Age", text: $age, placeholder: "Years", keyboard: .numberPad)
                        field(imperial ? "Weight (lb)" : "Weight (kg)", text: $weight, placeholder: imperial ? "lb" : "kg", keyboard: .decimalPad)
                    }
                    if imperial {
                        HStack(spacing: Thermyx.Space.m) {
                            field("Height (ft)", text: $height, placeholder: "ft", keyboard: .numberPad)
                            field("(in)", text: $heightInches, placeholder: "in", keyboard: .numberPad)
                        }
                    } else {
                        field("Height (cm)", text: $height, placeholder: "cm", keyboard: .numberPad)
                    }

                    SectionLabel("Sex")
                    Picker("Sex", selection: Binding(
                        get: { settings.profile.sex },
                        set: { settings.profile.sex = $0 }
                    )) {
                        Text("Not set").tag(UserProfile.Sex?.none)
                        ForEach(UserProfile.Sex.allCases) { Text($0.label).tag(UserProfile.Sex?.some($0)) }
                    }
                    .pickerStyle(.segmented)

                    SectionLabel("Shoe size")
                    Button { showingSize = true } label: {
                        HStack {
                            Text(settings.soleSize?.label ?? "Choose your size")
                                .font(ThermyxFont.bodyLarge)
                                .foregroundStyle(settings.soleSize == nil ? Thermyx.Ink.textFaint : Thermyx.Ink.textPrimary)
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(Thermyx.Ink.textFaint)
                        }
                        .padding(.horizontal, Thermyx.Space.xl)
                        .frame(minHeight: Thermyx.minimumTapTarget)
                        .background(Thermyx.Ink.deck, in: RoundedRectangle(cornerRadius: Thermyx.Radius.control, style: .continuous))
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)

                    SectionLabel("What should Insights focus on?")
                    ForEach(UserProfile.Focus.allCases) { focus in
                        focusRow(focus)
                    }

                    SectionLabel("Health conditions (optional)")
                    HealthConditionsMenu(settings: settings)
                }
                .riseIn(delay: 0.1)
            }
            .padding(.bottom, Thermyx.Space.m)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .sheet(isPresented: $showingSize) {
            SoleSizePicker(settings: settings)
                .presentationDetents([.large])
                .presentationBackground(Thermyx.Ink.midnight)
        }
        .onAppear(perform: load)
        .onChange(of: age) { _, _ in store() }
        .onChange(of: height) { _, _ in store() }
        .onChange(of: heightInches) { _, _ in store() }
        .onChange(of: weight) { _, _ in store() }
    }

    private func load() {
        let p = settings.profile
        age = p.age.map(String.init) ?? ""
        if let cm = p.heightCm {
            if imperial {
                let inches = Int((cm / 2.54).rounded())
                height = String(inches / 12)
                heightInches = String(inches % 12)
            } else {
                height = String(Int(cm.rounded()))
            }
        }
        if let kg = p.weightKg {
            weight = String(Int((imperial ? kg / 0.453_592 : kg).rounded()))
        }
    }

    /// Keeps only values in a sensible range, so a typo isn't saved.
    private func store() {
        var p = settings.profile
        p.age = Int(age).flatMap { (5...120).contains($0) ? $0 : nil }
        let cm: Double?
        if imperial {
            let feet = Double(height) ?? 0, inches = Double(heightInches) ?? 0
            cm = feet + inches > 0 ? (feet * 12 + inches) * 2.54 : nil
        } else {
            cm = Double(height)
        }
        p.heightCm = cm.flatMap { (80...250).contains($0) ? $0 : nil }
        let kg = Double(weight.replacingOccurrences(of: ",", with: ".")).map { imperial ? $0 * 0.453_592 : $0 }
        p.weightKg = kg.flatMap { (20...300).contains($0) ? $0 : nil }
        if p != settings.profile { settings.profile = p }
    }

    private func field(_ label: String, text: Binding<String>, placeholder: String, keyboard: UIKeyboardType) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(label)
            TextField(placeholder, text: text)
                .keyboardType(keyboard)
                .font(ThermyxFont.bodyLarge)
                .foregroundStyle(Thermyx.Ink.textPrimary)
                .autocorrectionDisabled()
                .padding(.horizontal, Thermyx.Space.xl)
                .frame(minHeight: Thermyx.minimumTapTarget)
                .background(Thermyx.Ink.deck, in: RoundedRectangle(cornerRadius: Thermyx.Radius.control, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Thermyx.Radius.control, style: .continuous)
                        .strokeBorder(Thermyx.Tint.neutralBorder, lineWidth: Thermyx.Stroke.hairline)
                }
        }
    }

    private func focusRow(_ focus: UserProfile.Focus) -> some View {
        let selected = settings.profile.focus == focus
        return Button {
            settings.profile.focus = selected ? nil : focus
        } label: {
            HStack(spacing: Thermyx.Space.m) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(focus.label).font(ThermyxFont.rowTitle).foregroundStyle(Thermyx.Ink.textPrimary)
                    Text(focus.detail).font(ThermyxFont.caption).foregroundStyle(Thermyx.Ink.textMuted)
                }
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(selected ? Thermyx.Ink.signal : Thermyx.Ink.textSupporting.opacity(0.35))
            }
            .padding(Thermyx.Space.l)
            .frame(maxWidth: .infinity, minHeight: Thermyx.minimumTapTarget, alignment: .leading)
            .background(selected ? Thermyx.Tint.signalFill : Thermyx.Ink.deck,
                        in: RoundedRectangle(cornerRadius: Thermyx.Radius.control, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Thermyx.Radius.control, style: .continuous)
                    .strokeBorder(selected ? Thermyx.Ink.signal : Thermyx.Ink.hairline, lineWidth: Thermyx.Stroke.hairline)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

}

/// Pick any number of health conditions from a dropdown. Kept on this phone.
struct HealthConditionsMenu: View {
    @ObservedObject var settings: ThermyxSettingsStore

    private var selected: Set<HealthCondition> { settings.profile.conditionSet }

    var body: some View {
        Menu {
            Button {
                settings.profile.conditionSet = []
            } label: {
                if selected.isEmpty { Label("None", systemImage: "checkmark") } else { Text("None") }
            }
            ForEach(HealthCondition.allCases) { condition in
                Button {
                    var set = selected
                    if set.contains(condition) { set.remove(condition) } else { set.insert(condition) }
                    settings.profile.conditionSet = set
                } label: {
                    if selected.contains(condition) { Label(condition.label, systemImage: "checkmark") } else { Text(condition.label) }
                }
            }
        } label: {
            HStack {
                Text(selected.isEmpty ? "None" : HealthCondition.allCases.filter(selected.contains).map(\.label).joined(separator: ", "))
                    .font(ThermyxFont.body)
                    .foregroundStyle(selected.isEmpty ? Thermyx.Ink.textFaint : Thermyx.Ink.textPrimary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Image(systemName: "chevron.up.chevron.down").foregroundStyle(Thermyx.Ink.textFaint)
            }
            .padding(.horizontal, Thermyx.Space.xl)
            .padding(.vertical, Thermyx.Space.s)
            .frame(minHeight: Thermyx.minimumTapTarget)
            .background(Thermyx.Ink.deck, in: RoundedRectangle(cornerRadius: Thermyx.Radius.control, style: .continuous))
            .contentShape(.rect)
        }
        .menuActionDismissBehavior(.disabled)
        .accessibilityLabel("Health conditions")
        .accessibilityValue(selected.isEmpty ? "None" : "\(selected.count) selected")
    }
}

/// Profile tab: who you are and what Insights focuses on, editable any time.
struct ProfileSettingsSection: View {
    @ObservedObject var roles: ThermyxRoleStore
    @ObservedObject var settings: ThermyxSettingsStore
    @State private var editing = false

    var body: some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.s) {
            SectionLabel("Your profile")
            ThermyxCard {
                VStack(alignment: .leading, spacing: Thermyx.Space.m) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(roles.profileName.isEmpty ? "No name yet" : roles.profileName)
                                .font(ThermyxFont.cardTitle)
                                .foregroundStyle(Thermyx.Ink.textPrimary)
                            Text(details)
                                .font(ThermyxFont.caption)
                                .foregroundStyle(Thermyx.Ink.textSupporting)
                        }
                        Spacer()
                        Button("Edit") { editing = true }
                            .font(ThermyxFont.rowTitle)
                            .foregroundStyle(Thermyx.Ink.ice)
                            .frame(minWidth: Thermyx.minimumTapTarget, minHeight: Thermyx.minimumTapTarget)
                    }

                    SectionLabel("Insights focus")
                    Picker("Insights focus", selection: Binding(
                        get: { settings.profile.focus ?? .health },
                        set: { settings.profile.focus = $0 }
                    )) {
                        ForEach(UserProfile.Focus.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Text((settings.profile.focus ?? .health) == .health
                         ? "Health: safety, comfort and circulation come first."
                         : "Performance: training, recovery and gait come first.")
                        .font(ThermyxFont.captionSmall)
                        .foregroundStyle(Thermyx.Ink.textFaint)

                    SectionLabel("Health conditions")
                    HealthConditionsMenu(settings: settings)

                    Text("Your profile stays on this phone.")
                        .font(ThermyxFont.captionSmall)
                        .foregroundStyle(Thermyx.Ink.textFaint)
                }
            }
        }
        .sheet(isPresented: $editing) {
            NavigationStack {
                OnboardingProfile(name: $roles.profileName, settings: settings)
                    .padding(.horizontal, Thermyx.Space.screen)
                    .background(Thermyx.Ink.midnight.ignoresSafeArea())
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) { Button("Done") { editing = false } }
                    }
            }
            .presentationDetents([.large])
            .presentationBackground(Thermyx.Ink.midnight)
        }
    }

    private var details: String {
        let p = settings.profile
        var parts: [String] = []
        if let age = p.age { parts.append("\(age) yrs") }
        if let cm = p.heightCm {
            if settings.temperatureUnit == .fahrenheit {
                let inches = Int((cm / 2.54).rounded())
                parts.append("\(inches / 12)′\(inches % 12)″")
            } else {
                parts.append("\(Int(cm.rounded())) cm")
            }
        }
        if let kg = p.weightKg {
            parts.append(settings.temperatureUnit == .fahrenheit ? "\(Int((kg / 0.453_592).rounded())) lb" : "\(Int(kg.rounded())) kg")
        }
        if let sex = p.sex { parts.append(sex.label) }
        if let size = settings.soleSize { parts.append(size.label) }
        return parts.isEmpty ? "Add your details" : parts.joined(separator: " · ")
    }
}
