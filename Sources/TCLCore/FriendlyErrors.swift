import Foundation

/// User-facing wording for failures. Never includes server response bodies, which can echo session data.
enum FriendlyError {
    static func network(_ error: Error) -> String {
        switch (error as NSError).code {
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorDataNotAllowed, NSURLErrorInternationalRoamingOff:
            return "You're offline. Check your internet connection and try again."
        case NSURLErrorTimedOut:
            return "TCL took too long to respond. Try again in a moment."
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate,
             NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateNotYetValid, NSURLErrorClientCertificateRejected:
            return "Couldn't make a secure connection to TCL. If you're on a VPN or public Wi-Fi, try another network."
        default:
            return "Couldn't reach TCL. Check your internet connection and try again."
        }
    }

    static func http(_ status: Int) -> String {
        switch status {
        case 401, 403: return "TCL didn't accept your sign-in. Sign in again."
        case 429: return "Too many attempts. Wait a few minutes and try again."
        case 500...599: return "TCL's servers are having trouble. Try again in a few minutes."
        default: return "TCL couldn't complete the request (error \(status)). Try again in a moment."
        }
    }

    static let wrongCredentials = "Incorrect email or password. Check them and your region, and use your TCL Home password, not your Google or Apple password. If it keeps failing, TCL may be asking you to verify your account in the TCL Home app."
}
