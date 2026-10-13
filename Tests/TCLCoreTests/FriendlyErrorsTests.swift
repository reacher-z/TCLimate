import XCTest
@testable import TCLCore

final class FriendlyErrorsTests: XCTestCase {
    func testNetworkFailuresAreClassified() {
        func message(_ code: Int) -> String { FriendlyError.network(NSError(domain: NSURLErrorDomain, code: code)) }
        XCTAssertTrue(message(NSURLErrorNotConnectedToInternet).hasPrefix("You're offline"))
        XCTAssertTrue(message(NSURLErrorTimedOut).hasPrefix("TCL took too long"))
        XCTAssertTrue(message(NSURLErrorServerCertificateUntrusted).contains("secure connection"))
        XCTAssertTrue(message(NSURLErrorCannotFindHost).hasPrefix("Couldn't reach TCL"))
    }

    func testHTTPStatusesAreClassified() {
        XCTAssertTrue(FriendlyError.http(401).contains("Sign in again"))
        XCTAssertTrue(FriendlyError.http(429).hasPrefix("Too many attempts"))
        XCTAssertTrue(FriendlyError.http(503).contains("servers are having trouble"))
        XCTAssertTrue(FriendlyError.http(418).contains("error 418"))
    }
}
