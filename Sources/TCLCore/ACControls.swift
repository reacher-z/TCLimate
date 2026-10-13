import Foundation

extension AirConditioner {
    public var mode: ACMode? { ACMode.allCases.first { $0.wireValue == controls["workMode"] } }
    public var modes: [ACMode] { mode == nil ? [] : ACMode.allCases }
    public var usesSevenSpeedFan: Bool { controls["windSpeed7Gear"] != nil && controls["windSpeedAutoSwitch"] != nil }
    public var fanSpeeds: [ACFanSpeed] {
        if usesSevenSpeedFan { return [.auto, .speed1, .low, .mediumLow, .medium, .mediumHigh, .high, .turbo] }
        guard controls["windSpeed"] != nil else { return [] }
        var values: [ACFanSpeed] = [.auto, .low, .mediumLow, .medium, .mediumHigh, .high]
        if controls["silenceSwitch"] != nil { values.append(.quiet) }
        if controls["turbo"] != nil { values.append(.turbo) }
        return values
    }
    public var fanSpeed: ACFanSpeed? {
        if usesSevenSpeedFan {
            if controls["windSpeedAutoSwitch"] == 1 { return .auto }
            return [0: .auto, 1: .speed1, 2: .low, 3: .mediumLow, 4: .medium, 5: .mediumHigh, 6: .high, 7: .turbo][controls["windSpeed7Gear"] ?? -1]
        }
        if controls["turbo"] == 1 { return .turbo }
        if controls["silenceSwitch"] == 1 { return .quiet }
        return [0: .auto, 2: .low, 3: .mediumLow, 4: .medium, 5: .mediumHigh, 6: .high][controls["windSpeed"] ?? -1]
    }
    public func feature(_ feature: ACFeature) -> Bool? {
        guard let value = controls[feature.rawValue], value == 0 || value == 1 else { return nil }
        return value == 1
    }
    public func supportsAirflow(_ axis: ACAxis) -> Bool {
        guard let value = controls[axis.directionKey] else { return false }
        return (1...4).contains(value) || (8...13).contains(value)
    }
    public func airflow(_ axis: ACAxis) -> ACAirflow? { controls[axis.directionKey].flatMap(ACAirflow.init(rawValue:)) }
    public var sleep: ACSleep? { controls["sleep"].flatMap(ACSleep.init(rawValue:)) }
    public var hasExtraControls: Bool {
        !modes.isEmpty || !fanSpeeds.isEmpty || sleep != nil || ACFeature.allCases.contains { feature($0) != nil } || ACAxis.allCases.contains { supportsAirflow($0) }
    }

    /// Encodes only recognized, reported controls. Never uses desired shadow state.
    func desiredState(for command: ACCommand) throws -> [String: Int] {
        guard isSupported, isOnline else { throw CloudError.message("This AC is offline or its controls are unavailable.") }
        switch command {
        case .power(let on): return ["powerSwitch": on ? 1 : 0]
        case .temperature(let value):
            guard targetTemperature != nil, value.isFinite, (minTemperature...maxTemperature).contains(value), value.rounded() == value else {
                throw CloudError.message("Choose a whole temperature between 16 and 30°C.")
            }
            return ["targetTemperature": Int(value)]
        default: break
        }
        guard power else { throw CloudError.message("Turn on the AC before changing these controls.") }
        var desired: [String: Int] = [:]
        switch command {
        case .mode(let value):
            guard modes.contains(value) else { throw unsupported() }
            desired["workMode"] = value.wireValue
            for key in ["ECO", "turbo", "sleep"] where controls[key] != nil { desired[key] = 0 }
        case .fan(let value):
            guard fanSpeeds.contains(value), mode != .dry else { throw unsupported() }
            let speeds: [ACFanSpeed: Int] = [.auto: 0, .speed1: 1, .quiet: 2, .low: 2, .mediumLow: 3, .medium: 4, .mediumHigh: 5, .high: 6, .turbo: 7]
            if usesSevenSpeedFan {
                desired = ["windSpeedAutoSwitch": value == .auto ? 1 : 0, "windSpeed7Gear": speeds[value]!]
            } else {
                desired["windSpeed"] = value == .turbo ? 6 : speeds[value]!
                for (key, flag) in [("turbo", value == .turbo), ("silenceSwitch", value == .quiet)] where controls[key] != nil {
                    desired[key] = flag ? 1 : 0
                }
                if controls["highTemperatureWind"] != nil { desired["highTemperatureWind"] = 0 }
            }
            if controls["ECO"] != nil { desired["ECO"] = 0 }
        case .feature(let option, let on):
            guard feature(option) != nil else { throw unsupported() }
            if option == .eco && on {
                guard mode == .cool else { throw CloudError.message("Eco is available in Cool mode.") }
                if controls["turbo"] != nil { desired["turbo"] = 0 }
            }
            desired[option.rawValue] = on ? 1 : 0
        case .airflow(let axis, let value):
            guard supportsAirflow(axis) else { throw unsupported() }
            desired[axis.directionKey] = value.rawValue
            if controls[axis.switchKey] != nil { desired[axis.switchKey] = value == .swing ? 1 : 0 }
        case .sleep(let value):
            guard sleep != nil, value == .off || mode == .cool || mode == .heat else { throw unsupported() }
            desired["sleep"] = value.rawValue
        case .power, .temperature: break
        }
        return desired
    }

    /// The state this unit should report once `command` is applied, so the UI can update before the cloud confirms.
    /// Throws exactly when sending the command would.
    public func applying(_ command: ACCommand) throws -> AirConditioner {
        let desired = try desiredState(for: command)
        return AirConditioner(id: id, name: name, isOnline: isOnline, isSupported: isSupported,
                              power: desired["powerSwitch"].map { $0 == 1 } ?? power,
                              targetTemperature: desired["targetTemperature"].map(Double.init) ?? targetTemperature,
                              currentTemperature: currentTemperature, outdoorTemperature: outdoorTemperature,
                              minTemperature: minTemperature, maxTemperature: maxTemperature,
                              controls: controls.merging(desired) { $1 },
                              model: model, productKey: productKey, statusMessage: statusMessage)
    }

    public func confirms(_ command: ACCommand) -> Bool {
        guard statusMessage == nil else { return false }
        switch command {
        case .power(let value): return power == value
        case .temperature(let value): return targetTemperature == value
        case .mode(let value): return mode == value
        case .fan(let value): return fanSpeed == value
        case .feature(let option, let value): return feature(option) == value
        case .airflow(let axis, let value):
            return airflow(axis) == value && (controls[axis.switchKey] == nil || controls[axis.switchKey] == (value == .swing ? 1 : 0))
        case .sleep(let value): return sleep == value
        }
    }

    private func unsupported() -> CloudError { .message("This option is unavailable for the AC's reported state or current mode.") }
}
