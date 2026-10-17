import Combine
import Foundation
import IOBluetooth

enum AudioMode: Equatable {
    case highQuality(Double)
    case callMode(Double)
    case unknown

    var label: String {
        switch self {
        case .highQuality(let hz): return "Stereo (\(Self.khz(hz)))"
        case .callMode(let hz): return "Call mode (\(Self.khz(hz)))"
        case .unknown: return "Not in use"
        }
    }

    private static func khz(_ hz: Double) -> String {
        let k = hz / 1000
        return k == k.rounded() ? "\(Int(k)) kHz" : String(format: "%.1f kHz", k)
    }
}

/// Everything the Mac can see of the headphones without a vendor protocol: the classic
/// Bluetooth link plus the CoreAudio devices macOS creates for it.
@MainActor
final class Headphones: ObservableObject {
    @Published private(set) var found = false
    @Published private(set) var name = "Dyson Zone"
    @Published private(set) var address = ""
    @Published private(set) var isConnected = false
    @Published private(set) var rssi: Int?
    @Published private(set) var isDefaultOutput = false
    @Published private(set) var audioMode: AudioMode = .unknown
    @Published private(set) var volume: Float = 0
    @Published private(set) var busy = false
    @Published var keepMacMic: Bool {
        didSet { UserDefaults.standard.set(keepMacMic, forKey: "keepMacMic"); refresh() }
    }

    private var device: IOBluetoothDevice?
    private var timer: Timer?
    private var outputID: AudioObjectID?

    init() {
        keepMacMic = UserDefaults.standard.object(forKey: "keepMacMic") as? Bool ?? true
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        if device == nil || !(device?.isPaired() ?? false) {
            let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
            device = paired.first { ($0.name ?? "").localizedCaseInsensitiveContains("dyson") }
        }
        guard let device else { found = false; isConnected = false; return }
        found = true
        name = device.name ?? "Dyson Zone"
        address = device.addressString ?? ""
        isConnected = device.isConnected()

        guard isConnected else {
            rssi = nil; isDefaultOutput = false; audioMode = .unknown; outputID = nil
            return
        }
        let raw = Int(device.rawRSSI())
        rssi = (raw == 127 || raw == 0) ? nil : raw
        refreshAudio()
    }

    private func refreshAudio() {
        let devices = AudioDevices.all().filter { $0.isBluetooth && $0.name.localizedCaseInsensitiveContains("dyson") }
        let output = devices.first { $0.hasOutput }
        let input = devices.first { $0.hasInput }
        outputID = output?.id
        isDefaultOutput = output != nil && output?.id == AudioDevices.defaultDevice(input: false)

        if let output, let rate = AudioDevices.sampleRate(output.id, input: false) {
            // macOS switches the headset to the 16/24 kHz HFP codecs when the mic is opened.
            audioMode = (rate <= 24_000 || input != nil && AudioDevices.defaultDevice(input: true) == input?.id)
                ? .callMode(rate) : .highQuality(rate)
            if let v = AudioDevices.volume(output.id) { volume = v }
        } else {
            audioMode = .unknown
        }

        if keepMacMic, let input, AudioDevices.defaultDevice(input: true) == input.id,
           let mac = AudioDevices.builtInInput() {
            AudioDevices.setDefault(mac.id, input: true)
        }
    }

    func setVolume(_ value: Float) {
        volume = value
        if let outputID { AudioDevices.setVolume(outputID, value) }
    }

    func useAsOutput() {
        guard let outputID else { return }
        AudioDevices.setDefault(outputID, input: false)
        refresh()
    }

    func toggleConnection() {
        guard let device, !busy else { return }
        busy = true
        let connect = !device.isConnected()
        Task.detached {
            if connect { device.openConnection() } else { device.closeConnection() }
            try? await Task.sleep(for: .seconds(connect ? 3 : 1))
            await MainActor.run {
                self.busy = false
                self.refresh()
                if connect { self.useAsOutput() }
            }
        }
    }
}
