import Foundation

/// Pragmatic email check: one `@`, a dotted domain, no spaces. Not a full RFC 5322 parser.
public func isValidEmail(_ value: String) -> Bool {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
        .range(of: #"^[A-Za-z0-9._%+\-']+@[A-Za-z0-9](?:[A-Za-z0-9\-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9\-]*[A-Za-z0-9])?)*\.[A-Za-z]{2,}$"#, options: .regularExpression) != nil
}
