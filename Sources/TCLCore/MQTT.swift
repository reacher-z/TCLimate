import Foundation

/// The few MQTT 3.1.1 packets needed to listen to device shadows over AWS IoT's WebSocket endpoint.
enum MQTTPacket: Equatable {
    case connack(returnCode: UInt8)
    case suback(returnCodes: [UInt8])
    case publish(topic: String, payload: Data)
    case pingresp
    case other(type: UInt8)

    static func connect(clientID: String, keepAlive: UInt16) -> Data {
        var body = string("MQTT") + [4, 0x02] + [UInt8(keepAlive >> 8), UInt8(keepAlive & 0xFF)]
        body += string(clientID)
        return frame(0x10, body)
    }

    static func subscribe(id: UInt16, topics: [String]) -> Data {
        var body: [UInt8] = [UInt8(id >> 8), UInt8(id & 0xFF)]
        for topic in topics { body += string(topic) + [0] }   // QoS 0
        return frame(0x82, body)
    }

    static let pingreq = Data([0xC0, 0x00])
    static let disconnect = Data([0xE0, 0x00])

    /// Removes and returns every complete packet at the front of `buffer`; leaves a trailing partial packet in place.
    static func decode(_ buffer: inout Data) -> [MQTTPacket] {
        var packets: [MQTTPacket] = []
        while true {
            let bytes = [UInt8](buffer)
            guard bytes.count >= 2 else { break }
            var length = 0, multiplier = 1, index = 1
            var complete = false
            while index < bytes.count, index <= 4 {
                let byte = bytes[index]
                length += Int(byte & 0x7F) * multiplier
                multiplier *= 128
                index += 1
                if byte & 0x80 == 0 { complete = true; break }
            }
            guard complete, bytes.count >= index + length else { break }
            let body = Array(bytes[index..<index + length])
            buffer = Data(bytes[(index + length)...])
            packets.append(parse(type: bytes[0], body: body))
        }
        return packets
    }

    private static func parse(type first: UInt8, body: [UInt8]) -> MQTTPacket {
        switch first >> 4 {
        case 2: return .connack(returnCode: body.count > 1 ? body[1] : 0xFF)
        case 9: return .suback(returnCodes: Array(body.dropFirst(2)))
        case 13: return .pingresp
        case 3:
            guard body.count >= 2 else { return .other(type: 3) }
            let topicLength = Int(body[0]) << 8 | Int(body[1])
            guard body.count >= 2 + topicLength else { return .other(type: 3) }
            let topic = String(decoding: body[2..<2 + topicLength], as: UTF8.self)
            let hasID = (first >> 1) & 0x03 != 0
            let start = 2 + topicLength + (hasID ? 2 : 0)
            guard body.count >= start else { return .other(type: 3) }
            return .publish(topic: topic, payload: Data(body[start...]))
        default: return .other(type: first >> 4)
        }
    }

    private static func string(_ value: String) -> [UInt8] {
        let bytes = Array(value.utf8)
        return [UInt8(bytes.count >> 8), UInt8(bytes.count & 0xFF)] + bytes
    }

    private static func frame(_ first: UInt8, _ body: [UInt8]) -> Data {
        var header: [UInt8] = [first]
        var remaining = body.count
        repeat {
            var byte = UInt8(remaining % 128)
            remaining /= 128
            if remaining > 0 { byte |= 0x80 }
            header.append(byte)
        } while remaining > 0
        return Data(header + body)
    }
}

/// One MQTT-over-WebSocket connection. Read-only: it connects, subscribes, and yields incoming publishes.
final class MQTTConnection: @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    private var buffer = Data()
    private var pending: [MQTTPacket] = []
    private let lock = NSLock()
    private var receivedAt = Date()
    /// When the broker last sent anything, ping replies included.
    var lastReceived: Date { lock.withLock { receivedAt } }

    init(url: URL, session: URLSession) {
        var request = URLRequest(url: url)
        request.setValue("mqtt", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        task = session.webSocketTask(with: request)
        task.resume()
    }

    /// Connects and subscribes. Returns how many topics the broker accepted; throws if the connection is refused.
    func open(clientID: String, topics: [String]) async throws -> Int {
        try await write(MQTTPacket.connect(clientID: clientID, keepAlive: 60))
        guard case .connack(let code) = try await next(), code == 0 else { throw MQTTError.refused }
        var accepted = 0
        // AWS IoT allows 8 topic filters per SUBSCRIBE.
        for (index, start) in stride(from: 0, to: topics.count, by: 8).enumerated() {
            try await write(MQTTPacket.subscribe(id: UInt16(index + 1), topics: Array(topics[start..<min(start + 8, topics.count)])))
            while true {
                guard case .suback(let codes) = try await next() else { continue }
                accepted += codes.filter { $0 < 0x80 }.count
                break
            }
        }
        return accepted
    }

    func next() async throws -> MQTTPacket {
        while pending.isEmpty {
            switch try await task.receive() {
            case .data(let data): buffer.append(data)
            case .string(let text): buffer.append(Data(text.utf8))
            @unknown default: break
            }
            lock.withLock { receivedAt = Date() }
            pending = MQTTPacket.decode(&buffer)
        }
        return pending.removeFirst()
    }

    func ping() async throws { try await write(MQTTPacket.pingreq) }

    func close() {
        task.send(.data(MQTTPacket.disconnect)) { _ in }
        task.cancel(with: .normalClosure, reason: nil)
    }

    private func write(_ data: Data) async throws { try await task.send(.data(data)) }
}

enum MQTTError: Error { case refused }
