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

    static func isAlive(_ id: AudioObjectID) -> Bool {
        let alive: UInt32 = get(id, address(kAudioDevicePropertyDeviceIsAlive), default: 0) ?? 0
        return alive != 0
    }

    static func streamBufferCount(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioBufferList>.size) else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        return UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self)).count
    }

    static func currentProcessObjectID() -> AudioObjectID? {
        var pid = getpid()
        var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var processObjectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            system,
            &addr,
            UInt32(MemoryLayout<pid_t>.size),
            &pid,
            &size,
            &processObjectID
        )
        guard status == noErr, processObjectID != kAudioObjectUnknown else { return nil }
        return processObjectID
    }

    static func isAnyOtherProcessOutputting(to targetDeviceID: AudioObjectID) -> Bool {
        var listAddr = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &listAddr, 0, nil, &size) == noErr, size > 0 else { return false }
        var processIDs = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &listAddr, 0, nil, &size, &processIDs) == noErr else { return false }

        let myPID = getpid()
        for procObj in processIDs {
            let pid: pid_t = get(procObj, address(kAudioProcessPropertyPID), default: 0) ?? 0
            if pid == myPID || pid == 0 { continue }

            let runningOut: UInt32 = get(procObj, address(kAudioProcessPropertyIsRunningOutput), default: 0) ?? 0
            guard runningOut != 0 else { continue }

            var devAddr = address(kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeOutput)
            var devSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(procObj, &devAddr, 0, nil, &devSize) == noErr, devSize > 0 else { continue }
            var outDevs = [AudioObjectID](repeating: 0, count: Int(devSize) / MemoryLayout<AudioObjectID>.size)
            guard AudioObjectGetPropertyData(procObj, &devAddr, 0, nil, &devSize, &outDevs) == noErr else { continue }
            if outDevs.contains(targetDeviceID) {
                return true
            }
        }
        return false
    }
}
