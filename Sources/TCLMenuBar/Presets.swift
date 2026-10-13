import Foundation
import TCLCore

/// One-tap settings for common situations. Steps a unit doesn't support or can't take from its current state are dropped.
enum Preset: String, CaseIterable, Identifiable {
    case quietNight, maxCool, warm
    var id: String { rawValue }

    var title: String {
        switch self {
        case .quietNight: return "Quiet night"
        case .maxCool: return "Max cool"
        case .warm: return "Warm"
        }
    }

    var symbol: String {
        switch self {
        case .quietNight: return "moon.stars"
        case .maxCool: return "snowflake"
        case .warm: return "sun.max"
        }
    }

    func commands(for device: AirConditioner) -> [ACCommand] {
        var wanted: [ACCommand] = device.power ? [] : [.power(true)]
        switch self {
        case .quietNight: wanted += [.mode(.cool), .fan(.quiet), .temperature(26), .sleep(.standard), .feature(.display, false)]
        case .maxCool: wanted += [.mode(.cool), .fan(.turbo), .temperature(device.minTemperature)]
        case .warm: wanted += [.mode(.heat), .temperature(24)]
        }
        // Validate each step against the state the previous steps would leave.
        var current = device
        return wanted.filter { command in
            guard let next = try? current.applying(command) else { return false }
            current = next
            return true
        }
    }
}
