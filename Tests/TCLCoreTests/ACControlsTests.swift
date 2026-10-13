import XCTest
@testable import TCLCore

final class ACControlsTests: XCTestCase {
    private func ac(_ values: [String: Any], online: Bool = true) throws -> AirConditioner {
        var reported: [String: Any] = ["powerSwitch": 1, "workMode": 1, "targetTemperature": 24]
        reported.merge(values) { _, new in new }
        return try XCTUnwrap(AirConditioner.parse(["deviceId": "fixture", "deviceName": "Split AC-1", "isOnline": online ? 1 : 0],
            shadow: ["state": ["reported": reported, "desired": ["workMode": 4, "ECO": 1]]]))
    }

    func testBedroomSevenSpeedProtocol() throws {
        let bedroom = try ac(["windSpeed7Gear": 0, "windSpeedAutoSwitch": 1, "ECO": 0])
        XCTAssertEqual(bedroom.mode, .cool)
        XCTAssertEqual(bedroom.fanSpeed, .auto)
        XCTAssertEqual(try bedroom.desiredState(for: .fan(.high)), ["windSpeed7Gear": 6, "windSpeedAutoSwitch": 0, "ECO": 0])
        XCTAssertEqual(try bedroom.desiredState(for: .fan(.turbo))["windSpeed7Gear"], 7)
        XCTAssertFalse(bedroom.confirms(.feature(.eco, true)))
        XCTAssertThrowsError(try bedroom.desiredState(for: .fan(.quiet)))
    }

    func testOfficeFanFlagsAndAirflowProtocols() throws {
        let office = try ac(["windSpeed": 2, "silenceSwitch": 1, "turbo": 0, "ECO": 1,
                             "verticalDirection": 1, "verticalSwitch": 1, "horizontalDirection": 1])
        XCTAssertEqual(office.fanSpeed, .quiet)
        XCTAssertEqual(try office.desiredState(for: .fan(.turbo)), ["windSpeed": 6, "turbo": 1, "silenceSwitch": 0, "ECO": 0])
        XCTAssertEqual(try office.desiredState(for: .airflow(.vertical, .middle)), ["verticalDirection": 11, "verticalSwitch": 0])
        XCTAssertEqual(try office.desiredState(for: .airflow(.horizontal, .swing)), ["horizontalDirection": 1])
        XCTAssertTrue(office.confirms(.airflow(.vertical, .swing)))
        let stopped = try ac(["verticalDirection": 1, "verticalSwitch": 0])
        XCTAssertFalse(stopped.confirms(.airflow(.vertical, .swing)))
    }

    func testModesEcoAndSleepGuards() throws {
        let device = try ac(["ECO": 1, "turbo": 1, "sleep": 2])
        XCTAssertEqual(try device.desiredState(for: .mode(.heat)), ["workMode": 4, "ECO": 0, "turbo": 0, "sleep": 0])
        XCTAssertEqual(try device.desiredState(for: .sleep(.child)), ["sleep": 3])
        XCTAssertEqual(try device.desiredState(for: .feature(.eco, true)), ["ECO": 1, "turbo": 0])
        let dry = try ac(["workMode": 2, "windSpeed": 0, "ECO": 0, "sleep": 0])
        XCTAssertThrowsError(try dry.desiredState(for: .fan(.high)))
        XCTAssertThrowsError(try dry.desiredState(for: .feature(.eco, true)))
        XCTAssertThrowsError(try dry.desiredState(for: .sleep(.standard)))
    }

    func testUnavailableControlsAndOfflineCommandsAreRejected() throws {
        let missing = try ac(["ECO": -1, "sleep": -1, "workMode": -1])
        XCTAssertNil(missing.feature(.eco))
        XCTAssertNil(missing.sleep)
        XCTAssertTrue(missing.modes.isEmpty)
        XCTAssertThrowsError(try missing.desiredState(for: .feature(.eco, true)))
        XCTAssertThrowsError(try missing.desiredState(for: .airflow(.vertical, .swing)))
        let off = try ac(["powerSwitch": 0, "ECO": 0])
        XCTAssertThrowsError(try off.desiredState(for: .feature(.eco, true)))
        XCTAssertEqual(try off.desiredState(for: .power(true)), ["powerSwitch": 1])
        let offline = try ac([:], online: false)
        XCTAssertThrowsError(try offline.desiredState(for: .power(true)))
    }

    func testApplyingPredictsStateWithoutMutatingTheOriginal() throws {
        let unit = try XCTUnwrap(AirConditioner.parse(["deviceId": "ac-o", "deviceName": "Split AC", "isOnline": 1],
            shadow: ["state": ["reported": ["powerSwitch": 0, "targetTemperature": 24, "workMode": 1, "windSpeed": 0, "ECO": 1]]]))
        XCTAssertThrowsError(try unit.applying(.mode(.heat)), "controls need power on, same as sending")
        let on = try unit.applying(.power(true))
        XCTAssertTrue(on.power)
        XCTAssertFalse(unit.power)
        XCTAssertEqual(try on.applying(.temperature(21)).targetTemperature, 21)
        let heating = try on.applying(.mode(.heat))
        XCTAssertEqual(heating.mode, .heat)
        XCTAssertEqual(heating.feature(.eco), false, "changing mode clears Eco, as the command does")
        XCTAssertTrue(try heating.applying(.fan(.high)).confirms(.fan(.high)))
    }
}
