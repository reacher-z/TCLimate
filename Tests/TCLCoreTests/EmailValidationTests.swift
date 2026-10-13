import XCTest
@testable import TCLCore

final class EmailValidationTests: XCTestCase {
    func testAcceptsCommonAddresses() {
        for email in ["a@b.co", "first.last+tag@mail.example.com", "  user_1@sub-domain.example.org  ", "o'brien@example.pk"] {
            XCTAssertTrue(isValidEmail(email), email)
        }
    }

    func testRejectsMalformedAddresses() {
        for email in ["", "plain", "a@b", "a@@b.com", "a b@c.com", "@b.com", "a@.com", "a@b..com", "a@-b.com", "a@b.c", "a@b.com."] {
            XCTAssertFalse(isValidEmail(email), email)
        }
    }
}
