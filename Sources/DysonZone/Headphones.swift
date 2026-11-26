import AppKit
import AudioToolbox
import Combine
import CoreAudio
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
    /// True when Classic Bluetooth audio (A2DP/HFP output stream) is connected to this Mac.
    /// Note: `IOBluetoothDevice.isConnected()` also returns true when only the BLE control link is active,
    /// so we check for the actual CoreAudio output device rather than `device.isConnected()` alone.
    @Published private(set) var isConnected = false
    @Published private(set) var rssi: Int?
    @Published private(set) var isDefaultOutput = false
    @Published private(set) var audioMode: AudioMode = .unknown
    @Published private(set) var volume: Float = 0
    @Published private(set) var busy = false
    @Published private(set) var outputID: AudioObjectID?
    @Published private(set) var outputUID: String?
    @Published var keepMacMic: Bool {
        didSet { UserDefaults.standard.set(keepMacMic, forKey: "keepMacMic"); refresh() }
    }

    var onAudioTargetChange: ((String?, AudioObjectID?, Bool) -> Void)?

    private var device: IOBluetoothDevice?
    private var timer: Timer?
    private var devicesListener: AudioObjectPropertyListenerBlock?
    private var defaultOutListener: AudioObjectPropertyListenerBlock?

    init() {
        keepMacMic = UserDefaults.standard.object(forKey: "keepMacMic") as? Bool ?? true
        installAudioListeners()
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
        guard let device else {
            found = false
            isConnected = false
            clearAudioState()
            return
        }
        found = true
        let rawName = device.name ?? "Dyson Zone"
        name = rawName.replacingOccurrences(of: " BLE", with: "")
        address = device.addressString ?? ""

        let audioDevices = AudioDevices.all().filter {
            $0.isBluetooth && ($0.name.localizedCaseInsensitiveContains("dyson") || (!address.isEmpty && $0.uid.localizedCaseInsensitiveContains(address)))
        }
        guard let output = audioDevices.first(where: { $0.hasOutput }) else {
            isConnected = false
            clearAudioState()
            return
        }

        isConnected = true
        let raw = Int(device.rawRSSI())
        rssi = (raw == 127 || raw == 0) ? nil : raw
        refreshAudio(output: output, input: audioDevices.first(where: { $0.hasInput }))
    }

    private func clearAudioState() {
        rssi = nil
        isDefaultOutput = false
        audioMode = .unknown
        outputID = nil
        outputUID = nil
        onAudioTargetChange?(nil, nil, false)
    }

    private func refreshAudio(output: AudioDevice, input: AudioDevice?) {
        outputID = output.id
        outputUID = output.uid
        isDefaultOutput = output.id == AudioDevices.defaultDevice(input: false)

        if let rate = AudioDevices.sampleRate(output.id, input: false) {
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

        let inCall: Bool = { if case .callMode = audioMode { return true } else { return false } }()
        onAudioTargetChange?(outputUID, outputID, inCall)
    }

    private func installAudioListeners() {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var devsAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let devsBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.refresh() }
        }
        devicesListener = devsBlock
        AudioObjectAddPropertyListenerBlock(system, &devsAddr, DispatchQueue.main, devsBlock)

        var defAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let defBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.refresh() }
        }
        defaultOutListener = defBlock
        AudioObjectAddPropertyListenerBlock(system, &defAddr, DispatchQueue.main, defBlock)
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
        let connect = !isConnected
        let addr = address
        Task.detached {
            if connect {
                let status = device.openConnection()
                Log.write("classic bt openConnection status=\(status)")
                for _ in 0..<20 {
                    try? await Task.sleep(for: .milliseconds(250))
                    let hasOut = AudioDevices.all().contains {
                        $0.isBluetooth && $0.hasOutput &&
                        ($0.name.localizedCaseInsensitiveContains("dyson") || (!addr.isEmpty && $0.uid.localizedCaseInsensitiveContains(addr)))
                    }
                    if hasOut { break }
                }
            } else {
                let status = device.closeConnection()
                Log.write("classic bt closeConnection status=\(status)")
                try? await Task.sleep(for: .seconds(1))
            }
            await MainActor.run {
                self.busy = false
                self.refresh()
                if connect {
                    if self.isConnected {
                        self.useAsOutput()
                    } else if let url = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }
}
