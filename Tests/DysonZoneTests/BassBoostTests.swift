import CoreAudio
import XCTest
@testable import DysonZone

final class BassBoostTests: XCTestCase {
    private let sampleRate = 48_000.0

    private func measureSineGainDB(
        hz: Double,
        amplitude: Float = 0.05,
        settings: BassSettings
    ) -> Double {
        let processor = BassBoostProcessor(sampleRate: sampleRate, initialSettings: settings)
        let settleFrames = 24_000
        let measureFrames = 24_000
        var inSumSq = 0.0
        var outSumSq = 0.0

        for n in 0..<(settleFrames + measureFrames) {
            let t = Double(n) / sampleRate
            let sample = amplitude * Float(sin(2.0 * Double.pi * hz * t))
            let (outL, outR) = processor.processFrame(left: sample, right: sample, settings: settings)
            XCTAssertEqual(outL, outR, accuracy: 1e-6)
            if n >= settleFrames {
                let dIn = Double(sample)
                let dOut = Double(outL)
                inSumSq += dIn * dIn
                outSumSq += dOut * dOut
            }
        }

        let inRMS = sqrt(inSumSq / Double(measureFrames))
        let outRMS = sqrt(outSumSq / Double(measureFrames))
        return 20.0 * log10(outRMS / inRMS)
    }

    func testAnalyticalResponseMatchesEmpiricalSineProcessing() {
        var settings = BassSettings()
        settings.isEnabled = true
        settings.apply(.heavy)
        settings.preventClipping = false // isolate pure filter response without headroom trim

        for hz in [20.0, 35.0, 50.0, 95.0, 250.0, 1_000.0, 6_000.0] {
            let expectedDB = BassBoostDSP.responseDB(atHz: hz, settings: settings, sampleRate: sampleRate)
            let measuredDB = measureSineGainDB(hz: hz, amplitude: 0.02, settings: settings)
            XCTAssertEqual(measuredDB, expectedDB, accuracy: 0.25, "Mismatch at \(hz) Hz")
        }

        // High mids and treble must remain uncolored (< 0.25 dB) even under Heavy bass boost
        let vocalDB = measureSineGainDB(hz: 1_500.0, amplitude: 0.05, settings: settings)
        let trebleDB = measureSineGainDB(hz: 8_000.0, amplitude: 0.05, settings: settings)
        XCTAssertEqual(vocalDB, 0.0, accuracy: 0.25)
        XCTAssertEqual(trebleDB, 0.0, accuracy: 0.10)
    }

    func testSubsonicHighPassProtectsDriverBelow15Hz() {
        var settings = BassSettings()
        settings.isEnabled = true
        settings.subGainDB = 0
        settings.punchGainDB = 0
        settings.preventClipping = false

        let at15Hz = BassBoostDSP.responseDB(atHz: 15.0, settings: settings, sampleRate: sampleRate)
        let at5Hz = BassBoostDSP.responseDB(atHz: 5.0, settings: settings, sampleRate: sampleRate)
        let at200Hz = BassBoostDSP.responseDB(atHz: 200.0, settings: settings, sampleRate: sampleRate)

        XCTAssertEqual(at15Hz, -3.01, accuracy: 0.2)
        XCTAssertLessThan(at5Hz, -18.0)
        XCTAssertEqual(at200Hz, 0.0, accuracy: 0.05)
    }

    func testPresetsAndCustomAdjustmentSync() {
        var settings = BassSettings()
        for preset in BassPreset.allCases {
            settings.apply(preset)
            XCTAssertEqual(settings.preset, preset)
            settings.syncMatchingPreset()
            XCTAssertEqual(settings.preset, preset)
        }

        // Ordering check: Max > Heavy > Deep > Warm peak boost
        var warm = BassSettings(); warm.apply(.warm)
        var deep = BassSettings(); deep.apply(.deep)
        var heavy = BassSettings(); heavy.apply(.heavy)
        var maxPreset = BassSettings(); maxPreset.apply(.max)

        XCTAssertGreaterThan(BassBoostDSP.peakBoost(for: deep).gainDB, BassBoostDSP.peakBoost(for: warm).gainDB)
        XCTAssertGreaterThan(BassBoostDSP.peakBoost(for: heavy).gainDB, BassBoostDSP.peakBoost(for: deep).gainDB)
        XCTAssertGreaterThan(BassBoostDSP.peakBoost(for: maxPreset).gainDB, BassBoostDSP.peakBoost(for: heavy).gainDB)

        // Manual slider tweak switches preset to nil (Custom), and returning to preset values re-matches
        settings.apply(.punch)
        settings.subGainDB = 9.3
        settings.syncMatchingPreset()
        XCTAssertNil(settings.preset)

        settings.subGainDB = BassPreset.punch.subGainDB
        settings.syncMatchingPreset()
        XCTAssertEqual(settings.preset, .punch)
    }

    func testLookaheadLimiterPreventsClippingUnderExtremeBoost() {
        var settings = BassSettings()
        settings.isEnabled = true
        settings.apply(.max) // +15 dB Sub, +10.5 dB Punch
        settings.preventClipping = true

        let processor = BassBoostProcessor(sampleRate: sampleRate, initialSettings: settings)
        var maxAbsSample: Float = 0

        // Full-scale hot master: 0.70 @ 48 Hz + 0.28 @ 90 Hz + 0.25 @ 1 kHz
        for n in 0..<48_000 {
            let t = Double(n) / sampleRate
            let sig = Float(
                0.70 * sin(2.0 * Double.pi * 48.0 * t) +
                0.28 * sin(2.0 * Double.pi * 90.0 * t) +
                0.25 * sin(2.0 * Double.pi * 1_000.0 * t)
            )
            let (outL, outR) = processor.processFrame(left: sig, right: -sig, settings: settings)
            XCTAssertTrue(outL.isFinite && outR.isFinite)
            maxAbsSample = max(maxAbsSample, max(abs(outL), abs(outR)))
        }

        XCTAssertLessThanOrEqual(maxAbsSample, 0.995, "Limiter must prevent any sample from clipping 0 dBFS")
        XCTAssertGreaterThan(maxAbsSample, 0.80, "Output should still retain strong loudness near ceiling")

        // Turning off Prevent clipping bypasses both headroom trim and soft-clipping
        settings.preventClipping = false
        let rawProcessor = BassBoostProcessor(sampleRate: sampleRate, initialSettings: settings)
        var rawPeak: Float = 0
        for n in 0..<8_000 {
            let t = Double(n) / sampleRate
            let sig = Float(0.50 * sin(2.0 * Double.pi * 55.0 * t))
            let (outL, _) = rawProcessor.processFrame(left: sig, right: sig, settings: settings)
            rawPeak = max(rawPeak, abs(outL))
        }
        XCTAssertGreaterThan(rawPeak, 1.2, "With Prevent clipping off, hot boosted signal must not be soft-clipped at 0.992")
    }

    func testParameterSweepAndBypassTransitionsAreClickFree() {
        var settings = BassSettings()
        settings.isEnabled = false
        settings.apply(.warm)

        let processor = BassBoostProcessor(sampleRate: sampleRate, initialSettings: settings)
        var prevL: Float = 0
        var maxDelta: Float = 0

        for n in 0..<24_000 {
            if n == 4_000 { settings.isEnabled = true }
            if n == 8_000 { settings.apply(.max) }
            if n == 12_000 { settings.frequencyHz = 88; settings.subGainDB = 2.0 }
            if n == 16_000 { settings.isEnabled = false }
            if n == 20_000 { settings.isEnabled = true; settings.apply(.heavy) }

            let t = Double(n) / sampleRate
            let x = Float(0.3 * sin(2.0 * Double.pi * 55.0 * t) + 0.2 * sin(2.0 * Double.pi * 440.0 * t))
            let (outL, _) = processor.processFrame(left: x, right: x, settings: settings)
            if n > processor.lookaheadFrames + 4 {
                maxDelta = max(maxDelta, abs(outL - prevL))
            }
            prevL = outL
        }

        // Max theoretical step of 440 Hz @ 0.2 + boosted 55 Hz @ <=1.0 at 48 kHz is ~0.025; a click/discontinuity would be > 0.15
        XCTAssertLessThan(maxDelta, 0.08, "Detected audible discontinuity / click during live toggle or slider change")
    }

    func testNonFiniteInputSelfHeals() {
        var settings = BassSettings()
        settings.isEnabled = true
        settings.apply(.heavy)

        let processor = BassBoostProcessor(sampleRate: sampleRate, initialSettings: settings)
        _ = processor.processFrame(left: .nan, right: .infinity, settings: settings)
        _ = processor.processFrame(left: -.infinity, right: .nan, settings: settings)

        for n in 0..<512 {
            let x = Float(0.2 * sin(2.0 * Double.pi * 60.0 * Double(n) / sampleRate))
            let (outL, outR) = processor.processFrame(left: x, right: x, settings: settings)
            XCTAssertTrue(outL.isFinite && outR.isFinite)
        }
    }

    func testSettingsCodablePersistence() throws {
        var original = BassSettings()
        original.isEnabled = true
        original.subGainDB = 12.4
        original.punchGainDB = 6.8
        original.frequencyHz = 78
        original.preventClipping = false
        original.syncMatchingPreset()

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(BassSettings.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testRealtimeContextHandlesInterleavedPlanarAndSubdeviceInputOffset() {
        var settings = BassSettings()
        settings.isEnabled = true
        settings.apply(.heavy)
        settings.preventClipping = false

        // Simulate a full-duplex device where buffer 0 is hardware mic noise and buffer 1 is the stereo SubTap
        let ctx = RealtimeAudioContext(sampleRate: sampleRate, initialSettings: settings, tapStartBufferIndex: 1)
        let frames = 512
        var micNoise = [Float32](repeating: 0.99, count: frames * 2)
        var tapInput = [Float32](repeating: 0, count: frames * 2)
        var outStereo = [Float32](repeating: 0, count: frames * 2)

        // Feed silent callback first -> nonZeroCallbacks must stay 0
        let inABL = AudioBufferList.allocate(maximumBuffers: 2)
        let outABL = AudioBufferList.allocate(maximumBuffers: 1)
        defer {
            inABL.unsafeMutablePointer.deallocate()
            outABL.unsafeMutablePointer.deallocate()
        }

        micNoise.withUnsafeMutableBufferPointer { micPtr in
            tapInput.withUnsafeMutableBufferPointer { tapPtr in
                outStereo.withUnsafeMutableBufferPointer { outPtr in
                    inABL[0] = AudioBuffer(
                        mNumberChannels: 2,
                        mDataByteSize: UInt32(frames * 2 * MemoryLayout<Float32>.size),
                        mData: micPtr.baseAddress
                    )
                    inABL[1] = AudioBuffer(
                        mNumberChannels: 2,
                        mDataByteSize: UInt32(frames * 2 * MemoryLayout<Float32>.size),
                        mData: tapPtr.baseAddress
                    )
                    outABL[0] = AudioBuffer(
                        mNumberChannels: 2,
                        mDataByteSize: UInt32(frames * 2 * MemoryLayout<Float32>.size),
                        mData: outPtr.baseAddress
                    )
                    ctx.render(input: inABL.unsafePointer, output: outABL.unsafeMutablePointer)
                }
            }
        }

        XCTAssertEqual(ctx.snapshotStats().callbacks, 1)
        XCTAssertEqual(ctx.snapshotStats().nonZeroCallbacks, 0, "Hardware input buffer 0 must be ignored in favor of tap buffer 1")

        // Now feed 50 Hz stereo signal on tap buffer 1 across multiple callbacks and verify bass boost gain
        var inSumSq = 0.0
        var outSumSq = 0.0
        let totalBlocks = 40
        for block in 0..<totalBlocks {
            for f in 0..<frames {
                let n = block * frames + f
                let v = Float32(0.05 * sin(2.0 * Double.pi * 50.0 * Double(n) / sampleRate))
                tapInput[f * 2] = v
                tapInput[f * 2 + 1] = -v
            }
            micNoise.withUnsafeMutableBufferPointer { micPtr in
                tapInput.withUnsafeMutableBufferPointer { tapPtr in
                    outStereo.withUnsafeMutableBufferPointer { outPtr in
                        inABL[0].mData = UnsafeMutableRawPointer(micPtr.baseAddress)
                        inABL[1].mData = UnsafeMutableRawPointer(tapPtr.baseAddress)
                        outABL[0].mData = UnsafeMutableRawPointer(outPtr.baseAddress)
                        ctx.render(input: inABL.unsafePointer, output: outABL.unsafeMutablePointer)
                    }
                }
            }
            if block >= 20 {
                for f in 0..<frames {
                    let iL = Double(tapInput[f * 2])
                    let oL = Double(outStereo[f * 2])
                    let oR = Double(outStereo[f * 2 + 1])
                    inSumSq += iL * iL
                    outSumSq += oL * oL
                    XCTAssertEqual(Float(oL), Float(-oR), accuracy: 1e-5)
                }
            }
        }

        XCTAssertGreaterThan(ctx.snapshotStats().nonZeroCallbacks, 30)
        let gainDB = 10.0 * log10(outSumSq / inSumSq)
        XCTAssertGreaterThan(gainDB, 10.0, "Expected > +10 dB bass boost at 50 Hz in Heavy preset, got \(gainDB) dB")

        // Planar output check (2 mono buffers)
        let ctxPlanar = RealtimeAudioContext(sampleRate: sampleRate, initialSettings: settings, tapStartBufferIndex: 0)
        var inL = [Float32](repeating: 0.1, count: frames)
        var inR = [Float32](repeating: -0.1, count: frames)
        var outL = [Float32](repeating: 0, count: frames)
        var outR = [Float32](repeating: 0, count: frames)
        let planarIn = AudioBufferList.allocate(maximumBuffers: 2)
        let planarOut = AudioBufferList.allocate(maximumBuffers: 2)
        defer {
            planarIn.unsafeMutablePointer.deallocate()
            planarOut.unsafeMutablePointer.deallocate()
        }
        inL.withUnsafeMutableBufferPointer { pIL in
            inR.withUnsafeMutableBufferPointer { pIR in
                outL.withUnsafeMutableBufferPointer { pOL in
                    outR.withUnsafeMutableBufferPointer { pOR in
                        planarIn[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: pIL.baseAddress)
                        planarIn[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: pIR.baseAddress)
                        planarOut[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: pOL.baseAddress)
                        planarOut[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: pOR.baseAddress)
                        ctxPlanar.render(input: planarIn.unsafePointer, output: planarOut.unsafeMutablePointer)
                    }
                }
            }
        }
        XCTAssertEqual(ctxPlanar.snapshotStats().nonZeroCallbacks, 1)

        // If expected tap buffer (index 1) is absent and only hardware input buffer 0 is present, must NOT replay mic
        let ctxMissingTap = RealtimeAudioContext(sampleRate: sampleRate, initialSettings: settings, tapStartBufferIndex: 1)
        var singleMicIn = [Float32](repeating: 0.75, count: frames * 2)
        var muteCheckOut = [Float32](repeating: 1.0, count: frames * 2)
        let oneIn = AudioBufferList.allocate(maximumBuffers: 1)
        let oneOut = AudioBufferList.allocate(maximumBuffers: 1)
        defer {
            oneIn.unsafeMutablePointer.deallocate()
            oneOut.unsafeMutablePointer.deallocate()
        }
        singleMicIn.withUnsafeMutableBufferPointer { pMic in
            muteCheckOut.withUnsafeMutableBufferPointer { pOut in
                oneIn[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(frames * 8), mData: pMic.baseAddress)
                oneOut[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(frames * 8), mData: pOut.baseAddress)
                ctxMissingTap.render(input: oneIn.unsafePointer, output: oneOut.unsafeMutablePointer)
            }
        }
        XCTAssertEqual(ctxMissingTap.snapshotStats().nonZeroCallbacks, 0)
        XCTAssertEqual(muteCheckOut.max() ?? 1, 0, accuracy: 1e-6)
    }
}
