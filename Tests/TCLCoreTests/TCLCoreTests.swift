import XCTest
@testable import TCLCore

final class TCLCoreTests: XCTestCase {
    // Published AWS IAM SigV4 example: GET ListUsers, 2015-08-30.
    func testAWSCanonicalRequestVector() {
        let result = SigV4.canonicalRequest(method: "GET", url: URL(string: "https://iam.amazonaws.com/?Action=ListUsers&Version=2010-05-08")!,
            headers: ["content-type": "application/x-www-form-urlencoded; charset=utf-8", "host": "iam.amazonaws.com", "x-amz-date": "20150830T123600Z"], body: Data())
        XCTAssertEqual(SigV4.hash(Data(result.request.utf8)), "f536975d06c0309214f805bb90ccff089219ecd68b2577efef23edd43b7e1a59")
        XCTAssertEqual(result.signedHeaders, "content-type;host;x-amz-date")
        let key = SigV4.signingKey(secret: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY", date: "20150830", region: "us-east-1", service: "iam")
        XCTAssertEqual(key.map { String(format: "%02x", $0) }.joined(), "c4afb1cc5771d871763a393e44b703571b55cc28424d1a5e86da6ed3c154a4b9")
    }

    func testCanonicalTopicEncodingAndToken() {
        let url = URL(string: "https://data.iot.ap-southeast-1.amazonaws.com/topics/%24aws/things/a%20b/shadow/update?qos=1")!
        let result = SigV4.canonicalRequest(method: "POST", url: url, headers: ["host": url.host!, "x-amz-security-token": "temporary"], body: Data("{}".utf8))
        XCTAssertTrue(result.request.contains("/topics/%2524aws/things/a%2520b/shadow/update\nqos=1\n"))
        XCTAssertTrue(result.signedHeaders.contains("x-amz-security-token"))
    }

    func testReportedStateOverridesDesiredAndAliases() throws {
        let device = try XCTUnwrap(AirConditioner.parse(["deviceId": "ac-1", "deviceName": "Split AC", "nickName": "Bedroom", "isOnline": "1"],
            shadow: ["state": ["reported": ["powerSwitch": 0, "targetTemperature": 24, "currentTemperature": "27"], "desired": ["powerSwitch": 1]]]))
        XCTAssertTrue(device.isSupported)
        XCTAssertTrue(device.isOnline)
        XCTAssertFalse(device.power)
        XCTAssertEqual(device.targetTemperature, 24)
        XCTAssertEqual(device.currentTemperature, 27)
        XCTAssertTrue(device.modes.isEmpty)
        XCTAssertTrue(device.fanSpeeds.isEmpty)
    }

    func testUnknownModelAndMissingStateDisableControl() throws {
        let unknown = try XCTUnwrap(AirConditioner.parse(["device_id": "ac-2", "device_name": "Portable AC", "is_online": 1], shadow: ["state": ["reported": ["powerSwitch": 1]]]))
        XCTAssertFalse(unknown.isSupported)
        let noState = try XCTUnwrap(AirConditioner.parse(["deviceId": "ac-3", "deviceName": "Split AC", "isOnline": 1], shadow: nil))
        XCTAssertFalse(noState.isSupported)
        XCTAssertNil(noState.currentTemperature)
        let sentinel = try XCTUnwrap(AirConditioner.parse(["deviceId": "ac-4", "deviceName": "Split AC", "isOnline": 1], shadow: ["state": ["reported": ["powerSwitch": -1, "targetTemperature": -1, "currentTemperature": -1]]]))
        XCTAssertFalse(sentinel.isSupported)
        XCTAssertNil(sentinel.targetTemperature)
        XCTAssertNil(sentinel.currentTemperature)
    }

    func testBootstrapURLAndJWTParsing() {
        XCTAssertNotNil(trustedURL("https://prod-sg.aws.tcljd.com"))
        XCTAssertNil(trustedURL("https://prod-sg.aws.tcljd.com.evil.example"))
        XCTAssertNil(trustedURL("http://prod-sg.aws.tcljd.com"))
        XCTAssertEqual(jwtSubject("e30.eyJzdWIiOiJhcC1zb3V0aGVhc3QtMTpleGFtcGxlIn0.signature"), "ap-southeast-1:example")
        XCTAssertNil(jwtSubject("invalid"))
        XCTAssertEqual(md5("test"), "098f6bcd4621d373cade4e832627b4f6")
    }

    func testAuthenticatedRequestsRejectRedirects() {
        let delegate = CloudSessionDelegate()
        let original = URL(string: "https://regional.tcljd.com/v3/auth/refresh_tokens")!
        let task = URLSession.shared.dataTask(with: original)
        defer { task.cancel() }
        for destination in ["https://regional.tcljd.com/other", "https://untrusted.example/collect"] {
            var redirected = URLRequest(url: URL(string: destination)!)
            redirected.setValue("test-session", forHTTPHeaderField: "accessToken")
            let response = HTTPURLResponse(url: original, statusCode: 307, httpVersion: nil,
                                           headerFields: ["Location": destination])!
            var completed = false
            delegate.urlSession(.shared, task: task, willPerformHTTPRedirection: response,
                                newRequest: redirected) { request in
                XCTAssertNil(request, "Authenticated requests must not follow redirects.")
                completed = true
            }
            XCTAssertTrue(completed)
        }
    }


    func testOutdoorTemperatureIsOptionalAndRangeChecked() throws {
        func parse(_ reported: [String: Any]) throws -> AirConditioner {
            try XCTUnwrap(AirConditioner.parse(["deviceId": "ac-9", "deviceName": "Split AC", "isOnline": 1],
                                               shadow: ["state": ["reported": ["powerSwitch": 1].merging(reported) { $1 }]]))
        }
        XCTAssertEqual(try parse(["externalUnitTemperature": 34]).outdoorTemperature, 34)
        XCTAssertEqual(try parse(["externalUnitTemperature": -3]).outdoorTemperature, -3)
        XCTAssertNil(try parse([:]).outdoorTemperature)
        XCTAssertNil(try parse(["externalUnitTemperature": -1]).outdoorTemperature)
        XCTAssertNil(try parse(["externalUnitTemperature": 255]).outdoorTemperature)
    }

    func testHealthModeIsAFeatureToggle() throws {
        let device = try XCTUnwrap(AirConditioner.parse(["deviceId": "ac-h", "deviceName": "Split AC", "isOnline": 1],
                                                        shadow: ["state": ["reported": ["powerSwitch": 1, "workMode": 1, "healthy": 0]]]))
        XCTAssertEqual(device.feature(.health), false)
        XCTAssertEqual(try device.desiredState(for: .feature(.health, true)), ["healthy": 1])
    }

    func testSetpointLimitsComeFromTheUnitWithSafeFallbacks() throws {
        func parse(_ extra: [String: Any]) throws -> AirConditioner {
            try XCTUnwrap(AirConditioner.parse(["deviceId": "ac-l", "deviceName": "Split AC", "isOnline": 1],
                shadow: ["state": ["reported": ["powerSwitch": 1, "targetTemperature": 24].merging(extra) { $1 }]]))
        }
        let reported = try parse(["lowerTemperatureLimit": 16, "upperTemperatureLimit": 31])
        XCTAssertEqual(reported.minTemperature, 16)
        XCTAssertEqual(reported.maxTemperature, 31)
        XCTAssertEqual(try parse([:]).maxTemperature, 30, "missing limits keep the default")
        XCTAssertEqual(try parse(["upperTemperatureLimit": 90]).maxTemperature, 30, "implausible limits are ignored")
        XCTAssertEqual(try parse(["lowerTemperatureLimit": 2]).minTemperature, 16)
    }
}
