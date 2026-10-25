import Foundation

// MARK: - Biquad maths (RBJ Audio EQ Cookbook)

/// Normalised biquad coefficients (a0 == 1). Difference equation:
/// y[n] = b0·x[n] + b1·x[n-1] + b2·x[n-2] − a1·y[n-1] − a2·y[n-2]
public struct BiquadCoefficients: Sendable, Equatable {
    public var b0: Double
    public var b1: Double
    public var b2: Double
    public var a1: Double
    public var a2: Double

    public init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        self.b0 = b0; self.b1 = b1; self.b2 = b2; self.a1 = a1; self.a2 = a2
    }

    /// Pass-through section.
    public static let identity = BiquadCoefficients(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)

    public var isIdentity: Bool { b0 == 1 && b1 == 0 && b2 == 0 && a1 == 0 && a2 == 0 }

    private static func normalised(_ b0: Double, _ b1: Double, _ b2: Double, _ a0: Double, _ a1: Double, _ a2: Double) -> BiquadCoefficients {
        BiquadCoefficients(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }

    /// Keeps the centre frequency safely below Nyquist (and above 0) for any sample rate.
    private static func omega(_ frequency: Double, _ sampleRate: Double) -> Double {
        let f = min(max(frequency, 1), sampleRate * 0.45)
        return 2 * Double.pi * f / sampleRate
    }

    /// Peaking EQ. `q` ≈ 1.41 is one octave wide.
    public static func peaking(frequency: Double, gainDB: Double, q: Double, sampleRate: Double) -> BiquadCoefficients {
        guard gainDB != 0, sampleRate > 0 else { return .identity }
        let a = pow(10, gainDB / 40)
        let w0 = omega(frequency, sampleRate)
        let cosW = cos(w0)
        let alpha = sin(w0) / (2 * q)
        return normalised(1 + alpha * a, -2 * cosW, 1 - alpha * a, 1 + alpha / a, -2 * cosW, 1 - alpha / a)
    }

    /// Low shelf with slope S = 1.
    public static func lowShelf(frequency: Double, gainDB: Double, sampleRate: Double) -> BiquadCoefficients {
        guard gainDB != 0, sampleRate > 0 else { return .identity }
        let a = pow(10, gainDB / 40)
        let w0 = omega(frequency, sampleRate)
        let cosW = cos(w0)
        let alpha = sin(w0) / 2 * sqrt(2) // S = 1
        let twoSqrtAAlpha = 2 * sqrt(a) * alpha
        return normalised(a * ((a + 1) - (a - 1) * cosW + twoSqrtAAlpha),
                          2 * a * ((a - 1) - (a + 1) * cosW),
                          a * ((a + 1) - (a - 1) * cosW - twoSqrtAAlpha),
                          (a + 1) + (a - 1) * cosW + twoSqrtAAlpha,
                          -2 * ((a - 1) + (a + 1) * cosW),
                          (a + 1) + (a - 1) * cosW - twoSqrtAAlpha)
    }

    /// High shelf with slope S = 1.
    public static func highShelf(frequency: Double, gainDB: Double, sampleRate: Double) -> BiquadCoefficients {
        guard gainDB != 0, sampleRate > 0 else { return .identity }
        let a = pow(10, gainDB / 40)
        let w0 = omega(frequency, sampleRate)
        let cosW = cos(w0)
        let alpha = sin(w0) / 2 * sqrt(2)
        let twoSqrtAAlpha = 2 * sqrt(a) * alpha
        return normalised(a * ((a + 1) + (a - 1) * cosW + twoSqrtAAlpha),
                          -2 * a * ((a - 1) + (a + 1) * cosW),
                          a * ((a + 1) + (a - 1) * cosW - twoSqrtAAlpha),
                          (a + 1) - (a - 1) * cosW + twoSqrtAAlpha,
                          2 * ((a - 1) - (a + 1) * cosW),
                          (a + 1) - (a - 1) * cosW - twoSqrtAAlpha)
    }

    /// Magnitude response in dB at `frequency`.
    public func magnitudeDB(at frequency: Double, sampleRate: Double) -> Double {
        let w = 2 * Double.pi * frequency / sampleRate
        let c1 = cos(w), s1 = sin(w), c2 = cos(2 * w), s2 = sin(2 * w)
        let nr = b0 + b1 * c1 + b2 * c2, ni = -(b1 * s1 + b2 * s2)
        let dr = 1 + a1 * c1 + a2 * c2, di = -(a1 * s1 + a2 * s2)
        let mag = sqrt((nr * nr + ni * ni) / (dr * dr + di * di))
        return 20 * log10(max(mag, 1e-12))
    }
}

// MARK: - 10-band graphic equaliser design

public enum EqualizerDesign {
    public static let bandFrequencies: [Double] = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    public static let bandCount = 10
    public static let gainRange: ClosedRange<Double> = -12...12
    public static let preampRange: ClosedRange<Double> = -12...12
    /// One octave between band centres.
    public static let q = 1.41

    /// Band label: "31", "1k", "16k".
    public static func label(_ index: Int) -> String {
        let f = bandFrequencies[index]
        return f >= 1000 ? "\(Int(f / 1000))k" : "\(Int(f))"
    }

    /// Coefficients for one band (no allocation, safe to call from an audio render thread).
    /// The outermost bands are shelves so the extremes of the spectrum move as a whole.
    public static func band(_ index: Int, gainDB: Double, sampleRate: Double) -> BiquadCoefficients {
        guard index >= 0, index < bandCount else { return .identity }
        let g = min(max(gainDB, gainRange.lowerBound), gainRange.upperBound)
        if abs(g) < 0.01 { return .identity }
        let f = bandFrequencies[index]
        switch index {
        case 0: return .lowShelf(frequency: f, gainDB: g, sampleRate: sampleRate)
        case bandCount - 1: return .highShelf(frequency: f, gainDB: g, sampleRate: sampleRate)
        default: return .peaking(frequency: f, gainDB: g, q: q, sampleRate: sampleRate)
        }
    }

    /// All active sections for `settings` (identity sections are skipped). Empty when the EQ is off.
    public static func coefficients(for settings: EqualizerSettings, sampleRate: Double) -> [BiquadCoefficients] {
        guard settings.enabled else { return [] }
        return settings.gains.indices.map { band($0, gainDB: settings.gains[$0], sampleRate: sampleRate) }.filter { !$0.isIdentity }
    }

    /// Linear preamp gain (1 when the EQ is off).
    public static func preampGain(for settings: EqualizerSettings) -> Float {
        guard settings.enabled else { return 1 }
        return Float(pow(10, min(max(settings.preamp, preampRange.lowerBound), preampRange.upperBound) / 20))
    }

    /// Combined magnitude response of the whole EQ (preamp included) in dB, for drawing the curve.
    public static func responseDB(for settings: EqualizerSettings, at frequency: Double, sampleRate: Double = 48000) -> Double {
        guard settings.enabled else { return 0 }
        let bands = coefficients(for: settings, sampleRate: sampleRate).reduce(0) { $0 + $1.magnitudeDB(at: frequency, sampleRate: sampleRate) }
        return bands + settings.preamp
    }

    /// Runs a cascade of biquads over one channel in place (Direct Form II Transposed, Double state).
    /// `state` must hold `2 * sectionCount` values and persists between calls. Allocation- and lock-free,
    /// so the app's audio tap calls exactly this on the render thread.
    public static func process(_ samples: UnsafeMutablePointer<Float>, count: Int,
                               sections: UnsafePointer<BiquadCoefficients>, sectionCount: Int,
                               state: UnsafeMutablePointer<Double>, gain: Float) {
        guard count > 0 else { return }
        if gain != 1 {
            for i in 0..<count { samples[i] *= gain }
        }
        guard sectionCount > 0 else { return }
        for s in 0..<sectionCount {
            let c = sections[s]
            var z1 = state[2 * s], z2 = state[2 * s + 1]
            for i in 0..<count {
                let x = Double(samples[i])
                let y = c.b0 * x + z1
                z1 = c.b1 * x - c.a1 * y + z2
                z2 = c.b2 * x - c.a2 * y
                samples[i] = Float(y)
            }
            // Flush denormals so silence after loud passages doesn't cost CPU.
            if abs(z1) < 1e-25 { z1 = 0 }
            if abs(z2) < 1e-25 { z2 = 0 }
            state[2 * s] = z1
            state[2 * s + 1] = z2
        }
    }
}

// MARK: - Presets & persisted settings

public enum EqualizerPreset: String, Codable, Sendable, CaseIterable, Identifiable {
    case flat, bassBoost, trebleBoost, vocal, rock, pop, electronic, acoustic, loudness, custom

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .flat: "Flat"
        case .bassBoost: "Bass Boost"
        case .trebleBoost: "Treble Boost"
        case .vocal: "Vocal"
        case .rock: "Rock"
        case .pop: "Pop"
        case .electronic: "Electronic"
        case .acoustic: "Acoustic"
        case .loudness: "Loudness"
        case .custom: "Custom"
        }
    }

    /// Band gains in dB for 31 Hz … 16 kHz; `nil` for Custom (the user's own curve).
    public var gains: [Double]? {
        switch self {
        case .flat: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        case .bassBoost: [6, 5, 4, 2.5, 1, 0, 0, 0, 0, 0]
        case .trebleBoost: [0, 0, 0, 0, 0, 1, 2.5, 4, 5, 6]
        case .vocal: [-2, -2, -1, 1, 3, 4, 3.5, 2, 0, -1]
        case .rock: [5, 4, 3, 1, -1, -1, 1, 3, 4, 5]
        case .pop: [-1, 0, 2, 3.5, 4, 3, 1, 0, -1, -1]
        case .electronic: [5, 4.5, 1.5, 0, -2, 1.5, 1, 1.5, 4, 5]
        case .acoustic: [4, 4, 3, 1, 2, 2, 3, 3.5, 3, 2]
        case .loudness: [6, 5, 2, 0, -1, 0, 0, 1, 4, 5]
        case .custom: nil
        }
    }

    /// Preamp that keeps headroom for the preset's boosts (half the largest boost, negative).
    public var suggestedPreamp: Double {
        guard let g = gains, let top = g.max(), top > 0 else { return 0 }
        return -(top / 2).rounded()
    }

    /// The presets shown in the picker (Custom appears once the user edits a band).
    public static let selectable: [EqualizerPreset] = allCases
}

public struct EqualizerSettings: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var preset: EqualizerPreset
    /// Ten band gains in dB (always exactly `EqualizerDesign.bandCount` values within ±12).
    public var gains: [Double] { didSet { gains = EqualizerSettings.sanitised(gains) } }
    public var preamp: Double { didSet { preamp = min(max(preamp, EqualizerDesign.preampRange.lowerBound), EqualizerDesign.preampRange.upperBound) } }

    public init(enabled: Bool = false, preset: EqualizerPreset = .flat, gains: [Double]? = nil, preamp: Double = 0) {
        self.enabled = enabled
        self.preset = preset
        self.gains = EqualizerSettings.sanitised(gains ?? preset.gains ?? [])
        self.preamp = min(max(preamp, EqualizerDesign.preampRange.lowerBound), EqualizerDesign.preampRange.upperBound)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let enabled = c.lenient(Bool.self, .enabled) ?? false
        let preset = c.lenient(String.self, .preset).flatMap(EqualizerPreset.init(rawValue:)) ?? .flat
        let gains = c.lenient([Double].self, .gains)
        let preamp = c.lenient(Double.self, .preamp) ?? 0
        self.init(enabled: enabled, preset: preset, gains: gains, preamp: preamp)
    }

    static func sanitised(_ values: [Double]) -> [Double] {
        (0..<EqualizerDesign.bandCount).map { i in
            let v = i < values.count && values[i].isFinite ? values[i] : 0
            return min(max(v, EqualizerDesign.gainRange.lowerBound), EqualizerDesign.gainRange.upperBound)
        }
    }

    /// Selects a preset: loads its curve and a matching preamp. Custom keeps the current curve.
    public mutating func apply(_ preset: EqualizerPreset) {
        self.preset = preset
        if let g = preset.gains {
            gains = g
            preamp = preset.suggestedPreamp
        }
    }

    /// Changes one band; the curve becomes Custom unless it still matches the selected preset.
    public mutating func setGain(_ value: Double, forBand index: Int) {
        guard gains.indices.contains(index) else { return }
        gains[index] = value
        if preset.gains != gains { preset = .custom }
    }

    /// True when the EQ would change the signal.
    public var isActive: Bool { enabled && (preamp != 0 || gains.contains { abs($0) >= 0.01 }) }
}

// MARK: - Reference processor

/// Plain-Swift reference implementation over `[Float]` (one channel). Used by tests and as the
/// specification for the realtime tap, which runs the same `EqualizerDesign.process` kernel.
public struct EqualizerProcessor: Sendable {
    public private(set) var sections: [BiquadCoefficients]
    public private(set) var gain: Float
    private var state: [Double]

    public init(settings: EqualizerSettings, sampleRate: Double) {
        sections = EqualizerDesign.coefficients(for: settings, sampleRate: sampleRate)
        gain = EqualizerDesign.preampGain(for: settings)
        state = Array(repeating: 0, count: max(1, sections.count * 2))
    }

    public mutating func reset() { state = Array(repeating: 0, count: state.count) }

    public mutating func process(_ samples: inout [Float]) {
        let count = samples.count
        let gain = self.gain
        sections.withUnsafeBufferPointer { secs in
            state.withUnsafeMutableBufferPointer { st in
                samples.withUnsafeMutableBufferPointer { buf in
                    guard let base = buf.baseAddress, let s = secs.baseAddress, let z = st.baseAddress else {
                        if let base = buf.baseAddress, gain != 1 { for i in 0..<count { base[i] *= gain } }
                        return
                    }
                    EqualizerDesign.process(base, count: count, sections: s, sectionCount: secs.count, state: z, gain: gain)
                }
            }
        }
    }
}
