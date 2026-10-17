import CoreBluetooth
import CryptoKit
import Foundation

enum ANCMode: Int, CaseIterable, Identifiable {
    case isolation = 0, conversation = 1, transparency = 2, off = 3

    var id: Int { rawValue }
    var label: String {
        switch self {
        case .isolation: return "Noise cancelling"
        case .conversation: return "Conversation"
        case .transparency: return "Transparency"
        case .off: return "Off"
        }
    }
}

enum EQMode: Int, CaseIterable, Identifiable {
    case enhanced = 0, bassBoost = 1, neutral = 2

    var id: Int { rawValue }
    var label: String {
        switch self {
        case .enhanced: return "Enhanced"
        case .bassBoost: return "Bass boost"
        case .neutral: return "Neutral"
        }
    }
}

enum BatteryState: Int {
    case full = 0, normal, low, insufficient, critical, shutdown

    var label: String {
        switch self {
        case .full: return "Full"
        case .normal: return "Good"
        case .low: return "Low"
        case .insufficient: return "Very low"
        case .critical: return "Critical"
        case .shutdown: return "Shutting down"
        }
    }
}

enum LinkState: Equatable {
    case needsSignIn
    case bluetoothUnavailable(String)
    case searching
    case busyElsewhere
    case connecting
    case authenticating
    case ready
    case failed(String)

    var summary: String {
        switch self {
        case .needsSignIn: return "Sign in to control"
        case .bluetoothUnavailable(let why): return why
        case .searching: return "Looking for headphones…"
        case .busyElsewhere: return "In use by another device"
        case .connecting: return "Connecting…"
        case .authenticating: return "Authenticating…"
        case .ready: return "Controls ready"
        case .failed(let why): return why
        }
    }
}

/// The Dyson control channel over BLE: handshake with the account's long-term key, then
/// attributes for ANC mode, battery and so on. The Zone allows one controller at a time, so this
/// only connects when the phone app is not holding the link.
@MainActor
final class ZoneLink: NSObject, ObservableObject {
    enum Attr {
        static let filterPresence: UInt16 = 0x4006
        static let ancMode: UInt16 = 0x400A
        static let eqMode: UInt16 = 0x400B
        static let volumeLimiter: UInt16 = 0x4010
        static let audioStatus: UInt16 = 0x4011
        static let conversationMode: UInt16 = 0x4012
        static let battery: UInt16 = 0x401A
        static let calibration: UInt16 = 0x401E
    }

    private static let authService = CBUUID(string: "2DD10010-1C37-452D-8979-D1B4A787D0A4")
    private static let authChar = CBUUID(string: "2DD10011-1C37-452D-8979-D1B4A787D0A4")
    private static let attrChar = CBUUID(string: "2DD10021-1C37-452D-8979-D1B4A787D0A4")

    @Published private(set) var state: LinkState = .needsSignIn
    @Published private(set) var ancMode: ANCMode?
    @Published private(set) var eqMode: EQMode?
    @Published private(set) var battery: BatteryState?
    @Published private(set) var attributes: [UInt16: Data] = [:]
    @Published private(set) var batteryPercent: Int?
    @Published private(set) var chargingState: Int?
    @Published private(set) var chargerPresent: Bool?
    @Published private(set) var fanSpeed: Int?
    @Published private(set) var fanAuto: Bool?

    private enum Char {
        static let fanSpeed = CBUUID(string: "2DD12001-1C37-452D-8979-D1B4A787D0A4")
        static let fanAuto = CBUUID(string: "2DD12002-1C37-452D-8979-D1B4A787D0A4")
        static let chargerPresent = CBUUID(string: "2DD1200B-1C37-452D-8979-D1B4A787D0A4")
        static let chargingState = CBUUID(string: "2DD12016-1C37-452D-8979-D1B4A787D0A4")
        static let batteryPercent = CBUUID(string: "2DD1201E-1C37-452D-8979-D1B4A787D0A4")
    }

    private var credentials: Credentials?
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var chars: [CBUUID: CBCharacteristic] = [:]
    private var pendingServices = 0
    private var rejected = Set<UUID>()
    private var authAssembler = MessageAssembler()
    private var attrAssembler = MessageAssembler()
    private var waiters: [UInt8: CheckedContinuation<DysonMessage, Error>] = [:]
    private var key: SymmetricKey?
    private var sawNonConnectable = false

    func start(with credentials: Credentials?) {
        self.credentials = credentials
        guard let credentials, let ltk = Data(hexString: credentials.ltk) else {
            state = .needsSignIn
            return
        }
        key = DysonCrypto.deriveAuthKey(ltk: ltk)
        if central == nil {
            state = .searching
            central = CBCentralManager(delegate: self, queue: nil)
        } else {
            beginScan()
        }
    }

    func stop() {
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        central?.stopScan()
        reset()
        state = credentials == nil ? .needsSignIn : .searching
    }

    func setANC(_ mode: ANCMode) {
        guard state == .ready else { return }
        ancMode = mode
        Task { await write(Framing.attributeSet(Attr.ancMode, value: Data([UInt8(mode.rawValue)])), to: Self.attrChar) }
    }

    func setEQ(_ mode: EQMode) {
        guard state == .ready else { return }
        eqMode = mode
        Task { await write(Framing.attributeSet(Attr.eqMode, value: Data([UInt8(mode.rawValue)])), to: Self.attrChar) }
    }

    /// 0 off, 1 rest, 2 light, 3 moderate.
    func setFanSpeed(_ speed: Int) {
        guard state == .ready, (0...3).contains(speed) else { return }
        fanSpeed = speed
        fanAuto = false
        Task {
            await write([Data([0])], to: Char.fanAuto)
            await write([Data([UInt8(speed)])], to: Char.fanSpeed)
        }
    }

    func setFanAuto(_ on: Bool) {
        guard state == .ready else { return }
        fanAuto = on
        Task { await write([Data([on ? 1 : 0])], to: Char.fanAuto) }
    }

    // MARK: - Scanning

    private func beginScan() {
        guard let central, central.state == .poweredOn, key != nil, peripheral == nil else { return }
        sawNonConnectable = false
        state = .searching
        central.scanForPeripherals(withServices: [Self.authService], options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    private func reset() {
        peripheral = nil
        chars = [:]
        pendingServices = 0
        authAssembler = MessageAssembler()
        attrAssembler = MessageAssembler()
        for (_, w) in waiters { w.resume(throwing: LinkError.disconnected) }
        waiters = [:]
        ancMode = nil
        eqMode = nil
        battery = nil
        attributes = [:]
        batteryPercent = nil
        chargingState = nil
        chargerPresent = nil
        fanSpeed = nil
        fanAuto = nil
    }

    // MARK: - Handshake

    private func authenticate() async {
        guard let credentials, let key, peripheral != nil else { return }
        state = .authenticating
        do {
            try await send(MsgType.requestProductInfo)
            if let info = try? await waitFor(MsgType.productInfo, timeout: 4) {
                Log.write("product info: \(info.payload.hex)")
            }
            let nonce = DysonCrypto.randomBytes(16)
            guard let a = DysonCrypto.reauthPayloadA(accountId: credentials.accountId, key: key, nonce: nonce) else {
                throw LinkError.badCredentials
            }
            try await send(MsgType.reauthA, a)
            let b = try await waitFor(MsgType.reauthB, timeout: 8)
            guard let challenge = DysonCrypto.challenge(fromPayloadB: b.payload, key: key) else {
                throw LinkError.wrongKey
            }
            try await send(MsgType.reauthC, DysonCrypto.reauthPayloadC(key: key, challenge: challenge))
            _ = try await waitFor(MsgType.connectionEstablished, timeout: 8)
            Log.write("authenticated")
            state = .ready
            await sync()
        } catch {
            Log.write("handshake failed: \(error)")
            if let p = peripheral {
                rejected.insert(p.identifier)
                central?.cancelPeripheralConnection(p)
            }
            state = .failed("Handshake failed: \(error.localizedDescription)")
        }
    }

    /// Subscribe to the attributes we show and ask for their current values.
    private func sync() async {
        let known: [UInt16] = [Attr.ancMode, Attr.battery, Attr.eqMode, Attr.audioStatus,
                               Attr.conversationMode, Attr.volumeLimiter, Attr.filterPresence]
        for id in known {
            await write(Framing.attributeSubscribe(id), to: Self.attrChar)
            try? await Task.sleep(for: .milliseconds(120))
        }
        for id in known {
            await write(Framing.attributeGet(id), to: Self.attrChar)
            try? await Task.sleep(for: .milliseconds(120))
        }
        for (uuid, char) in chars where char.properties.contains(.read) && uuid != Self.authChar {
            peripheral?.readValue(for: char)
        }
        for uuid in [Char.fanSpeed, Char.fanAuto, Char.chargerPresent, Char.chargingState, Char.batteryPercent] {
            if let char = chars[uuid], char.properties.contains(.notify) { peripheral?.setNotifyValue(true, for: char) }
        }
    }

    private func recordChar(_ uuid: CBUUID, _ value: Data) {
        guard let byte = value.first else { return }
        switch uuid {
        case Char.batteryPercent: batteryPercent = min(100, Int(byte))
        case Char.chargingState: chargingState = Int(byte)
        case Char.chargerPresent: chargerPresent = byte != 0
        case Char.fanSpeed: fanSpeed = Int(byte)
        case Char.fanAuto: fanAuto = byte != 0
        default: break
        }
    }

    // MARK: - IO

    private func send(_ type: UInt8, _ payload: Data = Data()) async throws {
        await write(Framing.fragments(type: type, payload: payload), to: Self.authChar)
    }

    private func write(_ fragments: [Data], to uuid: CBUUID) async {
        guard let peripheral, let char = chars[uuid] else { return }
        let type: CBCharacteristicWriteType = char.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        for fragment in fragments {
            peripheral.writeValue(fragment, for: char, type: type)
            try? await Task.sleep(for: .milliseconds(40))
        }
    }

    private func waitFor(_ type: UInt8, timeout: Double) async throws -> DysonMessage {
        try await withCheckedThrowingContinuation { continuation in
            waiters[type] = continuation
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                await MainActor.run {
                    if let w = self?.waiters.removeValue(forKey: type) { w.resume(throwing: LinkError.timeout(type)) }
                }
            }
        }
    }

    private func handleAuth(_ data: Data) {
        guard let message = authAssembler.push(data) else { return }
        if let waiter = waiters.removeValue(forKey: message.type) {
            waiter.resume(returning: message)
        } else {
            Log.write("auth message 0x\(String(message.type, radix: 16)): \(message.payload.hex)")
        }
    }

    private func handleAttr(_ data: Data) {
        guard let message = attrAssembler.push(data) else { return }
        let p = message.payload
        switch message.type {
        case MsgType.attributeValue where p.count >= 5:
            let id = UInt16(p[0]) | UInt16(p[1]) << 8
            let status = p[2]
            let len = Int(p[3]) | Int(p[4]) << 8
            guard status == 0, p.count >= 5 + len else { return }
            record(id, Data(p.subdata(in: 5..<(5 + len))))
        case MsgType.attributeReport where p.count >= 4:
            let id = UInt16(p[0]) | UInt16(p[1]) << 8
            let len = Int(p[2]) | Int(p[3]) << 8
            guard p.count >= 4 + len else { return }
            record(id, Data(p.subdata(in: 4..<(4 + len))))
        case MsgType.attributeAck, MsgType.subscribeAck:
            break
        default:
            Log.write("attr message 0x\(String(message.type, radix: 16)): \(p.hex)")
        }
    }

    private func record(_ id: UInt16, _ value: Data) {
        attributes[id] = value
        Log.write(String(format: "attr 0x%04x = %@", id, value.hex))
        switch id {
        case Attr.ancMode:
            if let b = value.first { ancMode = ANCMode(rawValue: Int(b)) }
        case Attr.eqMode:
            if let b = value.first { eqMode = EQMode(rawValue: Int(b)) }
        case Attr.battery:
            if let b = value.first { battery = BatteryState(rawValue: Int(b)) }
        default: break
        }
    }

}

enum LinkError: LocalizedError {
    case disconnected, badCredentials, wrongKey, timeout(UInt8)

    var errorDescription: String? {
        switch self {
        case .disconnected: return "Disconnected"
        case .badCredentials: return "Saved account details are invalid"
        case .wrongKey: return "The saved key was rejected"
        case .timeout: return "No answer from the device"
        }
    }
}

// MARK: - CoreBluetooth

extension ZoneLink: CBCentralManagerDelegate, CBPeripheralDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            switch central.state {
            case .poweredOn: beginScan()
            case .unauthorized: state = .bluetoothUnavailable("Bluetooth permission denied")
            case .poweredOff: state = .bluetoothUnavailable("Bluetooth is off")
            default: state = .bluetoothUnavailable("Bluetooth unavailable")
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager, didDiscover p: CBPeripheral,
        advertisementData ad: [String: Any], rssi RSSI: NSNumber
    ) {
        MainActor.assumeIsolated {
            guard peripheral == nil, !rejected.contains(p.identifier) else { return }
            if (ad[CBAdvertisementDataIsConnectable] as? Bool) == false {
                if !sawNonConnectable { Log.write("Dyson device advertising but not connectable (held by another controller)") }
                sawNonConnectable = true
                state = .busyElsewhere
                return
            }
            central.stopScan()
            peripheral = p
            p.delegate = self
            state = .connecting
            Log.write("connecting to \(p.identifier)")
            central.connect(p)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        MainActor.assumeIsolated { p.discoverServices(nil) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            Log.write("connect failed: \(String(describing: error))")
            reset()
            retrySoon()
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            Log.write("disconnected: \(String(describing: error))")
            let failed: Bool = { if case .failed = state { return true } else { return false } }()
            reset()
            if !failed { state = .searching }
            retrySoon()
        }
    }

    private func retrySoon() {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            await MainActor.run { self?.beginScan() }
        }
    }

    nonisolated func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            let services = p.services ?? []
            pendingServices = services.count
            for s in services { p.discoverCharacteristics(nil, for: s) }
        }
    }

    nonisolated func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        MainActor.assumeIsolated {
            for c in s.characteristics ?? [] { chars[c.uuid] = c }
            pendingServices -= 1
            guard pendingServices == 0 else { return }
            guard let auth = chars[Self.authChar], let attr = chars[Self.attrChar] else {
                Log.write("not a Dyson control device; skipping")
                rejected.insert(p.identifier)
                central?.cancelPeripheralConnection(p)
                return
            }
            p.setNotifyValue(true, for: auth)
            p.setNotifyValue(true, for: attr)
        }
    }

    nonisolated func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            if let error { Log.write("notify failed for \(c.uuid): \(error)"); return }
            if c.uuid == Self.attrChar { Task { await authenticate() } }
        }
    }

    nonisolated func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            guard let value = c.value else { return }
            if c.uuid == Self.authChar { handleAuth(value) }
            else if c.uuid == Self.attrChar { handleAttr(value) }
            else {
                Log.write("char \(c.uuid.uuidString.prefix(8)) = \(value.hex)")
                recordChar(c.uuid, value)
            }
        }
    }
}
