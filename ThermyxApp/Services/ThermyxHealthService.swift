import Foundation
import HealthKit
import UIKit

/// Apple Health integration.
///
/// Scope is deliberately narrow in both directions:
///
/// **Read** — step count, walking steadiness, and workouts, so Insights can
/// put heat exposure next to what the user was actually doing rather than
/// showing insole data in isolation; and date of birth, sex, height and
/// weight, offered to fill in About you.
///
/// **Write** — Thermyx sessions as `HKWorkout` only. Body temperature is
/// deliberately *not* requested: foot-contact temperature is not core body
/// temperature, and writing it into Health under that type would be exactly
/// the dishonest output the product spec forbids.
///
/// Nothing in the app blocks on any of this. Denial and "not determined" both
/// degrade to the activity card simply not appearing.
@MainActor
final class ThermyxHealthService: ObservableObject {

    enum Availability: Equatable {
        case unavailable
        case notDetermined
        case authorized
        case denied
        /// The app is not entitled to use HealthKit — almost always a build
        /// signed without the HealthKit capability. Distinguished from
        /// "denied" because the user cannot fix it from the Health app.
        case notEntitled
    }

    @Published private(set) var availability: Availability = .notDetermined
    @Published private(set) var todayStepCount: Int?
    @Published private(set) var walkingSteadiness: Double?
    @Published private(set) var lastWorkout: WorkoutSummary?
    @Published private(set) var lastError: String?
    /// When a Thermyx session was last written to Health, so the UI can say so
    /// rather than claiming the integration works and leaving it unevidenced.
    @Published private(set) var lastSavedSession: Date?

    struct WorkoutSummary: Equatable {
        let activityName: String
        let start: Date
        let duration: TimeInterval
    }

    private let store = HKHealthStore()

    private var readTypes: Set<HKObjectType> {
        var types: Set<HKObjectType> = [HKObjectType.workoutType()]
        if let steps = HKQuantityType.quantityType(forIdentifier: .stepCount) {
            types.insert(steps)
        }
        if let steadiness = HKQuantityType.quantityType(forIdentifier: .appleWalkingSteadiness) {
            types.insert(steadiness)
        }
        // About you: filled in from Health where it has the answer.
        types.formUnion([
            HKCharacteristicType(.dateOfBirth),
            HKCharacteristicType(.biologicalSex),
            HKQuantityType(.height),
            HKQuantityType(.bodyMass),
        ])
        return types
    }

    private var writeTypes: Set<HKSampleType> {
        [HKObjectType.workoutType()]
    }

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    // MARK: - Authorization

    func refreshAuthorizationState() {
        guard isAvailable else {
            availability = .unavailable
            return
        }
        // Read authorization is intentionally opaque in HealthKit, so the
        // write status is the only thing that can be inspected directly.
        switch store.authorizationStatus(for: HKObjectType.workoutType()) {
        case .sharingAuthorized: availability = .authorized
        case .sharingDenied: availability = .denied
        case .notDetermined: availability = .notDetermined
        @unknown default: availability = .notDetermined
        }
    }

    /// Presents the Health authorization sheet. Safe to call when already
    /// determined — HealthKit simply returns without showing anything.
    func requestAuthorization() async {
        guard isAvailable else {
            availability = .unavailable
            return
        }
        do {
            try await store.requestAuthorization(toShare: writeTypes, read: readTypes)
            refreshAuthorizationState()
            await refreshContext()
        } catch {
            lastError = error.localizedDescription
            // HKError.errorInvalidArgument (4) with this message is what you
            // get from a build that was not signed with the HealthKit
            // capability — worth distinguishing so the screen can say so.
            if (error as NSError).code == 4, error.localizedDescription.contains("entitlement") {
                availability = .notEntitled
            } else {
                refreshAuthorizationState()
            }
        }
    }

    /// Opens the Health app so the user can change permissions they denied.
    /// HealthKit deliberately gives no in-app way back, so pointing at Health
    /// is the only honest recovery path.
    func openHealthSettings() {
        guard let url = URL(string: "x-apple-health://") else { return }
        Task { @MainActor in
            await UIApplication.shared.open(url)
        }
    }

    // MARK: - About you

    /// What Health knows of the About you answers. Anything it doesn't
    /// know, or the wearer didn't share, stays nil for them to type in.
    struct ProfileImport: Equatable {
        var age: Int?
        var sex: UserProfile.Sex?
        var heightCm: Double?
        var weightKg: Double?

        var isEmpty: Bool { age == nil && sex == nil && heightCm == nil && weightKg == nil }
    }

    /// Asks for access, then reads date of birth, sex, and the latest height
    /// and weight. Health never says which reads were refused, so a refusal
    /// simply comes back empty.
    func importProfile() async -> ProfileImport {
        await requestAuthorization()
        guard isAvailable, availability != .notEntitled else { return ProfileImport() }
        var result = ProfileImport()
        if let birth = try? store.dateOfBirthComponents(), let born = Calendar.current.date(from: birth) {
            result.age = Calendar.current.dateComponents([.year], from: born, to: .now).year
        }
        switch (try? store.biologicalSex())?.biologicalSex {
        case .male: result.sex = .male
        case .female: result.sex = .female
        default: break
        }
        result.heightCm = await latest(.height, unit: .meterUnit(with: .centi))
        result.weightKg = await latest(.bodyMass, unit: .gramUnit(with: .kilo))
        return result
    }

    private func latest(_ identifier: HKQuantityTypeIdentifier, unit: HKUnit) async -> Double? {
        await withCheckedContinuation { continuation in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
            let query = HKSampleQuery(sampleType: HKQuantityType(identifier), predicate: nil, limit: 1, sortDescriptors: [sort]) { _, samples, _ in
                continuation.resume(returning: (samples?.first as? HKQuantitySample)?.quantity.doubleValue(for: unit))
            }
            store.execute(query)
        }
    }

    // MARK: - Reading

    /// Pulls the activity context shown alongside heat exposure. Every failure
    /// path leaves the corresponding value nil, which hides the card.
    func refreshContext() async {
        guard isAvailable else { return }
        async let steps = fetchTodaySteps()
        async let steadiness = fetchWalkingSteadiness()
        async let workout = fetchLastWorkout()
        todayStepCount = await steps
        walkingSteadiness = await steadiness
        lastWorkout = await workout
    }

    private func fetchTodaySteps() async -> Int? {
        guard let type = HKQuantityType.quantityType(forIdentifier: .stepCount) else { return nil }
        let start = Calendar.current.startOfDay(for: .now)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: .now)
        return await withCheckedContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum
            ) { _, statistics, _ in
                guard let sum = statistics?.sumQuantity() else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: Int(sum.doubleValue(for: .count())))
            }
            store.execute(query)
        }
    }

    private func fetchWalkingSteadiness() async -> Double? {
        guard let type = HKQuantityType.quantityType(forIdentifier: .appleWalkingSteadiness) else { return nil }
        return await withCheckedContinuation { continuation in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
            let query = HKSampleQuery(
                sampleType: type,
                predicate: nil,
                limit: 1,
                sortDescriptors: [sort]
            ) { _, samples, _ in
                guard let sample = samples?.first as? HKQuantitySample else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: sample.quantity.doubleValue(for: .percent()))
            }
            store.execute(query)
        }
    }

    private func fetchLastWorkout() async -> WorkoutSummary? {
        await withCheckedContinuation { continuation in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
            let predicate = HKQuery.predicateForSamples(
                withStart: Date.now.addingTimeInterval(-7 * 24 * 3600),
                end: .now
            )
            let query = HKSampleQuery(
                sampleType: HKObjectType.workoutType(),
                predicate: predicate,
                limit: 1,
                sortDescriptors: [sort]
            ) { _, samples, _ in
                guard let workout = samples?.first as? HKWorkout else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: WorkoutSummary(
                    activityName: workout.workoutActivityType.thermyxDisplayName,
                    start: workout.startDate,
                    duration: workout.duration
                ))
            }
            store.execute(query)
        }
    }

    // MARK: - Writing

    /// Saves a completed Thermyx session so heat exposure and standing time
    /// appear alongside the user's other health data.
    func saveSession(start: Date, end: Date, heatExposureSeconds: TimeInterval, peakRisk: ThermyxRiskLevel?) async {
        guard isAvailable, availability == .authorized, end > start else { return }

        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .other
        let builder = HKWorkoutBuilder(healthStore: store, configuration: configuration, device: .local())

        var metadata: [String: Any] = [
            HKMetadataKeyWorkoutBrandName: "Thermyx",
            "ThermyxHeatExposureSeconds": heatExposureSeconds
        ]
        if let peakRisk {
            metadata["ThermyxPeakRisk"] = peakRisk.rawValue
        }

        do {
            try await builder.beginCollection(at: start)
            try await builder.addMetadata(metadata)
            try await builder.endCollection(at: end)
            _ = try await builder.finishWorkout()
            lastSavedSession = end
            lastError = nil
            await refreshContext()
        } catch {
            lastError = error.localizedDescription
        }
    }
}

private extension HKWorkoutActivityType {
    var thermyxDisplayName: String {
        switch self {
        case .walking: return "Walk"
        case .running: return "Run"
        case .hiking: return "Hike"
        case .cycling: return "Cycle"
        case .functionalStrengthTraining, .traditionalStrengthTraining: return "Strength"
        case .highIntensityIntervalTraining: return "HIIT"
        default: return "Workout"
        }
    }
}
