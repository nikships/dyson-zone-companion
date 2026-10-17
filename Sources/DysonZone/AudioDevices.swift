import AudioToolbox
import CoreAudio
import Foundation

struct AudioDevice: Equatable {
    let id: AudioObjectID
    let name: String
    let uid: String
    let isBluetooth: Bool
    let hasInput: Bool
    let hasOutput: Bool
}

enum AudioDevices {
    private static let system = AudioObjectID(kAudioObjectSystemObject)

    private static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func get<T>(_ id: AudioObjectID, _ addr: AudioObjectPropertyAddress, default value: T) -> T? {
        var addr = addr
        var out = value
        var size = UInt32(MemoryLayout<T>.size)
        let status = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &out)
        return status == noErr ? out : nil
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr, let value else { return "" }
        return value.takeRetainedValue() as String
    }

    private static func hasStreams(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> Bool {
        var addr = address(kAudioDevicePropertyStreams, scope: scope)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr && size > 0
    }

    static func all() -> [AudioDevice] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.map { id in
            let transport: UInt32 = get(id, address(kAudioDevicePropertyTransportType), default: 0) ?? 0
            return AudioDevice(
                id: id,
                name: string(id, kAudioObjectPropertyName),
                uid: string(id, kAudioDevicePropertyDeviceUID),
                isBluetooth: transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE,
                hasInput: hasStreams(id, scope: kAudioObjectPropertyScopeInput),
                hasOutput: hasStreams(id, scope: kAudioObjectPropertyScopeOutput)
            )
        }
    }

    static func defaultDevice(input: Bool) -> AudioObjectID? {
        let selector = input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice
        let id: AudioObjectID? = get(system, address(selector), default: 0)
        return (id ?? 0) == 0 ? nil : id
    }

    @discardableResult
    static func setDefault(_ id: AudioObjectID, input: Bool) -> Bool {
        let selector = input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice
        var addr = address(selector)
        var id = id
        return AudioObjectSetPropertyData(system, &addr, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &id) == noErr
    }

    static func sampleRate(_ id: AudioObjectID, input: Bool) -> Double? {
        let scope = input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput
        return get(id, address(kAudioDevicePropertyNominalSampleRate, scope: scope), default: 0.0)
    }

    static func volume(_ id: AudioObjectID) -> Float? {
        let addr = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioObjectPropertyScopeOutput)
        return get(id, addr, default: Float32(0))
    }

    @discardableResult
    static func setVolume(_ id: AudioObjectID, _ value: Float) -> Bool {
        var addr = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioObjectPropertyScopeOutput)
        var value = min(max(value, 0), 1)
        return AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &value) == noErr
    }

    static func builtInInput() -> AudioDevice? {
        all().first { $0.hasInput && !$0.isBluetooth && $0.uid.contains("BuiltIn") }
    }
}
