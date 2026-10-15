import SwiftUI

/// Onboarding, wearer: About you. Apple Health can fill in what it knows;
/// the rest is typed. Every answer is needed to continue.
struct AboutYouStep: View {
    @Binding var name: String
    @ObservedObject var settings: ThermyxSettingsStore
    @ObservedObject var health: ThermyxHealthService
    let onContinue: () -> Void

    var body: some View {
        let missing = AboutYouForm.missing(name: name, settings: settings)
        OnboardingPage(eyebrow: "About you", title: "A little *about you*",
                       subtitle: "Thermyx reads your numbers against your own body. Every answer is needed, and all of it stays on this phone.") {
            AboutYouForm(name: $name, settings: settings, health: health)
        } actions: {
            if !missing.isEmpty {
                Text("Still needed: \(missing.joined(separator: ", "))")
                    .font(ThermyxFont.captionSmall)
                    .foregroundStyle(Thermyx.Site.textFaint)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
            }
            Button(action: onContinue) {
                Label("Continue", systemImage: "arrow.right").labelStyle(TrailingIconLabelStyle())
            }
            .buttonStyle(SitePrimaryButtonStyle())
            .disabled(!missing.isEmpty)
            .animation(SiteMotion.settle, value: missing)
        }
    }
}

/// The About you answers, used in onboarding and when editing the profile.
struct AboutYouForm: View {
    @Binding var name: String
    @ObservedObject var settings: ThermyxSettingsStore
    @ObservedObject var health: ThermyxHealthService

    @State private var age = ""
    @State private var height = ""
    @State private var heightInches = ""
    @State private var weight = ""
    @State private var importing = false
    @State private var importNote: String?

    private var imperial: Bool { settings.temperatureUnit == .fahrenheit }

    /// What's still unanswered, in the order the form asks.
    static func missing(name: String, settings: ThermyxSettingsStore) -> [String] {
        let p = settings.profile
        var result: [String] = []
        if name.trimmed.isEmpty { result.append("name") }
        if p.age == nil { result.append("age") }
        if p.sex == nil { result.append("sex") }
        if p.heightCm == nil { result.append("height") }
        if p.weightKg == nil { result.append("weight") }
        if settings.soleSize == nil { result.append("shoe size") }
        if p.focus == nil { result.append("Insights focus") }
        if p.conditions == nil { result.append("health conditions") }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            healthCard

            group("You") {
                OnboardingTextField(label: "Name", text: $name, placeholder: "Your name", contentType: .name)
                OnboardingTextField(label: "Age", text: $age, placeholder: "Years", keyboard: .numberPad)
                if let age = Int(age), !UserProfile.ageRange.contains(age) {
                    hint("Thermyx accounts are for ages 13 and up.")
                }
                sexPicker
            }

            group("Body") {
                if imperial {
                    HStack(spacing: Thermyx.Space.s) {
                        OnboardingTextField(label: "Height", text: $height, keyboard: .numberPad, suffix: "ft")
                        OnboardingTextField(label: "", text: $heightInches, keyboard: .numberPad, suffix: "in")
                            .frame(maxWidth: 120)
                    }
                } else {
                    OnboardingTextField(label: "Height", text: $height, keyboard: .numberPad, suffix: "cm")
                }
                OnboardingTextField(label: "Weight", text: $weight, keyboard: .decimalPad, suffix: imperial ? "lb" : "kg")
                if (!height.isEmpty && settings.profile.heightCm == nil) || (!weight.isEmpty && settings.profile.weightKg == nil) {
                    hint("Check your height and weight. Those numbers look off.")
                }
                shoeSize
            }

            group("What should Insights focus on?") {
                ForEach(UserProfile.Focus.allCases) { focus in
                    choiceRow(focus.label, detail: focus.detail, selected: settings.profile.focus == focus) {
                        settings.profile.focus = focus
                    }
                }
            }

            group("Health conditions") {
                ConditionsPicker(settings: settings)
                Text("Helps Thermyx explain what it sees. It never changes the safety limits.")
                    .font(ThermyxFont.captionSmall)
                    .foregroundStyle(Thermyx.Site.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear(perform: load)
        .onChange(of: age) { _, _ in store() }
        .onChange(of: height) { _, _ in store() }
        .onChange(of: heightInches) { _, _ in store() }
        .onChange(of: weight) { _, _ in store() }
    }

    // MARK: Apple Health

    private var healthCard: some View {
        HStack(alignment: .center, spacing: Thermyx.Space.l) {
            Image(systemName: "heart.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(Color(hex: 0xFF2D55), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("Apple Health")
                    .font(ThermyxFont.rowTitle)
                    .foregroundStyle(Thermyx.Site.text)
                Text(importNote ?? "Fill in your age, sex, height and weight.")
                    .font(ThermyxFont.captionSmall)
                    .foregroundStyle(Thermyx.Site.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Thermyx.Space.xs)
            if importing {
                ProgressView().tint(Thermyx.Site.text)
            } else if health.isAvailable {
                Button("Connect") { Task { await importFromHealth() } }
                    .font(ThermyxFont.controlLabel)
                    .foregroundStyle(Thermyx.Ink.ice)
                    .frame(minHeight: Thermyx.minimumTapTarget)
                    .accessibilityLabel("Connect Apple Health")
            }
        }
        .padding(Thermyx.Space.l)
        .siteGlass(radius: Thermyx.Radius.list)
    }

    private func importFromHealth() async {
        importing = true
        defer { importing = false }
        let found = await health.importProfile()
        settings.healthKitEnabled = health.availability != .notEntitled && health.availability != .unavailable
        guard !found.isEmpty else {
            importNote = health.availability == .notEntitled
                ? "This build can't reach Apple Health. Type your details below."
                : "Health didn't share any of these. Type them below."
            return
        }
        var p = settings.profile
        var filled: [String] = []
        if let a = found.age, UserProfile.ageRange.contains(a) { p.age = a; filled.append("age") }
        if let s = found.sex { p.sex = s; filled.append("sex") }
        if let h = found.heightCm, UserProfile.heightRangeCm.contains(h) { p.heightCm = h; filled.append("height") }
        if let w = found.weightKg, UserProfile.weightRangeKg.contains(w) { p.weightKg = w; filled.append("weight") }
        settings.profile = p
        load()
        importNote = filled.isEmpty ? "Health didn't share any of these. Type them below." : "Filled in \(Self.list(filled)) from Health."
    }

    private static func list(_ items: [String]) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + items.last!
    }

    // MARK: Fields

    private var sexPicker: some View {
        HStack(spacing: Thermyx.Space.m) {
            Text("Sex")
                .font(ThermyxFont.body)
                .foregroundStyle(Thermyx.Site.textMuted)
            Spacer(minLength: Thermyx.Space.s)
            HStack(spacing: 4) {
                ForEach(UserProfile.Sex.allCases) { sex in
                    let selected = settings.profile.sex == sex
                    Button {
                        withAnimation(SiteMotion.settle) { settings.profile.sex = sex }
                    } label: {
                        Text(sex.label)
                            .font(ThermyxFont.controlLabel)
                            .foregroundStyle(selected ? Thermyx.Ink.onSignal : Thermyx.Site.textMuted)
                            .frame(width: 84, height: 36)
                            .background(selected ? Thermyx.Ink.signal : .clear, in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                }
            }
            .padding(3)
            .background(Thermyx.Site.bg.opacity(0.4), in: Capsule())
            .sensoryFeedback(.selection, trigger: settings.profile.sex)
        }
        .padding(.leading, Thermyx.Space.xl)
        .padding(.trailing, Thermyx.Space.s)
        .frame(minHeight: 54)
        .siteGlass(radius: Thermyx.Radius.control)
    }

    @ViewBuilder
    private var shoeSize: some View {
        Menu {
            Picker("Shoe size", selection: Binding(get: { settings.soleSize }, set: { settings.soleSize = $0 })) {
                ForEach(SoleSize.all) { size in
                    Text(size.label).tag(Optional(size))
                }
            }
        } label: {
            HStack(spacing: Thermyx.Space.m) {
                Text("Shoe size")
                    .font(ThermyxFont.body)
                    .foregroundStyle(Thermyx.Site.textMuted)
                Spacer(minLength: Thermyx.Space.s)
                Text(settings.soleSize.map { "\($0.label) men's" } ?? "Choose")
                    .font(ThermyxFont.bodyLarge)
                    .foregroundStyle(settings.soleSize == nil ? Thermyx.Site.textFaint : Thermyx.Site.text)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Thermyx.Site.textFaint)
            }
            .padding(.horizontal, Thermyx.Space.xl)
            .frame(minHeight: 54)
            .siteGlass(radius: Thermyx.Radius.control)
            .contentShape(Rectangle())
        }
        if let size = settings.soleSize, !size.isSupported {
            hint("Today's insoles are cut for US men's 11–12. Your size is saved for when yours is ready.")
        }
    }

    private func choiceRow(_ title: String, detail: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(SiteMotion.settle) { action() }
        } label: {
            HStack(spacing: Thermyx.Space.m) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(ThermyxFont.rowTitle).foregroundStyle(Thermyx.Site.text)
                    Text(detail).font(ThermyxFont.caption).foregroundStyle(Thermyx.Site.textMuted)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: Thermyx.Space.xs)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(selected ? Thermyx.Ink.signal : Thermyx.Site.hairlineStrong)
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(Thermyx.Space.l)
            .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
            .siteGlass(radius: Thermyx.Radius.control, highlighted: selected)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .sensoryFeedback(.selection, trigger: selected)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.s) {
            SiteEyebrow(title)
            content()
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(ThermyxFont.captionSmall)
            .foregroundStyle(Thermyx.Ink.amber)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Storage

    private func load() {
        let p = settings.profile
        age = p.age.map(String.init) ?? age
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

    /// Keeps only values in range, so a typo is never saved.
    private func store() {
        var p = settings.profile
        p.age = Int(age).flatMap { UserProfile.ageRange.contains($0) ? $0 : nil }
        let cm: Double?
        if imperial {
            let feet = Double(height) ?? 0, inches = Double(heightInches) ?? 0
            cm = feet + inches > 0 ? (feet * 12 + inches) * 2.54 : nil
        } else {
            cm = Double(height)
        }
        p.heightCm = cm.flatMap { UserProfile.heightRangeCm.contains($0) ? $0 : nil }
        let kg = Double(weight.replacingOccurrences(of: ",", with: ".")).map { imperial ? $0 * 0.453_592 : $0 }
        p.weightKg = kg.flatMap { UserProfile.weightRangeKg.contains($0) ? $0 : nil }
        if p != settings.profile { settings.profile = p }
    }
}

/// Health conditions: "None", or any number of them. Unanswered until the
/// wearer picks.
struct ConditionsPicker: View {
    @ObservedObject var settings: ThermyxSettingsStore

    private var answered: Bool { settings.profile.conditions != nil }
    private var selected: Set<HealthCondition> { settings.profile.conditionSet }

    var body: some View {
        Menu {
            Button {
                settings.profile.conditionSet = []
            } label: {
                if answered && selected.isEmpty { Label("None", systemImage: "checkmark") } else { Text("None") }
            }
            Divider()
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
            HStack(spacing: Thermyx.Space.m) {
                Text(summary)
                    .font(ThermyxFont.bodyLarge)
                    .foregroundStyle(answered ? Thermyx.Site.text : Thermyx.Site.textFaint)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Thermyx.Space.s)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Thermyx.Site.textFaint)
            }
            .padding(.horizontal, Thermyx.Space.xl)
            .padding(.vertical, Thermyx.Space.s)
            .frame(minHeight: 54)
            .siteGlass(radius: Thermyx.Radius.control)
            .contentShape(Rectangle())
        }
        .menuActionDismissBehavior(.disabled)
        .accessibilityLabel("Health conditions")
        .accessibilityValue(answered ? summary : "Not answered")
    }

    private var summary: String {
        guard answered else { return "Choose any that apply, or None" }
        return selected.isEmpty ? "None" : HealthCondition.allCases.filter(selected.contains).map(\.label).joined(separator: ", ")
    }
}
