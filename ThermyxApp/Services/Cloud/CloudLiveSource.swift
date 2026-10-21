import Combine
import Foundation

/// A store that can take a restored baseline. `PersonalBaselineStore` keeps
/// its baseline `private(set)`, so it adopts this in its own file:
///
///     extension PersonalBaselineStore: CloudBaselineRestorable {
///         func restore(baseline: PersonalBaseline) { self.baseline = baseline; persist() }
///     }
///
/// Until it does, the baseline is backed up but not restored on a new phone.
@MainActor
protocol CloudBaselineRestorable: AnyObject {
    func restore(baseline: PersonalBaseline)
}

/// The preferences worth carrying to a new phone. Every field is optional so
/// a backup from an older or newer build still reads, and unknown values are
/// ignored rather than failing the whole restore.
///
/// Not here, on purpose: the relay token and URL (secrets, and a new phone
/// pairs afresh), trusted contacts (other people's numbers), location sharing
/// and Apple Health switches (consent is given again on each phone), and the
/// AI Insights switch (it sends data to Anthropic; that consent is renewed).
struct CloudSettingsSnapshot: Codable, Equatable {
    var profileName: String?
    var profile: UserProfile?
    var soleSizeUSMens: Double?
    var shoeSizeSystem: String?
    var temperatureUnit: String?
    var insightsRange: String?
    var periodStyle: String?
    var preferredFoot: String?
    var usage: [String]?
    var targetTemperatureC: Double?
    var alertOnCaution: Bool?
    var alertOnHighRisk: Bool?
    var alertOnCritical: Bool?
    var circleName: String?
    var aiSuggestionsEnabled: Bool?
}

/// The real phone, as the backup engine sees it.
@MainActor
final class CloudLiveSource: CloudBackupSource {
    private let viewModel: ThermyxViewModel
    private let settings: ThermyxSettingsStore
    private let roles: ThermyxRoleStore?

    init(viewModel: ThermyxViewModel, settings: ThermyxSettingsStore, roles: ThermyxRoleStore?) {
        self.viewModel = viewModel
        self.settings = settings
        self.roles = roles
    }

    var isDemo: Bool {
        viewModel.ble.isDemoMode || viewModel.recovery.inDemo || viewModel.history.isInDemo
    }

    var changes: AnyPublisher<Void, Never> {
        var publishers: [AnyPublisher<Void, Never>] = [
            settings.objectWillChange.eraseToAnyPublisher(),
            viewModel.baseline.objectWillChange.eraseToAnyPublisher(),
            viewModel.recovery.objectWillChange.eraseToAnyPublisher(),
            // Leaving Demo Mode brings the real data back; look again.
            viewModel.ble.$isDemoMode.dropFirst().map { _ in () }.eraseToAnyPublisher(),
        ]
        if let roles { publishers.append(roles.objectWillChange.eraseToAnyPublisher()) }
        return Publishers.MergeMany(publishers).eraseToAnyPublisher()
    }

    // MARK: Reading

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private func json<T: Encodable>(_ value: T) -> String {
        (try? Self.encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
    }

    func snapshot() -> CloudSettingsSnapshot {
        CloudSettingsSnapshot(
            profileName: roles?.profileName,
            profile: settings.profile,
            soleSizeUSMens: settings.soleSize?.usMens,
            shoeSizeSystem: settings.shoeSizeSystem.rawValue,
            temperatureUnit: settings.temperatureUnit.rawValue,
            insightsRange: settings.insightsRange.rawValue,
            periodStyle: settings.periodStyle.rawValue,
            preferredFoot: settings.preferredFoot.rawValue,
            usage: settings.usage,
            targetTemperatureC: settings.targetTemperatureC,
            alertOnCaution: settings.alertOnCaution,
            alertOnHighRisk: settings.alertOnHighRisk,
            alertOnCritical: settings.alertOnCritical,
            circleName: settings.circleName,
            aiSuggestionsEnabled: settings.aiSuggestionsEnabled
        )
    }

    /// The model, unless it came from the fake insole's scripted data.
    private var realModel: PersonalThermalModel? {
        guard let model = viewModel.baseline.model, !model.isTestData else { return nil }
        return model
    }

    func payload(for part: CloudPart) -> String {
        switch part {
        case .settings: return json(snapshot())
        case .baseline: return json(viewModel.baseline.baseline)
        case .model: return json(realModel)
        case .recoveries: return json(viewModel.recovery.records)
        }
    }

    func hasData(for part: CloudPart) -> Bool {
        switch part {
        case .settings: return settings.profile != UserProfile() || !(roles?.profileName ?? "").isEmpty
        case .baseline: return viewModel.baseline.baseline.minutesLearned > 0
        case .model: return realModel != nil
        case .recoveries: return !viewModel.recovery.records.isEmpty
        }
    }

    func canApply(_ part: CloudPart) -> Bool {
        part != .baseline || (viewModel.baseline as AnyObject) is CloudBaselineRestorable
    }

    func same(_ a: String, _ b: String, part: CloudPart) -> Bool {
        if a == b { return true }
        func decode<T: Decodable & Equatable>(_ type: T.Type) -> Bool {
            guard let x = try? JSONDecoder().decode(type, from: Data(a.utf8)),
                  let y = try? JSONDecoder().decode(type, from: Data(b.utf8)) else { return false }
            return x == y
        }
        switch part {
        case .settings: return decode(CloudSettingsSnapshot.self)
        case .baseline: return decode(PersonalBaseline.self)
        case .model: return a == "null" || b == "null" ? a == b : decode(PersonalThermalModel.self)
        case .recoveries: return decode([RecoveryRecord].self)
        }
    }

    // MARK: Restoring

    func apply(_ payload: String, to part: CloudPart) -> Bool {
        let data = Data(payload.utf8)
        let decoder = JSONDecoder()
        switch part {
        case .settings:
            guard let snapshot = try? decoder.decode(CloudSettingsSnapshot.self, from: data) else { return false }
            apply(snapshot)
            return true
        case .baseline:
            guard let restorable = viewModel.baseline as AnyObject as? CloudBaselineRestorable,
                  let baseline = try? decoder.decode(PersonalBaseline.self, from: data), !baseline.isExpired() else { return false }
            restorable.restore(baseline: baseline)
            return true
        case .model:
            // "null" means no calibration; anything else must decode.
            let model: PersonalThermalModel?
            if payload.trimmingCharacters(in: .whitespacesAndNewlines) == "null" {
                model = nil
            } else if let decoded = try? decoder.decode(PersonalThermalModel.self, from: data) {
                model = decoded
            } else {
                return false
            }
            if let model, !model.isTestData {
                // No calibration minutes: the baseline is restored on its own.
                viewModel.baseline.adopt(model, indoorSamples: [])
            } else {
                viewModel.baseline.clearModel()
            }
            return true
        case .recoveries:
            guard let records = try? decoder.decode([RecoveryRecord].self, from: data) else { return false }
            viewModel.recovery.deleteAll()
            for record in records { viewModel.recovery.add(record) }
            return true
        }
    }

    /// Writes each value through the store's own setters, checked against the
    /// ranges the app itself accepts, since a backup is only as trustworthy
    /// as the last phone that wrote it.
    private func apply(_ s: CloudSettingsSnapshot) {
        if let name = s.profileName, let roles { roles.profileName = String(name.prefix(60)) }
        if var profile = s.profile {
            if let age = profile.age, !UserProfile.ageRange.contains(age) { profile.age = nil }
            if let h = profile.heightCm, !UserProfile.heightRangeCm.contains(h) { profile.heightCm = nil }
            if let w = profile.weightKg, !UserProfile.weightRangeKg.contains(w) { profile.weightKg = nil }
            settings.profile = profile
        }
        if let size = s.soleSizeUSMens, size > 0, size < 30 { settings.soleSize = SoleSize.make(usMens: size) }
        if let v = s.shoeSizeSystem.flatMap(ShoeSizeSystem.init(rawValue:)) { settings.shoeSizeSystem = v }
        if let v = s.temperatureUnit.flatMap(TemperatureUnit.init(rawValue:)) { settings.temperatureUnit = v }
        if let v = s.insightsRange.flatMap(InsightsRange.init(rawValue:)) { settings.insightsRange = v }
        if let v = s.periodStyle.flatMap(InsightsPeriodStyle.init(rawValue:)) { settings.periodStyle = v }
        if let v = s.preferredFoot.flatMap(Foot.init(rawValue:)) { settings.preferredFoot = v }
        if let v = s.usage { settings.usage = v.filter(ThermyxSettingsStore.usageOptions.contains) }
        if let v = s.targetTemperatureC, v.isFinite {
            settings.targetTemperatureC = min(max(v, ThermyxSettingsStore.targetRange.lowerBound), ThermyxSettingsStore.targetRange.upperBound)
        }
        if let v = s.alertOnCaution { settings.alertOnCaution = v }
        if let v = s.alertOnHighRisk { settings.alertOnHighRisk = v }
        if let v = s.alertOnCritical { settings.alertOnCritical = v }
        if let v = s.circleName { settings.circleName = String(v.prefix(60)) }
        if let v = s.aiSuggestionsEnabled { settings.aiSuggestionsEnabled = v }
    }
}

// MARK: - Population contribution inputs

extension CloudLiveSource: PopulationSource {
    var populationCohort: PopulationCohort {
        PopulationCohort.make(usage: settings.usage, age: settings.profile.age)
    }

    var populationInputs: PopulationInputs? {
        guard !isDemo else { return nil }
        return PopulationInputs(
            minutes: viewModel.history.minuteSamples,
            baseline: viewModel.baseline.baseline,
            usage: settings.usage,
            age: settings.profile.age
        )
    }
}
