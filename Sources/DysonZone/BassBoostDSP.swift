import Foundation

enum BassPreset: String, CaseIterable, Codable, Identifiable, Sendable {
    case warm
    case deep
    case punch
    case heavy
    case max

    var id: String { rawValue }

    var label: String {
        switch self {
        case .warm: return "Warm"
        case .deep: return "Deep"
        case .punch: return "Punch"
        case .heavy: return "Heavy"
        case .max: return "Max"
        }
    }

    var subGainDB: Double {
        switch self {
        case .warm: return 3.5
        case .deep: return 8.0
        case .punch: return 4.5
        case .heavy: return 11.5
        case .max: return 15.0
        }
    }

    var punchGainDB: Double {
        switch self {
        case .warm: return 2.5
        case .deep: return 3.0
        case .punch: return 8.5
        case .heavy: return 7.5
        case .max: return 11.0
        }
    }

    var frequencyHz: Double {
        switch self {
        case .warm: return 85
        case .deep: return 75
        case .punch: return 90
        case .heavy: return 85
        case .max: return 85
        }
    }
}

struct BassSettings: Codable, Equatable, Sendable {
    static let subGainRange: ClosedRange<Double> = 0...15
    static let punchGainRange: ClosedRange<Double> = 0...12
    static let frequencyRange: ClosedRange<Double> = 50...140

    var isEnabled: Bool = false
    var preset: BassPreset? = .deep
    var subGainDB: Double = BassPreset.deep.subGainDB
    var punchGainDB: Double = BassPreset.deep.punchGainDB
    var frequencyHz: Double = BassPreset.deep.frequencyHz
    var preventClipping: Bool = true

    var clampedSubGainDB: Double { min(max(subGainDB, Self.subGainRange.lowerBound), Self.subGainRange.upperBound) }
    var clampedPunchGainDB: Double { min(max(punchGainDB, Self.punchGainRange.lowerBound), Self.punchGainRange.upperBound) }
    var clampedFrequencyHz: Double { min(max(frequencyHz, Self.frequencyRange.lowerBound), Self.frequencyRange.upperBound) }

    mutating func apply(_ preset: BassPreset) {
        self.preset = preset
        self.subGainDB = preset.subGainDB
        self.punchGainDB = preset.punchGainDB
        self.frequencyHz = preset.frequencyHz
    }

    mutating func syncMatchingPreset() {
        subGainDB = (clampedSubGainDB * 10).rounded() / 10
        punchGainDB = (clampedPunchGainDB * 10).rounded() / 10
        frequencyHz = clampedFrequencyHz.rounded()
        preset = BassPreset.allCases.first {
            abs($0.subGainDB - subGainDB) < 0.05 &&
            abs($0.punchGainDB - punchGainDB) < 0.05 &&
            abs($0.frequencyHz - frequencyHz) < 0.5
        }
    }
}

struct BiquadCoefficients: Equatable, Sendable {
    var b0: Double
    var b1: Double
    var b2: Double
    var a1: Double
    var a2: Double

    static let identity = BiquadCoefficients(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)

    static func highPass(hz: Double, q: Double = 0.7071067811865475, sampleRate: Double) -> BiquadCoefficients {
        guard sampleRate > 0, q > 0 else { return .identity }
        let clampedHz = min(max(hz, 5), sampleRate * 0.45)
        let w0 = 2.0 * Double.pi * clampedHz / sampleRate
        let cosW0 = cos(w0)
        let sinW0 = sin(w0)
        let alpha = sinW0 / (2.0 * q)

        let b0 = (1.0 + cosW0) * 0.5
        let b1 = -(1.0 + cosW0)
        let b2 = (1.0 + cosW0) * 0.5
        let a0 = 1.0 + alpha
        let a1 = -2.0 * cosW0
        let a2 = 1.0 - alpha

        return BiquadCoefficients(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }

    static func lowShelf(hz: Double, gainDB: Double, slope: Double = 0.85, sampleRate: Double) -> BiquadCoefficients {
        guard sampleRate > 0, abs(gainDB) > 1e-4 else { return .identity }
        let clampedHz = min(max(hz, 15), sampleRate * 0.45)
        let a = pow(10.0, gainDB / 40.0)
        let w0 = 2.0 * Double.pi * clampedHz / sampleRate
        let cosW0 = cos(w0)
        let sinW0 = sin(w0)
        let s = max(slope, 0.1)
        let term = max((a + 1.0 / a) * (1.0 / s - 1.0) + 2.0, 0.0)
        let alpha = sinW0 * 0.5 * sqrt(term)
        let twoSqrtAAlpha = 2.0 * sqrt(a) * alpha

        let b0 = a * ((a + 1.0) - (a - 1.0) * cosW0 + twoSqrtAAlpha)
        let b1 = 2.0 * a * ((a - 1.0) - (a + 1.0) * cosW0)
        let b2 = a * ((a + 1.0) - (a - 1.0) * cosW0 - twoSqrtAAlpha)
        let a0 = (a + 1.0) + (a - 1.0) * cosW0 + twoSqrtAAlpha
        let a1 = -2.0 * ((a - 1.0) + (a + 1.0) * cosW0)
        let a2 = (a + 1.0) + (a - 1.0) * cosW0 - twoSqrtAAlpha

        return BiquadCoefficients(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }

    static func peaking(hz: Double, gainDB: Double, q: Double = 1.15, sampleRate: Double) -> BiquadCoefficients {
        guard sampleRate > 0, q > 0, abs(gainDB) > 1e-4 else { return .identity }
        let clampedHz = min(max(hz, 20), sampleRate * 0.45)
        let a = pow(10.0, gainDB / 40.0)
        let w0 = 2.0 * Double.pi * clampedHz / sampleRate
        let cosW0 = cos(w0)
        let sinW0 = sin(w0)
        let alpha = sinW0 / (2.0 * q)

        let b0 = 1.0 + alpha * a
        let b1 = -2.0 * cosW0
        let b2 = 1.0 - alpha * a
        let a0 = 1.0 + alpha / a
        let a1 = -2.0 * cosW0
        let a2 = 1.0 - alpha / a

        return BiquadCoefficients(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }

    func magnitudeSquared(atHz hz: Double, sampleRate: Double) -> Double {
        guard sampleRate > 0 else { return 1 }
        let w = 2.0 * Double.pi * hz / sampleRate
        let c1 = cos(w)
        let s1 = sin(w)
        let c2 = cos(2.0 * w)
        let s2 = sin(2.0 * w)
        let numRe = b0 + b1 * c1 + b2 * c2
        let numIm = -b1 * s1 - b2 * s2
        let denRe = 1.0 + a1 * c1 + a2 * c2
        let denIm = -a1 * s1 - a2 * s2
        let den = denRe * denRe + denIm * denIm
        guard den > 1e-24 else { return 1 }
        return (numRe * numRe + numIm * numIm) / den
    }
}

enum BassBoostDSP {
    static let subsonicHighPassHz: Double = 15.0

    static func stageCoefficients(
        subGainDB: Double,
        punchGainDB: Double,
        frequencyHz: Double,
        sampleRate: Double
    ) -> (highPass: BiquadCoefficients, subShelf: BiquadCoefficients, punchPeak: BiquadCoefficients) {
        let clampedFreq = min(max(frequencyHz, BassSettings.frequencyRange.lowerBound), BassSettings.frequencyRange.upperBound)
        let punchHz = min(max(clampedFreq * 1.35, 80), 165)
        let hp = BiquadCoefficients.highPass(hz: subsonicHighPassHz, sampleRate: sampleRate)
        let shelf = BiquadCoefficients.lowShelf(hz: clampedFreq, gainDB: max(0, subGainDB), slope: 0.90, sampleRate: sampleRate)
        let peak = BiquadCoefficients.peaking(hz: punchHz, gainDB: max(0, punchGainDB), q: 1.25, sampleRate: sampleRate)
        return (hp, shelf, peak)
    }

    static func responseDB(atHz hz: Double, settings: BassSettings, sampleRate: Double = 48_000) -> Double {
        let stages = stageCoefficients(
            subGainDB: settings.clampedSubGainDB,
            punchGainDB: settings.clampedPunchGainDB,
            frequencyHz: settings.clampedFrequencyHz,
            sampleRate: sampleRate
        )
        let mag2 = stages.highPass.magnitudeSquared(atHz: hz, sampleRate: sampleRate)
            * stages.subShelf.magnitudeSquared(atHz: hz, sampleRate: sampleRate)
            * stages.punchPeak.magnitudeSquared(atHz: hz, sampleRate: sampleRate)
        guard mag2 > 1e-20 else { return -100 }
        return 10.0 * log10(mag2)
    }

    static func peakBoost(for settings: BassSettings, sampleRate: Double = 48_000) -> (gainDB: Double, atHz: Double) {
        var bestDB = 0.0
        var bestHz = settings.clampedFrequencyHz
        let steps = 96
        let minLog = log(20.0)
        let maxLog = log(300.0)
        for i in 0...steps {
            let t = Double(i) / Double(steps)
            let hz = exp(minLog + t * (maxLog - minLog))
            let db = responseDB(atHz: hz, settings: settings, sampleRate: sampleRate)
            if db > bestDB {
                bestDB = db
                bestHz = hz
            }
        }
        return (bestDB, bestHz)
    }

    /// Gentle partial headroom pre-trim so quiet/normal tracks stay punchy and loud while the lookahead limiter catches peaks.
    static func autoHeadroomTrimDB(subGainDB: Double, punchGainDB: Double, frequencyHz: Double, sampleRate: Double) -> Double {
        var s = BassSettings()
        s.subGainDB = subGainDB
        s.punchGainDB = punchGainDB
        s.frequencyHz = frequencyHz
        let peak = max(0, peakBoost(for: s, sampleRate: sampleRate).gainDB)
        return -min(peak * 0.22, 3.0)
    }
}

private struct StereoBiquadState {
    var z1L: Double = 0
    var z2L: Double = 0
    var z1R: Double = 0
    var z2R: Double = 0

    @inline(__always)
    mutating func process(_ c: BiquadCoefficients, left: inout Double, right: inout Double) {
        let yL = c.b0 * left + z1L
        z1L = c.b1 * left - c.a1 * yL + z2L
        z2L = c.b2 * left - c.a2 * yL
        left = yL

        let yR = c.b0 * right + z1R
        z1R = c.b1 * right - c.a1 * yR + z2R
        z2R = c.b2 * right - c.a2 * yR
        right = yR
    }

    mutating func reset() {
        z1L = 0; z2L = 0; z1R = 0; z2R = 0
    }
}

/// Real-time stereo DSP processor. Pre-allocates its lookahead ring buffers once on initialization
/// and performs zero heap allocations or locks inside `processFrame`.
final class BassBoostProcessor {
    private static let ringCapacity = 128 // power of two, >= max lookaheadFrames (96)
    private static let ringMask = ringCapacity - 1
    private static let limiterThreshold = 0.955
    private static let softCeiling = 0.992
    private static let controlSubblock = 32

    let sampleRate: Double
    let lookaheadFrames: Int

    private var hpCoeffs: BiquadCoefficients
    private var shelfCoeffs: BiquadCoefficients
    private var peakCoeffs: BiquadCoefficients

    private var hpState = StereoBiquadState()
    private var shelfState = StereoBiquadState()
    private var peakState = StereoBiquadState()

    private var smoothedSubDB: Double
    private var smoothedPunchDB: Double
    private var smoothedFreqHz: Double
    private var smoothedTrimLinear: Double
    private var smoothedWet: Double
    private var limiterGain: Double = 1.0
    private var subblockCounter: Int = 0

    private let paramStepAlpha: Double
    private let wetRampAlpha: Double
    private let attackAlpha: Double
    private let releaseAlpha: Double

    // Pre-allocated ring buffers for phase-aligned wet/dry lookahead limiting
    private let wetDelayL: UnsafeMutablePointer<Double>
    private let wetDelayR: UnsafeMutablePointer<Double>
    private let dryDelayL: UnsafeMutablePointer<Double>
    private let dryDelayR: UnsafeMutablePointer<Double>
    private var writeIndex: Int = 0

    // Fixed-size O(1) monotonic max-queue over the lookahead window
    private let maxQueuePeak: UnsafeMutablePointer<Double>
    private let maxQueueStamp: UnsafeMutablePointer<UInt64>
    private var queueHead: Int = 0
    private var queueTail: Int = 0
    private var sampleStamp: UInt64 = 0

    init(sampleRate: Double, initialSettings: BassSettings = BassSettings()) {
        let validRate = sampleRate > 8_000 ? sampleRate : 48_000
        self.sampleRate = validRate
        self.lookaheadFrames = min(max(Int((validRate * 0.0015).rounded()), 16), 96)

        self.smoothedSubDB = initialSettings.clampedSubGainDB
        self.smoothedPunchDB = initialSettings.clampedPunchGainDB
        self.smoothedFreqHz = initialSettings.clampedFrequencyHz
        self.smoothedWet = initialSettings.isEnabled ? 1.0 : 0.0

        let trimDB = initialSettings.preventClipping
            ? BassBoostDSP.autoHeadroomTrimDB(
                subGainDB: initialSettings.clampedSubGainDB,
                punchGainDB: initialSettings.clampedPunchGainDB,
                frequencyHz: initialSettings.clampedFrequencyHz,
                sampleRate: validRate
            ) : 0.0
        self.smoothedTrimLinear = pow(10.0, trimDB / 20.0)

        let stages = BassBoostDSP.stageCoefficients(
            subGainDB: initialSettings.clampedSubGainDB,
            punchGainDB: initialSettings.clampedPunchGainDB,
            frequencyHz: initialSettings.clampedFrequencyHz,
            sampleRate: validRate
        )
        self.hpCoeffs = stages.highPass
        self.shelfCoeffs = stages.subShelf
        self.peakCoeffs = stages.punchPeak

        // Control smoothing (~25 ms per subblock update) and sample-level wet/limiter constants
        self.paramStepAlpha = 1.0 - exp(-Double(Self.controlSubblock) / (0.025 * validRate))
        self.wetRampAlpha = 1.0 - exp(-1.0 / (0.020 * validRate))
        self.attackAlpha = 1.0 - exp(-4.8 / Double(self.lookaheadFrames))
        self.releaseAlpha = 1.0 - exp(-1.0 / (0.160 * validRate))

        let cap = Self.ringCapacity
        self.wetDelayL = .allocate(capacity: cap)
        self.wetDelayR = .allocate(capacity: cap)
        self.dryDelayL = .allocate(capacity: cap)
        self.dryDelayR = .allocate(capacity: cap)
        self.maxQueuePeak = .allocate(capacity: cap)
        self.maxQueueStamp = .allocate(capacity: cap)

        self.wetDelayL.initialize(repeating: 0, count: cap)
        self.wetDelayR.initialize(repeating: 0, count: cap)
        self.dryDelayL.initialize(repeating: 0, count: cap)
        self.dryDelayR.initialize(repeating: 0, count: cap)
        self.maxQueuePeak.initialize(repeating: 0, count: cap)
        self.maxQueueStamp.initialize(repeating: 0, count: cap)
    }

    deinit {
        let cap = Self.ringCapacity
        wetDelayL.deinitialize(count: cap); wetDelayL.deallocate()
        wetDelayR.deinitialize(count: cap); wetDelayR.deallocate()
        dryDelayL.deinitialize(count: cap); dryDelayL.deallocate()
        dryDelayR.deinitialize(count: cap); dryDelayR.deallocate()
        maxQueuePeak.deinitialize(count: cap); maxQueuePeak.deallocate()
        maxQueueStamp.deinitialize(count: cap); maxQueueStamp.deallocate()
    }

    @inline(__always)
    private func updateCoefficientsIfNeeded(target: BassSettings) {
        let targetSub = target.clampedSubGainDB
        let targetPunch = target.clampedPunchGainDB
        let targetFreq = target.clampedFrequencyHz

        let dSub = targetSub - smoothedSubDB
        let dPunch = targetPunch - smoothedPunchDB
        let dFreq = targetFreq - smoothedFreqHz

        if abs(dSub) > 1e-4 || abs(dPunch) > 1e-4 || abs(dFreq) > 1e-3 {
            smoothedSubDB += paramStepAlpha * dSub
            smoothedPunchDB += paramStepAlpha * dPunch
            smoothedFreqHz += paramStepAlpha * dFreq
            let stages = BassBoostDSP.stageCoefficients(
                subGainDB: smoothedSubDB,
                punchGainDB: smoothedPunchDB,
                frequencyHz: smoothedFreqHz,
                sampleRate: sampleRate
            )
            shelfCoeffs = stages.subShelf
            peakCoeffs = stages.punchPeak
        }

        let targetTrimDB = target.preventClipping
            ? BassBoostDSP.autoHeadroomTrimDB(
                subGainDB: smoothedSubDB,
                punchGainDB: smoothedPunchDB,
                frequencyHz: smoothedFreqHz,
                sampleRate: sampleRate
            ) : 0.0
        let targetTrimLinear = pow(10.0, targetTrimDB / 20.0)
        smoothedTrimLinear += paramStepAlpha * (targetTrimLinear - smoothedTrimLinear)
    }

    @inline(__always)
    private static func softClip(_ x: Double) -> Double {
        let ax = abs(x)
        let knee = limiterThreshold
        if ax <= knee { return x }
        let span = softCeiling - knee
        let shaped = knee + span * tanh((ax - knee) / span)
        return x >= 0 ? shaped : -shaped
    }

    /// Processes one stereo sample frame in place without heap allocations.
    @inline(__always)
    func processFrame(left inL: Float, right inR: Float, settings: BassSettings) -> (Float, Float) {
        if subblockCounter == 0 {
            updateCoefficientsIfNeeded(target: settings)
        }
        subblockCounter = (subblockCounter + 1) & (Self.controlSubblock - 1)

        let dryL = inL.isFinite ? Double(inL) : 0.0
        let dryR = inR.isFinite ? Double(inR) : 0.0

        var wL = dryL
        var wR = dryR
        hpState.process(hpCoeffs, left: &wL, right: &wR)
        shelfState.process(shelfCoeffs, left: &wL, right: &wR)
        peakState.process(peakCoeffs, left: &wL, right: &wR)

        if !wL.isFinite || !wR.isFinite {
            hpState.reset(); shelfState.reset(); peakState.reset()
            wL = 0; wR = 0
        }

        wL *= smoothedTrimLinear
        wR *= smoothedTrimLinear

        let idx = writeIndex
        let readIdx = (idx - lookaheadFrames) & Self.ringMask
        let delayedWetL = wetDelayL[readIdx]
        let delayedWetR = wetDelayR[readIdx]
        let delayedDryL = dryDelayL[readIdx]
        let delayedDryR = dryDelayR[readIdx]

        wetDelayL[idx] = wL
        wetDelayR[idx] = wR
        dryDelayL[idx] = dryL
        dryDelayR[idx] = dryR
        writeIndex = (idx + 1) & Self.ringMask

        // Push incoming peak into monotonic lookahead max-queue
        let inPeak = max(abs(wL), abs(wR))
        let stamp = sampleStamp
        sampleStamp &+= 1

        while queueTail != queueHead {
            let last = (queueTail - 1) & Self.ringMask
            if maxQueuePeak[last] <= inPeak {
                queueTail = last
            } else {
                break
            }
        }
        maxQueuePeak[queueTail] = inPeak
        maxQueueStamp[queueTail] = stamp
        queueTail = (queueTail + 1) & Self.ringMask

        let minValidStamp = stamp >= UInt64(lookaheadFrames) ? stamp - UInt64(lookaheadFrames) : 0
        while queueHead != queueTail && maxQueueStamp[queueHead] < minValidStamp {
            queueHead = (queueHead + 1) & Self.ringMask
        }

        let windowPeak = queueHead != queueTail ? maxQueuePeak[queueHead] : inPeak

        var processedL: Double
        var processedR: Double
        if settings.preventClipping {
            let targetGain = windowPeak > Self.limiterThreshold ? (Self.limiterThreshold / windowPeak) : 1.0
            if targetGain < limiterGain {
                limiterGain += attackAlpha * (targetGain - limiterGain)
            } else {
                limiterGain += releaseAlpha * (targetGain - limiterGain)
            }
            let delayedPeak = max(abs(delayedWetL), abs(delayedWetR))
            let safeGain = delayedPeak > Self.softCeiling ? min(limiterGain, Self.softCeiling / delayedPeak) : limiterGain
            processedL = Self.softClip(delayedWetL * safeGain)
            processedR = Self.softClip(delayedWetR * safeGain)
        } else {
            limiterGain = 1.0
            processedL = delayedWetL
            processedR = delayedWetR
        }

        let targetWet = settings.isEnabled ? 1.0 : 0.0
        smoothedWet += wetRampAlpha * (targetWet - smoothedWet)

        let outL = delayedDryL + smoothedWet * (processedL - delayedDryL)
        let outR = delayedDryR + smoothedWet * (processedR - delayedDryR)
        return (Float(outL), Float(outR))
    }
}
