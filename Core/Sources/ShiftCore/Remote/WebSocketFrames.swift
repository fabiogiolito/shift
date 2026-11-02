import CryptoKit
import Foundation

/// RFC 6455, the little of it a server needs. Clients mask what they send; servers don't.
enum WebSocketFrames {
    struct Frame: Equatable {
        var opcode: UInt8
        var isFinal: Bool
        var payload: Data
    }

    static let text: UInt8 = 1, close: UInt8 = 8, ping: UInt8 = 9, pong: UInt8 = 10

    static func accept(key: String) -> String {
        Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
    }

    static func encode(opcode: UInt8, payload: Data = Data()) -> Data {
        var frame = Data([0x80 | opcode])
        switch payload.count {
        case ..<126: frame.append(UInt8(payload.count))
        case ..<65536:
            frame.append(126)
            frame.append(contentsOf: withUnsafeBytes(of: UInt16(payload.count).bigEndian, Array.init))
        default:
            frame.append(127)
            frame.append(contentsOf: withUnsafeBytes(of: UInt64(payload.count).bigEndian, Array.init))
        }
        return frame + payload
    }

    /// The first whole frame in `buffer`, removed from it. nil until one has arrived.
    /// Throws for a frame that is too large or unmasked, which ends the connection.
    static func next(from buffer: inout Data, limit: Int) throws -> Frame? {
        let bytes = [UInt8](buffer.prefix(14))
        guard bytes.count >= 2 else { return nil }
        guard bytes[1] & 0x80 != 0 else { throw Refused() }
        var length = Int(bytes[1] & 0x7F), start = 2
        if length == 126 {
            guard bytes.count >= 4 else { return nil }
            length = Int(bytes[2]) << 8 | Int(bytes[3])
            start = 4
        } else if length == 127 {
            guard bytes.count >= 10 else { return nil }
            guard bytes[2...5].allSatisfy({ $0 == 0 }) else { throw Refused() }
            length = bytes[6...9].reduce(0) { $0 << 8 | Int($1) }
            start = 10
        }
        guard length <= limit else { throw Refused() }
        guard bytes.count >= start + 4, buffer.count >= start + 4 + length else { return nil }
        let mask = bytes[start..<(start + 4)].map { $0 }
        let body = buffer.dropFirst(start + 4).prefix(length)
        let payload = Data(body.enumerated().map { $1 ^ mask[$0 % 4] })
        buffer = Data(buffer.dropFirst(start + 4 + length))
        return Frame(opcode: bytes[0] & 0x0F, isFinal: bytes[0] & 0x80 != 0, payload: payload)
    }

    struct Refused: Error {}
}
