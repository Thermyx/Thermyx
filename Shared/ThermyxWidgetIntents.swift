import AppIntents
import Foundation
import WidgetKit

// The buttons on the widgets and the Live Activity. A button can't talk to
// the insoles itself (the app owns Bluetooth), so it leaves a request in the
// App Group and tells the app, which applies it the way the in-app control
// does, including the heat lockout.

/// The thermal modes as an App Intents choice.
enum ThermyxModeChoice: String, AppEnum {
    case auto, cool, heat, off

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Thermal mode"
    static let caseDisplayRepresentations: [ThermyxModeChoice: DisplayRepresentation] = [
        .auto: "Auto", .cool: "Cool", .heat: "Heat", .off: "Off"
    ]

    var widgetMode: ThermyxWidgetMode { ThermyxWidgetMode(rawValue: rawValue) ?? .auto }

    init(_ mode: ThermyxWidgetMode) { self = ThermyxModeChoice(rawValue: mode.rawValue) ?? .auto }
}

/// Switches the insoles to a mode. A Live Activity intent, so iOS runs it in
/// the app's process where Bluetooth lives; the Home Screen widget uses it
/// too.
struct SetThermalModeIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Set thermal mode"
    static let description = IntentDescription("Switches your Thermyx insoles to Auto, Cool, Heat or Off.")

    @Parameter(title: "Mode")
    var mode: ThermyxModeChoice

    init() { mode = .auto }
    init(mode: ThermyxWidgetMode) { self.mode = ThermyxModeChoice(mode) }

    func perform() async throws -> some IntentResult {
        ThermyxModeInbox.submit(mode.widgetMode)
        return .result()
    }
}

/// Picks one of Temperature, Pressure and Gait for the sole.
enum ThermyxSoleChoice: String, AppEnum {
    case temperature, pressure, gait

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Measurement"
    static let caseDisplayRepresentations: [ThermyxSoleChoice: DisplayRepresentation] = [
        .temperature: "Temperature", .pressure: "Pressure", .gait: "Gait"
    ]
}

struct SetSoleViewIntent: AppIntent {
    static let title: LocalizedStringResource = "Show a measurement on the sole"

    @Parameter(title: "Measurement")
    var view: ThermyxSoleChoice

    init() { view = .temperature }
    init(view: ThermyxSoleView) { self.view = ThermyxSoleChoice(rawValue: view.rawValue) ?? .temperature }

    func perform() async throws -> some IntentResult {
        ThermyxSoleView.current = ThermyxSoleView(rawValue: view.rawValue) ?? .temperature
        WidgetCenter.shared.reloadTimelines(ofKind: ThermyxShared.widgetKind)
        return .result()
    }
}

/// Switches the sole between Temperature, Pressure and Gait.
struct CycleSoleViewIntent: AppIntent {
    static let title: LocalizedStringResource = "Change what the sole shows"

    init() {}

    func perform() async throws -> some IntentResult {
        ThermyxSoleView.current = ThermyxSoleView.current.next
        WidgetCenter.shared.reloadTimelines(ofKind: ThermyxShared.widgetKind)
        return .result()
    }
}

/// The hand-off between a button and the app.
enum ThermyxModeInbox {
    private static let modeKey = "thermyx.widget.requestedMode"
    private static let atKey = "thermyx.widget.requestedAt"
    private static let notification = "com.thermyx.app.a.modeRequest"
    /// A request nobody picked up in this long is stale: the wearer has
    /// moved on, and a late Heat would be a surprise.
    static let expiry: TimeInterval = 120

    /// Set by the app: called when a request arrives.
    static var onRequest: (() -> Void)?

    /// Leaves the request, wakes the app and redraws the widgets.
    static func submit(_ mode: ThermyxWidgetMode) {
        ThermyxShared.defaults?.set(mode.rawValue, forKey: modeKey)
        ThermyxShared.defaults?.set(Date.now.timeIntervalSince1970, forKey: atKey)
        WidgetCenter.shared.reloadTimelines(ofKind: ThermyxShared.widgetKind)
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(notification as CFString), nil, nil, true)
        onRequest?()
    }

    /// The request, if there is a fresh one, and clears it.
    static func take(now: Date = .now) -> ThermyxWidgetMode? {
        let mode = pending(now: now)
        clear()
        return mode
    }

    /// The request without clearing it, for showing "switching…" on the
    /// widget until the app confirms.
    static func pending(now: Date = .now) -> ThermyxWidgetMode? {
        guard let defaults = ThermyxShared.defaults,
              let raw = defaults.string(forKey: modeKey), let mode = ThermyxWidgetMode(rawValue: raw),
              now.timeIntervalSince1970 - defaults.double(forKey: atKey) < expiry
        else { return nil }
        return mode
    }

    static func clear() {
        ThermyxShared.defaults?.removeObject(forKey: modeKey)
        ThermyxShared.defaults?.removeObject(forKey: atKey)
    }

    /// The app listens for requests made while it's running in the
    /// background (a widget button runs in another process).
    static func startListening() {
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil, { _, _, _, _, _ in
            ThermyxModeInbox.onRequest?()
        }, notification as CFString, nil, .deliverImmediately)
    }
}


// MARK: - Safety widget

/// "I'm OK" from the Safety widget: tells the trusted circle, from the app's
/// process (it has the relay connection and what to say).
struct CheckInIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Tell my circle I'm OK"
    static let description = IntentDescription("Lets your Thermyx trusted circle know you're OK.")

    init() {}

    func perform() async throws -> some IntentResult {
        ThermyxCheckInInbox.submit()
        return .result()
    }
}

/// A check-in waiting for the app, in the App Group.
enum ThermyxCheckInInbox {
    private static let atKey = "thermyx.widget.checkInAt"
    private static let notification = "com.thermyx.app.a.checkIn"
    /// A check-in older than this is dropped rather than sent late.
    static let expiry: TimeInterval = 120

    static var onRequest: (() -> Void)?

    static func submit(now: Date = .now) {
        ThermyxShared.defaults?.set(now.timeIntervalSince1970, forKey: atKey)
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(notification as CFString), nil, nil, true)
        onRequest?()
    }

    /// The pending check-in's time, once; nil if none or too old.
    static func take(now: Date = .now) -> Date? {
        guard let raw = ThermyxShared.defaults?.double(forKey: atKey), raw > 0 else { return nil }
        ThermyxShared.defaults?.removeObject(forKey: atKey)
        let at = Date(timeIntervalSince1970: raw)
        return now.timeIntervalSince(at) <= expiry ? at : nil
    }

    static func startListening() {
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil, { _, _, _, _, _ in
            ThermyxCheckInInbox.onRequest?()
        }, notification as CFString, nil, .deliverImmediately)
    }
}
