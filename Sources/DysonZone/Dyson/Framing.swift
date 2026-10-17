import Foundation

enum MsgType {
    static let requestProductInfo: UInt8 = 0x0A
    static let productInfo: UInt8 = 0x0B
    static let reauthA: UInt8 = 0x06
    static let reauthB: UInt8 = 0x07
    static let reauthC: UInt8 = 0x08
    static let connectionEstablished: UInt8 = 0x26
    static let attributeGet: UInt8 = 0x90
    static let attributeValue: UInt8 = 0x91
    static let attributeSet: UInt8 = 0x93
    static let attributeAck: UInt8 = 0x94
    static let attributeSubscribe: UInt8 = 0x96
    static let attributeReport: UInt8 = 0x97
    static let subscribeAck: UInt8 = 0x98
}

struct DysonMessage {
    let type: UInt8
    let payload: Data
}

enum Framing {
    static let capacity = 20

    /// First fragment header is `0x80 | (total - 1)`; later ones carry their own index.
    /// The type byte belongs to the payload stream, so it only appears in fragment 0.
    static func fragments(type: UInt8, payload: Data = Data()) -> [Data] {
        let logical = Data([type]) + payload
        let per = capacity - 1
        let total = max(1, (logical.count + per - 1) / per)
        return (0..<total).map { i in
            let chunk = logical.subdata(in: (i * per)..<min(logical.count, (i + 1) * per))
            let header: UInt8 = i == 0 ? UInt8(0x80 | (total - 1)) : UInt8(i & 0x7F)
            return Data([header]) + chunk
        }
    }

    static func attributeID(_ id: UInt16) -> Data { Data([UInt8(id & 0xFF), UInt8(id >> 8)]) }

    static func attributeGet(_ id: UInt16) -> [Data] {
        fragments(type: MsgType.attributeGet, payload: attributeID(id))
    }

    static func attributeSet(_ id: UInt16, value: Data) -> [Data] {
        let len = Data([UInt8(value.count & 0xFF), UInt8(value.count >> 8)])
        return fragments(type: MsgType.attributeSet, payload: attributeID(id) + len + value)
    }

    static func attributeSubscribe(_ id: UInt16) -> [Data] {
        fragments(type: MsgType.attributeSubscribe, payload: attributeID(id) + Data([0]))
    }
}

/// Reassembles notification fragments. A new first fragment always restarts the buffer so a
/// stray fragment cannot wedge the stream.
struct MessageAssembler {
    private var parts: [Data] = []
    private var type: UInt8 = 0
    private var expected = 0
    private var received = 0

    mutating func push(_ fragment: Data) -> DysonMessage? {
        guard let header = fragment.first else { return nil }
        let body = fragment.dropFirst()
        if header & 0x80 != 0 {
            guard let t = body.first else { return nil }
            type = t
            expected = Int(header & 0x7F) + 1
            received = 1
            parts = [Data(body.dropFirst())]
        } else {
            guard expected > 0 else { return nil }
            parts.append(Data(body))
            received = Int(header & 0x7F) + 1
        }
        guard received >= expected else { return nil }
        let message = DysonMessage(type: type, payload: parts.reduce(Data(), +))
        parts = []; expected = 0; received = 0
        return message
    }
}
