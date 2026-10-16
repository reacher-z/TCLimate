import Foundation
import CryptoKit

struct AWSCredentials {
    let accessKey: String
    let secretKey: String
    let sessionToken: String
    let expires: Date
}

enum SigV4 {
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func hmac(_ value: String, key: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(value.utf8), using: SymmetricKey(data: key)))
    }
    static func signingKey(secret: String, date: String, region: String, service: String) -> Data {
        let dateKey = hmac(date, key: Data(("AWS4" + secret).utf8))
        let regionKey = hmac(region, key: dateKey)
        let serviceKey = hmac(service, key: regionKey)
        return hmac("aws4_request", key: serviceKey)
    }
    static func encode(_ string: String) -> String {
        string.utf8.map { byte in
            if (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || [45,46,95,126].contains(byte) { return String(UnicodeScalar(byte)) }
            return String(format: "%%%02X", byte)
        }.joined()
    }
    static func canonicalRequest(method: String, url: URL, headers: [String: String], body: Data) -> (request: String, signedHeaders: String) {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        // Botocore's general SigV4 signer quotes the already URL-encoded path.
        // In particular the MQTT topic's %24aws becomes %2524aws in the canonical URI.
        let encodedPath = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        let path = encodedPath.split(separator: "/", omittingEmptySubsequences: false).map { encode(String($0)) }.joined(separator: "/")
        let queryPairs: [(String, String)] = (components.queryItems ?? []).map { (encode($0.name), encode($0.value ?? "")) }
        let sortedPairs = queryPairs.sorted { first, second in first.0 == second.0 ? first.1 < second.1 : first.0 < second.0 }
        let query = sortedPairs.map { pair in pair.0 + "=" + pair.1 }.joined(separator: "&")
        let normalized = Dictionary(uniqueKeysWithValues: headers.map { key, value in
            (key.lowercased(), value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " "))
        })
        let keys = normalized.keys.sorted()
        let canonicalHeaders = keys.map { "\($0):\(normalized[$0]!)\n" }.joined()
        let signed = keys.joined(separator: ";")
        return ([method, path, query, canonicalHeaders, signed, hash(body)].joined(separator: "\n"), signed)
    }
    static func amzDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }
    /// Presigned `wss://` URL for AWS IoT's MQTT-over-WebSocket endpoint. The session token goes after the signature,
    /// as IoT requires, so it is not part of the signed query.
    static func presignedMQTTURL(host: String, credentials: AWSCredentials, region: String, date: Date = Date()) -> URL {
        let timestamp = amzDate(date)
        let day = String(timestamp.prefix(8))
        let scope = "\(day)/\(region)/iotdevicegateway/aws4_request"
        let query = [("X-Amz-Algorithm", "AWS4-HMAC-SHA256"), ("X-Amz-Credential", "\(credentials.accessKey)/\(scope)"),
                     ("X-Amz-Date", timestamp), ("X-Amz-SignedHeaders", "host")]
            .map { "\($0.0)=\(encode($0.1))" }.joined(separator: "&")
        let unsigned = URL(string: "https://\(host)/mqtt?\(query)")!
        let canonical = canonicalRequest(method: "GET", url: unsigned, headers: ["host": host], body: Data())
        let stringToSign = "AWS4-HMAC-SHA256\n\(timestamp)\n\(scope)\n\(hash(Data(canonical.request.utf8)))"
        let signature = hmac(stringToSign, key: signingKey(secret: credentials.secretKey, date: day, region: region, service: "iotdevicegateway"))
            .map { String(format: "%02x", $0) }.joined()
        var url = "wss://\(host)/mqtt?\(query)&X-Amz-Signature=\(signature)"
        if !credentials.sessionToken.isEmpty { url += "&X-Amz-Security-Token=\(encode(credentials.sessionToken))" }
        return URL(string: url)!
    }

    static func sign(_ request: URLRequest, credentials: AWSCredentials, region: String, service: String = "iotdata", date: Date = Date()) -> URLRequest {
        var result = request
        let timestamp = amzDate(date)
        let day = String(timestamp.prefix(8))
        var headers = result.allHTTPHeaderFields ?? [:]
        headers["host"] = result.url!.host!
        headers["x-amz-date"] = timestamp
        if !credentials.sessionToken.isEmpty { headers["x-amz-security-token"] = credentials.sessionToken }
        let canonical = canonicalRequest(method: result.httpMethod ?? "GET", url: result.url!, headers: headers, body: result.httpBody ?? Data())
        let scope = "\(day)/\(region)/\(service)/aws4_request"
        let stringToSign = "AWS4-HMAC-SHA256\n\(timestamp)\n\(scope)\n\(hash(Data(canonical.request.utf8)))"
        let signature = hmac(stringToSign, key: signingKey(secret: credentials.secretKey, date: day, region: region, service: service)).map { String(format: "%02x", $0) }.joined()
        headers["Authorization"] = "AWS4-HMAC-SHA256 Credential=\(credentials.accessKey)/\(scope), SignedHeaders=\(canonical.signedHeaders), Signature=\(signature)"
        result.allHTTPHeaderFields = headers
        return result
    }
}
