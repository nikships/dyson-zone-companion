import AppKit
import AudioToolbox
import CoreAudio
import Foundation
import os.lock

enum BassEngineStatus: Equatable {
    case off
    case waitingForHeadphones
    case pausedForCall
    case starting
    case active(Double)
    case permissionNeeded
    case failed(String)

    var summary: String {
        switch self {
        case .off:
            return "Off"
        case .waitingForHeadphones:
            return "Ready — activates when headphones connect"
        case .pausedForCall:
            return "Paused during voice call"
        case .starting:
            return "Starting audio processor…"
        case .active(let hz):
            let k = hz / 1000
            let rateText = k == k.rounded() ? "\(Int(k)) kHz" : String(format: "%.1f kHz", k)
            return "Active (\(rateText)) · stacks with headphone EQ"
        case .permissionNeeded:
            return "Allow System Audio Recording in System Settings"
        case .failed(let reason):
            return reason
        }
    }
}

/// Lock-free / try-lock bridge between `@MainActor` UI state and the real-time CoreAudio IO thread.
final class RealtimeAudioContext: @unchecked Sendable {
    private var lock = os_unfair_lock_s()
    private var sharedSettings: BassSettings
    private var ioCallbacks: UInt64 = 0
    private var nonZeroCallbacks: UInt64 = 0

    // Accessed exclusively on the CoreAudio real-time IO thread
    private var cachedSettings: BassSettings
    private let processor: BassBoostProcessor
    private let tapStartBufferIndex: Int

    init(sampleRate: Double, initialSettings: BassSettings, tapStartBufferIndex: Int) {
        self.sharedSettings = initialSettings
        self.cachedSettings = initialSettings
        self.processor = BassBoostProcessor(sampleRate: sampleRate, initialSettings: initialSettings)
        self.tapStartBufferIndex = max(0, tapStartBufferIndex)
    }

    func updateSettings(_ newSettings: BassSettings) {
        os_unfair_lock_lock(&lock)
        sharedSettings = newSettings
        os_unfair_lock_unlock(&lock)
    }

    func snapshotStats() -> (callbacks: UInt64, nonZeroCallbacks: UInt64) {
        os_unfair_lock_lock(&lock)
        let stats = (ioCallbacks, nonZeroCallbacks)
        os_unfair_lock_unlock(&lock)
        return stats
    }

    func render(input: UnsafePointer<AudioBufferList>?, output: UnsafeMutablePointer<AudioBufferList>?) {
        guard let output else { return }
        let outList = UnsafeMutableAudioBufferListPointer(output)
        guard !outList.isEmpty else { return }

        if os_unfair_lock_trylock(&lock) {
            cachedSettings = sharedSettings
            os_unfair_lock_unlock(&lock)
        }

        let firstOut = outList[0]
        let outChannels = max(1, Int(firstOut.mNumberChannels))
        let frameCount = Int(firstOut.mDataByteSize) / (MemoryLayout<Float32>.size * outChannels)
        guard frameCount > 0 else { return }

        let inList: UnsafeMutableAudioBufferListPointer? = input.map {
            UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: $0))
        }

        let tapIdx: Int = {
            guard let inList, tapStartBufferIndex < inList.count else { return -1 }
            return tapStartBufferIndex
        }()

        // Pre-resolve buffer pointers outside the sample loop
        var inPtr0: UnsafePointer<Float32>?
        var inPtr1: UnsafePointer<Float32>?
        var inStride = 0
        var inPlanarStereo = false
        var inInterleavedStereo = false

        if let inList, tapIdx >= 0 {
            let b0 = inList[tapIdx]
            let ch0 = Int(b0.mNumberChannels)
            let availFrames0 = ch0 > 0 ? Int(b0.mDataByteSize) / (MemoryLayout<Float32>.size * ch0) : 0
            if availFrames0 >= frameCount, let p0 = b0.mData?.assumingMemoryBound(to: Float32.self) {
                inPtr0 = UnsafePointer(p0)
                if ch0 >= 2 {
                    inStride = ch0
                    inInterleavedStereo = true
                } else if ch0 == 1, tapIdx + 1 < inList.count {
                    let b1 = inList[tapIdx + 1]
                    let availFrames1 = Int(b1.mDataByteSize) / MemoryLayout<Float32>.size
                    if b1.mNumberChannels == 1, availFrames1 >= frameCount,
                       let p1 = b1.mData?.assumingMemoryBound(to: Float32.self) {
                        inPtr1 = UnsafePointer(p1)
                        inPlanarStereo = true
                    }
                }
            }
        }

        let outPtr0 = firstOut.mData?.assumingMemoryBound(to: Float32.self)
        let outPlanarStereo = outChannels == 1 && outList.count >= 2 && outList[1].mNumberChannels == 1
        let outPtr1 = outPlanarStereo ? outList[1].mData?.assumingMemoryBound(to: Float32.self) : nil

        guard let outPtr0 else { return }

        var sawSignal = false
        for f in 0..<frameCount {
            var inL: Float32 = 0
            var inR: Float32 = 0
            if let inPtr0 {
                if inInterleavedStereo {
                    let base = f * inStride
                    inL = inPtr0[base]
                    inR = inPtr0[base + 1]
                } else if inPlanarStereo, let inPtr1 {
                    inL = inPtr0[f]
                    inR = inPtr1[f]
                } else {
                    inL = inPtr0[f]
                    inR = inL
                }
            }

            if abs(inL) > 1e-6 || abs(inR) > 1e-6 {
                sawSignal = true
            }

            let (outL, outR) = processor.processFrame(left: inL, right: inR, settings: cachedSettings)

            if outChannels >= 2 {
                let base = f * outChannels
                outPtr0[base] = outL
                outPtr0[base + 1] = outR
                if outChannels > 2 {
                    for c in 2..<outChannels { outPtr0[base + c] = 0 }
                }
            } else if outPlanarStereo, let outPtr1 {
                outPtr0[f] = outL
                outPtr1[f] = outR
            } else {
                outPtr0[f] = 0.5 * (outL + outR)
            }
        }

        if os_unfair_lock_trylock(&lock) {
            ioCallbacks &+= 1
            if sawSignal { nonZeroCallbacks &+= 1 }
            os_unfair_lock_unlock(&lock)
        }
    }
}

/// Owns one active CoreAudio Process Tap + private Aggregate Device + IOProc lifecycle.
@available(macOS 14.2, *)
private final class TapPipeline: @unchecked Sendable {
    let targetDeviceUID: String
    let targetDeviceID: AudioObjectID
    let sampleRate: Double
    let context: RealtimeAudioContext

    private var stateLock = os_unfair_lock_s()
    private var tapID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var stopped = false

    init(targetDeviceUID: String, targetDeviceID: AudioObjectID, initialSettings: BassSettings, ioQueue: DispatchQueue) throws {
        self.targetDeviceUID = targetDeviceUID
        self.targetDeviceID = targetDeviceID

        guard let selfProcessObj = AudioDevices.currentProcessObjectID() else {
            throw TapPipelineError.message("Could not resolve CoreAudio process handle")
        }

        let tapUUID = UUID()
        let tapDesc = CATapDescription(excludingProcesses: [selfProcessObj], deviceUID: targetDeviceUID, stream: 0)
        tapDesc.uuid = tapUUID
        tapDesc.name = "Dyson Zone Bass Tap"
        tapDesc.isPrivate = true
        tapDesc.muteBehavior = .mutedWhenTapped

        var createdTapID = AudioObjectID(kAudioObjectUnknown)
        let tapErr = AudioHardwareCreateProcessTap(tapDesc, &createdTapID)
        guard tapErr == noErr, createdTapID != kAudioObjectUnknown else {
            throw TapPipelineError.osStatus("Process tap failed", tapErr)
        }
        self.tapID = createdTapID

        var fmtAddr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let fmtErr = AudioObjectGetPropertyData(createdTapID, &fmtAddr, 0, nil, &asbdSize, &asbd)
        let detectedRate = (fmtErr == noErr && asbd.mSampleRate > 8_000)
            ? asbd.mSampleRate
            : (AudioDevices.sampleRate(targetDeviceID, input: false) ?? 48_000)
        self.sampleRate = detectedRate

        let subdeviceInputBuffers = AudioDevices.streamBufferCount(targetDeviceID, scope: kAudioObjectPropertyScopeInput)
        let rtContext = RealtimeAudioContext(
            sampleRate: detectedRate,
            initialSettings: initialSettings,
            tapStartBufferIndex: subdeviceInputBuffers
        )
        self.context = rtContext

        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Dyson Zone Software Bass",
            kAudioAggregateDeviceUIDKey: "dev.nik.DysonZoneCompanion.bass.\(tapUUID.uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: targetDeviceUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: targetDeviceUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUUID.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapDriftCompensationQualityKey: kAudioAggregateDriftCompensationHighQuality
                ]
            ]
        ]

        var createdAggID = AudioObjectID(kAudioObjectUnknown)
        let aggErr = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &createdAggID)
        guard aggErr == noErr, createdAggID != kAudioObjectUnknown else {
            AudioHardwareDestroyProcessTap(createdTapID)
            self.tapID = AudioObjectID(kAudioObjectUnknown)
            throw TapPipelineError.osStatus("Aggregate audio device failed", aggErr)
        }
        self.aggregateID = createdAggID

        // Wait briefly for CoreAudio HAL to publish both output and sub-tap input streams on the aggregate device
        var hasExpectedStreams = false
        for _ in 0..<25 {
            if AudioDevices.isAlive(createdAggID),
               AudioDevices.streamBufferCount(createdAggID, scope: kAudioObjectPropertyScopeOutput) > 0,
               AudioDevices.streamBufferCount(createdAggID, scope: kAudioObjectPropertyScopeInput) > subdeviceInputBuffers {
                hasExpectedStreams = true
                break
            }
            Thread.sleep(forTimeInterval: 0.012)
        }
        guard hasExpectedStreams else {
            AudioHardwareDestroyAggregateDevice(createdAggID)
            AudioHardwareDestroyProcessTap(createdTapID)
            self.aggregateID = AudioObjectID(kAudioObjectUnknown)
            self.tapID = AudioObjectID(kAudioObjectUnknown)
            throw TapPipelineError.message("Audio tap stream did not become ready")
        }

        var procID: AudioDeviceIOProcID?
        let procErr = AudioDeviceCreateIOProcIDWithBlock(&procID, createdAggID, ioQueue) { _, inInputData, _, outOutputData, _ in
            rtContext.render(input: inInputData, output: outOutputData)
        }
        guard procErr == noErr, let procID else {
            AudioHardwareDestroyAggregateDevice(createdAggID)
            AudioHardwareDestroyProcessTap(createdTapID)
            self.aggregateID = AudioObjectID(kAudioObjectUnknown)
            self.tapID = AudioObjectID(kAudioObjectUnknown)
            throw TapPipelineError.osStatus("Audio callback setup failed", procErr)
        }
        self.ioProcID = procID

        let startErr = AudioDeviceStart(createdAggID, procID)
        guard startErr == noErr else {
            AudioDeviceDestroyIOProcID(createdAggID, procID)
            AudioHardwareDestroyAggregateDevice(createdAggID)
            AudioHardwareDestroyProcessTap(createdTapID)
            self.ioProcID = nil
            self.aggregateID = AudioObjectID(kAudioObjectUnknown)
            self.tapID = AudioObjectID(kAudioObjectUnknown)
            throw TapPipelineError.osStatus("Audio stream start failed", startErr)
        }
    }

    func stop() {
        os_unfair_lock_lock(&stateLock)
        if stopped {
            os_unfair_lock_unlock(&stateLock)
            return
        }
        stopped = true
        let agg = aggregateID
        let proc = ioProcID
        let tap = tapID
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        ioProcID = nil
        tapID = AudioObjectID(kAudioObjectUnknown)
        os_unfair_lock_unlock(&stateLock)

        if agg != kAudioObjectUnknown {
            if let proc {
                AudioDeviceStop(agg, proc)
                AudioDeviceDestroyIOProcID(agg, proc)
            }
            AudioHardwareDestroyAggregateDevice(agg)
        }
        if tap != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tap)
        }
    }

    deinit {
        stop()
    }
}

private enum TapPipelineError: LocalizedError {
    case message(String)
    case osStatus(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case .message(let msg): return msg
        case .osStatus(let prefix, let status): return "\(prefix) (\(status))"
        }
    }
}

/// Manages software-level bass boost for Dyson Zone audio independently of the headphones' BLE EQ preset.
@MainActor
final class BassBoost: ObservableObject {
    private static let defaultsKey = "bassBoostSettings"

    @Published private(set) var settings: BassSettings
    @Published private(set) var status: BassEngineStatus = .off

    private let controlQueue = DispatchQueue(label: "dev.nik.DysonZoneCompanion.bass.control", qos: .userInitiated)
    private let ioQueue = DispatchQueue(label: "dev.nik.DysonZoneCompanion.bass.io", qos: .userInteractive)

    private var pipelineBox: AnyObject?
    private var desiredUID: String?
    private var desiredDeviceID: AudioObjectID?
    private var isCallMode = false
    private var generation: UInt64 = 0
    private var watchdogTimer: Timer?
    private var silentActiveChecks = 0
    private var confirmedCapture = false
    private var terminateObserver: NSObjectProtocol?
    private var listenerDeviceID: AudioObjectID?
    private var rateListenerBlock: AudioObjectPropertyListenerBlock?
    private var restartListenerBlock: AudioObjectPropertyListenerBlock?

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode(BassSettings.self, from: data) {
            self.settings = decoded
        } else {
            self.settings = BassSettings()
        }

        installSystemListeners()
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated { self.shutdownSynchronously() }
        }

        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkHealth() }
        }
        reconcile()
    }

    var isEnabled: Bool {
        get { settings.isEnabled }
        set {
            guard settings.isEnabled != newValue else { return }
            settings.isEnabled = newValue
            persistAndPush()
            reconcile()
        }
    }

    var preventClipping: Bool {
        get { settings.preventClipping }
        set {
            guard settings.preventClipping != newValue else { return }
            settings.preventClipping = newValue
            persistAndPush()
        }
    }

    var peakBoost: (gainDB: Double, atHz: Double) {
        BassBoostDSP.peakBoost(for: settings)
    }

    var activePresetLabel: String {
        settings.preset?.label ?? "Custom"
    }

    func selectPreset(_ preset: BassPreset) {
        settings.apply(preset)
        if !settings.isEnabled {
            settings.isEnabled = true
            persistAndPush()
            reconcile()
        } else {
            persistAndPush()
        }
    }

    func setSubGain(_ db: Double) {
        settings.subGainDB = db
        settings.syncMatchingPreset()
        persistAndPush()
    }

    func setPunchGain(_ db: Double) {
        settings.punchGainDB = db
        settings.syncMatchingPreset()
        persistAndPush()
    }

    func setFrequency(_ hz: Double) {
        settings.frequencyHz = hz
        settings.syncMatchingPreset()
        persistAndPush()
    }

    func updateTarget(deviceUID: String?, deviceID: AudioObjectID?, isCallMode: Bool) {
        guard deviceUID != desiredUID || deviceID != desiredDeviceID || isCallMode != self.isCallMode else {
            return
        }
        desiredUID = deviceUID
        desiredDeviceID = deviceID
        self.isCallMode = isCallMode
        updateDeviceListener(deviceID)
        reconcile()
    }

    func openSystemAudioSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    private func persistAndPush() {
        if let encoded = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(encoded, forKey: Self.defaultsKey)
        }
        if #available(macOS 14.2, *), let pipeline = pipelineBox as? TapPipeline {
            pipeline.context.updateSettings(settings)
        }
    }

    private func reconcile(forceRestart: Bool = false) {
        guard #available(macOS 14.2, *) else {
            status = settings.isEnabled ? .failed("Requires macOS 14.2 or later") : .off
            return
        }

        guard settings.isEnabled else {
            tearDownPipeline()
            status = .off
            return
        }

        guard let targetUID = desiredUID, let targetID = desiredDeviceID else {
            tearDownPipeline()
            status = .waitingForHeadphones
            return
        }

        if isCallMode {
            tearDownPipeline()
            status = .pausedForCall
            return
        }

        if !forceRestart, let existing = pipelineBox as? TapPipeline,
           existing.targetDeviceUID == targetUID, existing.targetDeviceID == targetID {
            existing.context.updateSettings(settings)
            if case .off = status { status = .active(existing.sampleRate) }
            return
        }

        tearDownPipeline()
        status = .starting
        silentActiveChecks = 0
        generation &+= 1
        let expectedGen = generation
        let initialSettings = settings
        let ioQ = ioQueue

        controlQueue.async { [weak self] in
            do {
                let created = try TapPipeline(
                    targetDeviceUID: targetUID,
                    targetDeviceID: targetID,
                    initialSettings: initialSettings,
                    ioQueue: ioQ
                )
                Log.write("software bass started on \(targetUID) (\(Int(created.sampleRate)) Hz)")
                DispatchQueue.main.async {
                    guard let self else {
                        created.stop()
                        return
                    }
                    guard self.generation == expectedGen, self.settings.isEnabled else {
                        self.controlQueue.async { created.stop() }
                        return
                    }
                    created.context.updateSettings(self.settings)
                    self.pipelineBox = created
                    self.status = .active(created.sampleRate)
                }
            } catch {
                Log.write("software bass failed: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    guard let self, self.generation == expectedGen else { return }
                    self.status = .failed(error.localizedDescription)
                }
            }
        }
    }

    private func tearDownPipeline() {
        generation &+= 1
        silentActiveChecks = 0
        guard #available(macOS 14.2, *), let existing = pipelineBox as? TapPipeline else {
            pipelineBox = nil
            return
        }
        pipelineBox = nil
        controlQueue.async {
            existing.stop()
        }
    }

    private func shutdownSynchronously() {
        generation &+= 1
        guard #available(macOS 14.2, *), let existing = pipelineBox as? TapPipeline else { return }
        pipelineBox = nil
        controlQueue.sync {
            existing.stop()
        }
    }

    private func checkHealth() {
        guard #available(macOS 14.2, *), settings.isEnabled, let pipeline = pipelineBox as? TapPipeline else { return }

        if !AudioDevices.isAlive(pipeline.targetDeviceID) {
            reconcile(forceRestart: true)
            return
        }

        if let currentRate = AudioDevices.sampleRate(pipeline.targetDeviceID, input: false),
           currentRate > 8_000, abs(currentRate - pipeline.sampleRate) > 1.0 {
            reconcile(forceRestart: true)
            return
        }

        let stats = pipeline.context.snapshotStats()
        if stats.nonZeroCallbacks > 0 {
            confirmedCapture = true
            silentActiveChecks = 0
            if case .permissionNeeded = status {
                status = .active(pipeline.sampleRate)
            }
            return
        }

        guard !confirmedCapture else { return }
        if stats.callbacks > 25, AudioDevices.isAnyOtherProcessOutputting(to: pipeline.targetDeviceID) {
            silentActiveChecks += 1
            if silentActiveChecks >= 2 {
                status = .permissionNeeded
            }
        } else {
            silentActiveChecks = 0
        }
    }

    private func installSystemListeners() {
        var restartAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyServiceRestarted,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.reconcile(forceRestart: true) }
        }
        restartListenerBlock = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &restartAddr, DispatchQueue.main, block)
    }

    private func updateDeviceListener(_ newID: AudioObjectID?) {
        if let oldID = listenerDeviceID, let block = rateListenerBlock {
            var rateAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyNominalSampleRate,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(oldID, &rateAddr, DispatchQueue.main, block)
            listenerDeviceID = nil
            rateListenerBlock = nil
        }

        guard let newID else { return }
        var rateAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.reconcile(forceRestart: true) }
        }
        if AudioObjectAddPropertyListenerBlock(newID, &rateAddr, DispatchQueue.main, block) == noErr {
            listenerDeviceID = newID
            rateListenerBlock = block
        }
    }
}
