import Foundation
import XCTest
@testable import StreameroCore

final class EqualizerTests: XCTestCase {
    let fs = 44_100.0

    private func sine(_ freq: Double, seconds: Double = 0.5, amplitude: Float = 0.25) -> [Float] {
        (0..<Int(fs * seconds)).map { amplitude * Float(sin(2 * Double.pi * freq * Double($0) / fs)) }
    }

    /// RMS level in dB, skipping the filter's start-up transient.
    private func rmsDB(_ x: [Float]) -> Double {
        let tail = x.dropFirst(x.count / 4)
        let ms = tail.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(tail.count)
        return 10 * log10(ms)
    }

    private func gainDB(_ settings: EqualizerSettings, at freq: Double) -> Double {
        var p = EqualizerProcessor(settings: settings, sampleRate: fs)
        let input = sine(freq)
        var output = input
        p.process(&output)
        return rmsDB(output) - rmsDB(input)
    }

    func testFlatIsIdentity() {
        var settings = EqualizerSettings(enabled: true, preset: .flat)
        settings.preamp = 0
        var p = EqualizerProcessor(settings: settings, sampleRate: fs)
        XCTAssertTrue(p.sections.isEmpty)
        let input = sine(440)
        var output = input
        p.process(&output)
        for (a, b) in zip(input, output) { XCTAssertEqual(a, b, accuracy: 1e-6) }
    }

    func testDisabledIsIdentityWhateverTheCurve() {
        let settings = EqualizerSettings(enabled: false, preset: .rock, preamp: -6)
        XCTAssertEqual(gainDB(settings, at: 60), 0, accuracy: 0.01)
        XCTAssertEqual(EqualizerDesign.preampGain(for: settings), 1)
    }

    func testPeakingBoostAtOneKilohertz() {
        var settings = EqualizerSettings(enabled: true)
        settings.setGain(12, forBand: 5) // 1 kHz
        XCTAssertEqual(settings.preset, .custom)
        XCTAssertEqual(gainDB(settings, at: 1000), 12, accuracy: 0.5)
        XCTAssertEqual(gainDB(settings, at: 100), 0, accuracy: 1.0, "100 Hz stays roughly unchanged")
        XCTAssertEqual(gainDB(settings, at: 10_000), 0, accuracy: 1.0)
    }

    func testCutAndPreamp() {
        var settings = EqualizerSettings(enabled: true)
        settings.setGain(-12, forBand: 5)
        XCTAssertEqual(gainDB(settings, at: 1000), -12, accuracy: 0.5)
        settings = EqualizerSettings(enabled: true, preset: .flat, preamp: -6)
        XCTAssertEqual(gainDB(settings, at: 1000), -6, accuracy: 0.05)
    }

    func testShelvesMoveTheExtremes() {
        var settings = EqualizerSettings(enabled: true)
        settings.setGain(9, forBand: 0)
        XCTAssertGreaterThan(gainDB(settings, at: 31), 4, "about half the shelf gain at the corner")
        XCTAssertGreaterThan(gainDB(settings, at: 12), 7)
        XCTAssertEqual(gainDB(settings, at: 2000), 0, accuracy: 0.5)
        settings = EqualizerSettings(enabled: true)
        settings.setGain(9, forBand: 9)
        XCTAssertGreaterThan(gainDB(settings, at: 18_000), 6)
        XCTAssertEqual(gainDB(settings, at: 500), 0, accuracy: 0.5)
    }

    func testAnalyticResponseMatchesProcessor() {
        let settings = EqualizerSettings(enabled: true, preset: .vocal)
        for f in [125.0, 1000, 4000] {
            XCTAssertEqual(EqualizerDesign.responseDB(for: settings, at: f, sampleRate: fs), gainDB(settings, at: f), accuracy: 0.3)
        }
    }

    func testCoefficientsAreStableForAllPresetsAndRates() {
        for rate in [22_050.0, 44_100, 48_000, 96_000] {
            for preset in EqualizerPreset.allCases {
                for c in EqualizerDesign.coefficients(for: EqualizerSettings(enabled: true, preset: preset), sampleRate: rate) {
                    // Poles inside the unit circle: |a2| < 1 and |a1| < 1 + a2.
                    XCTAssertLessThan(abs(c.a2), 1, "\(preset) @ \(rate)")
                    XCTAssertLessThan(abs(c.a1), 1 + c.a2, "\(preset) @ \(rate)")
                    XCTAssertTrue([c.b0, c.b1, c.b2, c.a1, c.a2].allSatisfy(\.isFinite))
                }
            }
        }
    }

    func testPresetsAndClamping() {
        XCTAssertEqual(EqualizerPreset.allCases.map(\.title), ["Flat", "Bass Boost", "Treble Boost", "Vocal", "Rock", "Pop", "Electronic", "Acoustic", "Loudness", "Custom"])
        for p in EqualizerPreset.allCases where p != .custom {
            XCTAssertEqual(p.gains?.count, 10, p.title)
            XCTAssertTrue(p.gains!.allSatisfy { abs($0) <= 12 })
        }
        XCTAssertNil(EqualizerPreset.custom.gains)
        var s = EqualizerSettings(enabled: true)
        s.apply(.bassBoost)
        XCTAssertEqual(s.gains, EqualizerPreset.bassBoost.gains)
        XCTAssertEqual(s.preamp, -3)
        s.setGain(40, forBand: 2)
        XCTAssertEqual(s.gains[2], 12)
        s.preamp = -99
        XCTAssertEqual(s.preamp, -12)
        XCTAssertEqual(EqualizerSettings(gains: [1, 2]).gains.count, 10)
        XCTAssertEqual(EqualizerDesign.bandFrequencies, [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000])
        XCTAssertEqual(EqualizerDesign.label(5), "1k")
        XCTAssertEqual(EqualizerDesign.label(0), "31")
    }

    func testSettingsDecodeLeniently() throws {
        let s = try JSONDecoder().decode(EqualizerSettings.self, from: Data(#"{"enabled":true,"preset":"rock","gains":[1,2,3,99]}"#.utf8))
        XCTAssertTrue(s.enabled)
        XCTAssertEqual(s.preset, .rock)
        XCTAssertEqual(s.gains, [1, 2, 3, 12, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(s.preamp, 0)
        let empty = try JSONDecoder().decode(EqualizerSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(empty, EqualizerSettings())
        let round = try JSONDecoder().decode(EqualizerSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(round, s)
    }

    func testProcessingInChunksMatchesOneShot() {
        let settings = EqualizerSettings(enabled: true, preset: .electronic)
        let input = sine(250, seconds: 0.1)
        var whole = input
        var a = EqualizerProcessor(settings: settings, sampleRate: fs)
        a.process(&whole)
        var b = EqualizerProcessor(settings: settings, sampleRate: fs)
        var chunked: [Float] = []
        var i = 0
        while i < input.count {
            var chunk = Array(input[i..<min(i + 512, input.count)])
            b.process(&chunk)
            chunked += chunk
            i += 512
        }
        for (x, y) in zip(whole, chunked) { XCTAssertEqual(x, y, accuracy: 1e-6) }
    }

    func testCompactCounts() {
        XCTAssertEqual(Format.compact(950), "950")
        XCTAssertEqual(Format.compact(7_920_000), "7.92M")
        XCTAssertEqual(Format.compact(23_100_000), "23.1M")
        XCTAssertEqual(Format.compact(118_000_000), "118M")
        XCTAssertEqual(Format.compact(3_600_000_000), "3.6B")
        XCTAssertEqual(Format.compact(180_000_000_000), "180B")
        XCTAssertEqual(Format.compact(1_000), "1K")
        XCTAssertEqual(Format.compact(999_999), "1M")
    }
}
