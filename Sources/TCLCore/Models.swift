import Foundation

public enum AccountRegion: String, CaseIterable, Codable, Identifiable {
    case singapore, europe, usa
    public var id: String { rawValue }
    public var title: String {
        switch self { case .singapore: return "Singapore (Pakistan)"; case .europe: return "Europe"; case .usa: return "United States" }
    }
    var host: String {
        switch self { case .singapore: return "sg.account.tcl.com"; case .europe: return "pa.account.tcl.com"; case .usa: return "us.account.tcl.com" }
    }
}

public enum ACMode: String, CaseIterable, Identifiable {
    case auto, cool, dry, fan, heat
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
    var wireValue: Int { [.auto: 0, .cool: 1, .dry: 2, .fan: 3, .heat: 4][self]! }
}
public enum ACFanSpeed: String, CaseIterable, Identifiable {
    case auto, low, medium, high, quiet, mediumLow, mediumHigh, speed1, turbo
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .mediumLow: return "Medium-low"
        case .mediumHigh: return "Medium-high"
        case .speed1: return "Speed 1"
        default: return rawValue.capitalized
        }
    }
}
public enum ACFeature: String, CaseIterable, Identifiable {
    case eco = "ECO", health = "healthy", display = "screen", beep = "beepSwitch"
    public var id: String { rawValue }
    public var title: String {
        switch self { case .eco: return "Eco"; case .health: return "Health"; case .display: return "Display light"; case .beep: return "Beep" }
    }
}
public enum ACAxis: String, CaseIterable, Identifiable {
    case vertical, horizontal
    public var id: String { rawValue }
    var directionKey: String { rawValue + "Direction" }
    var switchKey: String { rawValue + "Switch" }
    public var title: String { self == .vertical ? "Up / down" : "Left / right" }
}
public enum ACAirflow: Int, CaseIterable, Identifiable {
    case swing = 1, stop = 8, first = 9, second = 10, middle = 11, fourth = 12, last = 13
    public var id: Int { rawValue }
    public func title(for axis: ACAxis) -> String {
        switch self {
        case .swing: return "Swing"
        case .stop: return "Stop swing"
        default:
            return (axis == .vertical ? ["Top", "Upper", "Middle", "Lower", "Bottom"] : ["Left", "Center-left", "Center", "Center-right", "Right"])[rawValue - 9]
        }
    }
}
public enum ACSleep: Int, CaseIterable, Identifiable {
    case off, standard, elderly, child
    public var id: Int { rawValue }
    public var title: String { String(describing: self).capitalized }
}
public enum ACCommand {
    case power(Bool), temperature(Double), mode(ACMode), fan(ACFanSpeed)
    case feature(ACFeature, Bool), airflow(ACAxis, ACAirflow), sleep(ACSleep)
}

public struct AirConditioner: Identifiable {
    public let id: String
    public let name: String
    public let isOnline: Bool
    public let isSupported: Bool
    public let power: Bool
    public let targetTemperature: Double?
    public let currentTemperature: Double?
    /// Outdoor unit sensor, when the model reports one.
    public let outdoorTemperature: Double?
    public let minTemperature: Double
    public let maxTemperature: Double
    let controls: [String: Int]
    public let model: String
    let productKey: String
    public let statusMessage: String?

    /// A made-up unit with every control present, used only to pre-build the UI at launch. Never sent anywhere.
    public static var warmUpSample: AirConditioner {
        parse(["deviceId": "warm-up", "deviceName": "Split AC", "nickName": "AC", "isOnline": 1, "productKey": "warm-up"],
              shadow: ["state": ["reported": ["powerSwitch": 1, "targetTemperature": 24, "currentTemperature": 27, "externalUnitTemperature": 30,
                                              "workMode": 1, "windSpeed": 0, "sleep": 0, "verticalDirection": 1, "horizontalDirection": 11,
                                              "healthy": 0, "ECO": 0, "screen": 1, "beepSwitch": 1]]])!
    }

    /// The same unit with a different online status, from TCL's online flag.
    public func with(online: Bool) -> AirConditioner {
        AirConditioner(id: id, name: name, isOnline: online, isSupported: isSupported, power: power,
                       targetTemperature: targetTemperature, currentTemperature: currentTemperature,
                       outdoorTemperature: outdoorTemperature, minTemperature: minTemperature, maxTemperature: maxTemperature,
                       controls: controls, model: model, productKey: productKey, statusMessage: statusMessage)
    }

    static func parse(_ thing: [String: Any], shadow: [String: Any]?, failure: String? = nil) -> AirConditioner? {
        guard let id = text(thing, "device_id", "deviceId"), !id.isEmpty else { return nil }
        let model = text(thing, "device_name", "deviceName") ?? "Unknown model"
        let suffix = model.hasPrefix("Split AC-") ? String(model.dropFirst("Split AC-".count)) : ""
        let supportedFamily = model == "Split AC" || (!suffix.isEmpty && suffix.allSatisfy { $0.isNumber })
        let state = shadow?["state"] as? [String: Any]
        let reported = state?["reported"] as? [String: Any] ?? [:]
        let rawPower = number(reported["powerSwitch"])
        let hasPower = rawPower == 0 || rawPower == 1
        return AirConditioner(id: id,
            name: text(thing, "nick_name", "nickName") ?? model,
            isOnline: number(thing["is_online"] ?? thing["isOnline"]) == 1,
            isSupported: supportedFamily && hasPower,
            power: number(reported["powerSwitch"]) == 1,
            targetTemperature: temperature(reported["targetTemperature"]),
            currentTemperature: temperature(reported["currentTemperature"]),
            outdoorTemperature: temperature(reported["externalUnitTemperature"]).flatMap { (-40...80).contains($0) ? $0 : nil },
            minTemperature: limit(reported["lowerTemperatureLimit"], fallback: 16, range: 10...30),
            maxTemperature: limit(reported["upperTemperatureLimit"], fallback: 30, range: 20...35),
            controls: supportedFamily ? reported.reduce(into: [String: Int]()) { values, entry in
                if let n = number(entry.value), n.isFinite, n >= 0, n <= 100, n.rounded() == n { values[entry.key] = Int(n) }
            } : [:],
            model: model, productKey: text(thing, "productKey", "product_key") ?? "",
            statusMessage: failure ?? (supportedFamily ? (hasPower ? nil : "No supported device state") : "Model support has not been verified"))
    }
}

/// The unit's own setpoint limit when it reports a sensible one; otherwise the conservative default.
private func limit(_ value: Any?, fallback: Double, range: ClosedRange<Double>) -> Double {
    guard let n = number(value), range.contains(n), n.rounded() == n else { return fallback }
    return n
}

private func temperature(_ value: Any?) -> Double? {
    guard let value = number(value), value.isFinite, value != -1 else { return nil }
    return value
}

func text(_ object: [String: Any], _ keys: String...) -> String? {
    for key in keys { if let value = object[key] as? String, !value.isEmpty { return value } }
    return nil
}
func number(_ value: Any?) -> Double? {
    if let n = value as? NSNumber { return n.doubleValue }
    if let s = value as? String { return Double(s) }
    return nil
}

public enum CloudError: LocalizedError {
    case message(String)
    public var errorDescription: String? { switch self { case .message(let message): return message } }
}
