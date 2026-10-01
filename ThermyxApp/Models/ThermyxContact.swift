import Foundation

struct ThermyxContact: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var phoneNumber: String
    var enabled: Bool

    init(name: String, phoneNumber: String, enabled: Bool = true) {
        self.id = UUID()
        self.name = name
        self.phoneNumber = phoneNumber
        self.enabled = enabled
    }
}

struct ThermyxAlertEvent: Codable {
    /// What prompted the event. `status` is the once-a-minute heartbeat and
    /// never texts anyone; `alert` is an escalation; `sos` is the Call 911
    /// button; `ok` is the wearer checking in. Optional so events from older
    /// builds still decode.
    enum Kind: String, Codable {
        case status, alert, sos, ok
    }

    let deviceID: String
    let level: String
    let reasons: [String]
    let recipients: [String]
    let timestamp: Date
    /// The readings of the foot that drove the event (the hotter one when
    /// neither did), never an average of the two.
    let readings: AlertReadings
    var kind: Kind? = nil
    /// Which foot `readings` came from.
    var foot: String? = nil
    var left: AlertReadings? = nil
    var right: AlertReadings? = nil
    var location: AlertLocation? = nil

    struct AlertReadings: Codable {
        let footTemperatureC: Double?
        let ambientTemperatureC: Double?
        let gaitStability: Double?
        let pressureBalance: Double?
        let batteryPercent: Int?

        init(footTemperatureC: Double?, ambientTemperatureC: Double?, gaitStability: Double?, pressureBalance: Double?, batteryPercent: Int?) {
            self.footTemperatureC = footTemperatureC
            self.ambientTemperatureC = ambientTemperatureC
            self.gaitStability = gaitStability
            self.pressureBalance = pressureBalance
            self.batteryPercent = batteryPercent
        }

        init(_ reading: ThermyxReading) {
            self.init(
                footTemperatureC: reading.footTemperatureC,
                ambientTemperatureC: reading.ambientTemperatureC,
                gaitStability: reading.gaitStability,
                pressureBalance: reading.pressureBalance,
                batteryPercent: reading.batteryPercent
            )
        }
    }

    struct AlertLocation: Codable, Equatable {
        let latitude: Double
        let longitude: Double
        let accuracyM: Double?

        var mapsURL: URL? {
            URL(string: String(format: "https://maps.apple.com/?ll=%.5f,%.5f&q=Thermyx%%20wearer", latitude, longitude))
        }
    }

    /// Rebuilds both feet for the watcher, when the event carried them.
    var bilateral: BilateralReading? {
        func reading(_ foot: Foot, _ values: AlertReadings?) -> ThermyxReading? {
            guard let values else { return nil }
            return ThermyxReading(
                foot: foot,
                timestamp: timestamp,
                footTemperatureC: values.footTemperatureC,
                ambientTemperatureC: values.ambientTemperatureC,
                pressureBalance: values.pressureBalance,
                gaitStability: values.gaitStability,
                batteryPercent: values.batteryPercent,
                thermalMode: .off
            )
        }
        let pair = BilateralReading(left: reading(.left, left), right: reading(.right, right))
        return pair.hasAny ? pair : nil
    }
}
