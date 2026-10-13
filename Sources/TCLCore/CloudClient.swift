import Foundation
import CryptoKit

/// Native global TCL Home client. Protocol reference: nemesa/ha-tcl-home-unofficial-integration (MIT).
/// No account data is persisted or logged by this actor.
public actor CloudClient {
    private let session: URLSession
    private var email = ""
    private var password = ""
    private var accountRegion: AccountRegion = .singapore
    private var username = ""
    /// Name and picture from the TCL account, for display only.
    public private(set) var profile: AccountProfile?
    private var countryCode = ""
    private var ssoToken = ""
    private var saasToken = ""
    private var cloudURL: URL?
    private var deviceURL: URL?
    private var awsRegion = ""
    private var credentials: AWSCredentials?
    private var loggedInAt = Date.distantPast

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 25
        configuration.timeoutIntervalForResource = 40
        configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: CloudSessionDelegate(), delegateQueue: nil)
    }

    public func login(email: String, password: String, region: AccountRegion = .singapore) async throws {
        self.email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        self.password = password
        accountRegion = region
        credentials = nil
        saasToken = ""
        guard !self.email.isEmpty, !password.isEmpty else { throw CloudError.message("Enter your TCL account email and TCL password.") }
        let url = URL(string: "https://\(region.host)/account/login?clientId=54148614")!
        let auth = try await json(url: url, body: ["equipment": 2, "password": md5(password), "osType": 1,
            "username": self.email, "clientVersion": "4.8.1", "osVersion": "6.0",
            "deviceModel": "AndroidAndroid SDK built for x86", "captchaRule": 2, "channel": "app"],
            headers: ["th_platform": "android", "th_version": "4.8.1", "th_appbulid": "830"], operation: "TCL sign-in")
        guard number(auth["status"]) == 1, let token = auth["token"] as? String,
            let user = auth["user"] as? [String: Any], let canonicalUser = user["username"] as? String else {
            throw CloudError.message(FriendlyError.wrongCredentials)
        }
        ssoToken = token
        username = canonicalUser
        countryCode = text(user, "countryAbbr", "country_abbr") ?? ""
        profile = AccountProfile(nickname: text(user, "nickname", "nickName"), avatarURL: imageURL(user["headpic"]))
        let urls = try await json(url: URL(string: "https://prod-center.aws.tcljd.com/v3/global/cloud_url_get")!,
            body: ["ssoId": username, "ssoToken": ssoToken], operation: "TCL region discovery")
        guard let data = urls["data"] as? [String: Any], let region = data["cloud_region"] as? String,
            region.range(of: "^[a-z]{2}-[a-z]+-[0-9]+$", options: .regularExpression) != nil,
            let cloud = trustedURL(data["cloud_url"]), let devices = trustedURL(data["device_url"]) else {
            throw CloudError.message("Your account uses a TCL region this app doesn't support yet. Try a different region.")
        }
        cloudURL = cloud
        deviceURL = devices
        awsRegion = region
        loggedInAt = Date()
        try await refresh()
    }

    /// Reobtains temporary cloud and AWS credentials; reauthenticates after 45 minutes.
    public func refresh() async throws {
        if Date().timeIntervalSince(loggedInAt) > 45 * 60 {
            guard !email.isEmpty else { throw CloudError.message("Sign in to TCL first.") }
            try await login(email: email, password: password, region: accountRegion)
            return
        }
        guard let cloudURL else { throw CloudError.message("Sign in to TCL first.") }
        let tokens = try await json(url: cloudURL.appendingPathComponent("v3/auth/refresh_tokens"),
            body: ["userId": username, "ssoToken": ssoToken, "appId": "wx6e1af3fa84fbe523"], operation: "TCL token renewal")
        guard let data = tokens["data"] as? [String: Any], let saas = text(data, "saas_token", "saasToken"),
            let cognito = text(data, "cognito_token", "cognitoToken"), let identity = jwtSubject(cognito) else {
            throw CloudError.message("TCL couldn't start your session. Try signing in again.")
        }
        saasToken = saas
        let aws = try await json(url: URL(string: "https://cognito-identity.\(awsRegion).amazonaws.com/")!,
            body: ["IdentityId": identity, "Logins": ["cognito-identity.amazonaws.com": cognito]],
            headers: ["X-Amz-Target": "AWSCognitoIdentityService.GetCredentialsForIdentity", "Content-Type": "application/x-amz-json-1.1"], operation: "AWS session renewal")
        guard let values = aws["Credentials"] as? [String: Any], let key = values["AccessKeyId"] as? String,
            let secret = values["SecretKey"] as? String, let token = values["SessionToken"] as? String,
            let expiry = number(values["Expiration"]) else { throw CloudError.message("Couldn't get access to your devices. Try signing in again.") }
        credentials = AWSCredentials(accessKey: key, secretKey: secret, sessionToken: token, expires: Date(timeIntervalSince1970: expiry))
    }

    private func ensureSession() async throws {
        guard let credentials, credentials.expires.timeIntervalSinceNow >= 120,
              Date().timeIntervalSince(loggedInAt) <= 45 * 60 else {
            try await refresh()
            return
        }
    }

    public func devices() async throws -> [AirConditioner] {
        try await ensureSession()
        guard let deviceURL else { throw CloudError.message("Sign in to TCL first.") }
        let timestamp = String(Int64(Date().timeIntervalSince1970 * 1000))
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(16)
        let headers = ["platform": "android", "appversion": "5.4.1", "thomeversion": "4.8.1", "accesstoken": saasToken,
            "accept-language": "en", "timestamp": timestamp, "nonce": String(nonce), "sign": md5(timestamp + nonce + saasToken)]
        let response = try await json(url: deviceURL.appendingPathComponent("v3/user/get_things"), body: [:], headers: headers, operation: "Device discovery")
        guard let things = response["data"] as? [[String: Any]] else { throw CloudError.message("TCL sent back a device list this app couldn't read. Try again later.") }
        var result: [AirConditioner] = []
        for thing in things {
            guard let id = text(thing, "device_id", "deviceId") else { continue }
            let model = text(thing, "device_name", "deviceName") ?? ""
            let category = text(thing, "category") ?? ""
            guard model.localizedCaseInsensitiveContains("AC") || category.localizedCaseInsensitiveContains("air") else { continue }
            do {
                let state = try await awsRequest(path: "things/\(SigV4.encode(id))/shadow", method: "GET", body: nil)
                if let device = AirConditioner.parse(thing, shadow: state) { result.append(device) }
            } catch {
                if let device = AirConditioner.parse(thing, shadow: nil, failure: error.localizedDescription) { result.append(device) }
            }
        }
        return result
    }

    public func control(device: AirConditioner, command: ACCommand) async throws {
        guard device.isSupported else { throw CloudError.message("This AC model has not been verified for control.") }
        guard device.isOnline else { throw CloudError.message("This AC is offline. Refresh its state before controlling it.") }
        let desired = try device.desiredState(for: command)
        try await ensureSession()
        let body: [String: Any] = ["state": ["desired": desired], "clientToken": "mobile_\(Int(Date().timeIntervalSince1970))"]
        _ = try await awsRequest(path: "topics/%24aws/things/\(SigV4.encode(device.id))/shadow/update?qos=1", method: "POST", body: body)
    }

    /// Reads TCL's daily kWh report without changing any device settings.
    /// Same endpoint TCL Home 7.x uses; the older /v3/ac/{id}/power/consumption/info route now returns 10003.
    public func energy(for device: AirConditioner) async throws -> EnergyReport {
        try await ensureSession()
        guard let deviceURL else { throw CloudError.message("Sign in to TCL first.") }
        let now = Date()
        var components = URLComponents(url: deviceURL.appendingPathComponent("v1/ac/statistics/electricity/summary"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "timeType", value: "2")] // 2 = daily rows grouped by month
        let timestamp = String(Int64(now.timeIntervalSince1970 * 1000))
        let nonce = UUID().uuidString.lowercased()
        var request = URLRequest(url: components.url!)
        for (key, value) in ["platform": "ios", "appVersion": "7.4.5", "thomeversion": "7.0.5", "accessToken": saasToken,
                             "ssoToken": ssoToken, "appId": "wx6e1af3fa84fbe523", "appPackageName": "com.tcl.tclhome",
                             "countryCode": countryCode, "Accept-Language": "en", "timeZone": TimeZone.current.identifier,
                             "deviceId": device.id, "productKey": device.productKey, "timestamp": timestamp,
                             "nonce": nonce, "sign": md5(timestamp + nonce + saasToken)] {
            request.setValue(value, forHTTPHeaderField: key)
        }
        return EnergyReport.parse(try await send(request, operation: "Electricity statistics", allowServiceError: true), now: now)
    }

    private func awsRequest(path: String, method: String, body: [String: Any]?) async throws -> [String: Any] {
        guard let credentials else { throw CloudError.message("Sign in to TCL first.") }
        guard let url = URL(string: "https://data-ats.iot.\(awsRegion).amazonaws.com/\(path)") else { throw CloudError.message("Invalid device address.") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        request = SigV4.sign(request, credentials: credentials, region: awsRegion)
        return try await send(request, operation: "Device communication")
    }

    private func json(url: URL, body: [String: Any], headers: [String: String] = [:], operation: String) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue("Android", forHTTPHeaderField: "User-Agent")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return try await send(request, operation: operation)
    }
    private func send(_ request: URLRequest, operation: String, allowServiceError: Bool = false) async throws -> [String: Any] {
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch {
            throw CloudError.message(FriendlyError.network(error))
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw CloudError.message(FriendlyError.http(code))
        }
        if data.isEmpty { return [:] }
        guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CloudError.message("TCL sent a response this app couldn't read. Try again later.") }
        // Never surface server bodies: authentication errors can echo session data.
        if !allowServiceError, let code = number(value["code"]), ![0, 1, 200].contains(code) {
            throw CloudError.message("TCL declined the request (code \(code.isFinite ? String(format: "%.0f", code) : "unknown")). Sign in again if this continues.")
        }
        return value
    }
}

func md5(_ value: String) -> String { Insecure.MD5.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
func jwtSubject(_ token: String) -> String? {
    let parts = token.split(separator: ".")
    guard parts.count == 3 else { return nil }
    var encoded = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
    guard let bytes = Data(base64Encoded: encoded), let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return nil }
    return object["sub"] as? String
}
public struct AccountProfile: Sendable, Equatable {
    public let nickname: String?
    public let avatarURL: URL?
}

/// A display-only image URL: HTTPS with no embedded credentials. Unlike `trustedURL`, any host is allowed,
/// because account pictures may live on a third-party CDN; such URLs are never sent TCL credentials.
func imageURL(_ value: Any?) -> URL? {
    guard let string = value as? String, let url = URL(string: string), url.scheme == "https", url.host != nil,
        url.user == nil, url.password == nil else { return nil }
    return url
}

func trustedURL(_ value: Any?) -> URL? {
    guard let string = value as? String, let url = URL(string: string), url.scheme == "https", let host = url.host,
        host.hasSuffix(".tcljd.com"), url.user == nil, url.password == nil else { return nil }
    return url
}

/// Authentication headers are scoped to the requested endpoint. A redirected URL
/// must never inherit TCL tokens, a password body, or an AWS signature.
final class CloudSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
