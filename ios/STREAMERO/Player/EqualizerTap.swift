import AVFoundation
import MediaToolbox
import os
import StreameroCore

// Realtime 10-band equaliser for music playback.
//
// Every music AVPlayerItem (both decks; local downloads and progressive HTTP AAC/ALAC streams) gets an
// AVMutableAudioMix whose input parameters carry an MTAudioProcessingTap. The tap runs the cascaded
// biquads from StreameroCore (`EqualizerDesign.process`, Direct Form II Transposed, RBJ coefficients)
// on the Float32 non-interleaved buffers AVFoundation hands it.
//
// Thread safety: the main thread writes the user's settings into `EqualizerParameters` under an
// os_unfair_lock. The render callback only ever *tries* that lock (never blocks); when it gets it and the
// generation changed, it copies the ten gains into preallocated memory and recomputes coefficients there.
// No allocation, no blocking and no Objective-C messaging happen on the render thread.
//
// Not covered: HLS video audio (the tap API does not apply to HLS renditions; the "Listen" audio of a
// video plays without EQ) and AirPlay (audio is sent before taps apply).

/// Settings shared by every tap (written on the main thread, read by render threads).
final class EqualizerParameters: @unchecked Sendable {
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private let gains: UnsafeMutablePointer<Double>
    private var preamp: Double = 0
    private var enabled = false
    private var generation: UInt64 = 1

    init() {
        lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
        gains = UnsafeMutablePointer<Double>.allocate(capacity: EqualizerDesign.bandCount)
        gains.initialize(repeating: 0, count: EqualizerDesign.bandCount)
    }

    deinit {
        gains.deinitialize(count: EqualizerDesign.bandCount)
        gains.deallocate()
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    /// Main thread.
    func update(_ settings: EqualizerSettings, active: Bool) {
        let values = settings.gains
        os_unfair_lock_lock(lock)
        for i in 0..<EqualizerDesign.bandCount { gains[i] = i < values.count ? values[i] : 0 }
        preamp = settings.preamp
        enabled = active && settings.enabled
        generation &+= 1
        os_unfair_lock_unlock(lock)
    }

    /// Render thread: copies the parameters if they changed since `seen`. Never blocks: when the main
    /// thread holds the lock this returns `nil` and the caller keeps its current coefficients.
    func tryCopy(ifNewerThan seen: UInt64, gains out: UnsafeMutablePointer<Double>, preamp outPreamp: inout Double, enabled outEnabled: inout Bool) -> UInt64? {
        guard os_unfair_lock_trylock(lock) else { return nil }
        defer { os_unfair_lock_unlock(lock) }
        guard generation != seen else { return nil }
        for i in 0..<EqualizerDesign.bandCount { out[i] = gains[i] }
        outPreamp = preamp
        outEnabled = enabled
        return generation
    }
}

/// Per-tap state: filter memory and coefficients for one AVPlayerItem. All buffers are allocated up front.
final class EqualizerTapContext: @unchecked Sendable {
    static let maxChannels = 8
    private static let bands = EqualizerDesign.bandCount

    let parameters: EqualizerParameters
    private let sections: UnsafeMutablePointer<BiquadCoefficients>
    private let state: UnsafeMutablePointer<Double>
    private let gains: UnsafeMutablePointer<Double>
    private var preamp: Double = 0
    private var preampGain: Float = 1
    private var enabled = false
    private var seenGeneration: UInt64 = 0
    private var sampleRate: Double = 44_100
    private var supportedFormat = false
    private var needsRecompute = true

    init(parameters: EqualizerParameters) {
        self.parameters = parameters
        sections = UnsafeMutablePointer<BiquadCoefficients>.allocate(capacity: Self.bands)
        sections.initialize(repeating: .identity, count: Self.bands)
        state = UnsafeMutablePointer<Double>.allocate(capacity: Self.maxChannels * Self.bands * 2)
        state.initialize(repeating: 0, count: Self.maxChannels * Self.bands * 2)
        gains = UnsafeMutablePointer<Double>.allocate(capacity: Self.bands)
        gains.initialize(repeating: 0, count: Self.bands)
    }

    deinit {
        sections.deinitialize(count: Self.bands)
        sections.deallocate()
        state.deinitialize(count: Self.maxChannels * Self.bands * 2)
        state.deallocate()
        gains.deinitialize(count: Self.bands)
        gains.deallocate()
    }

    /// Called by the tap's prepare callback whenever the processing format is (re)established.
    func prepare(_ format: AudioStreamBasicDescription) {
        let flags = format.mFormatFlags
        supportedFormat = format.mFormatID == kAudioFormatLinearPCM
            && (flags & kAudioFormatFlagIsFloat) != 0
            && (flags & kAudioFormatFlagIsNonInterleaved) != 0
            && format.mBitsPerChannel == 32
        if format.mSampleRate > 0 { sampleRate = format.mSampleRate }
        resetState()
        needsRecompute = true
    }

    func resetState() {
        for i in 0..<(Self.maxChannels * Self.bands * 2) { state[i] = 0 }
    }

    /// Render thread.
    func process(_ bufferList: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
        if let g = parameters.tryCopy(ifNewerThan: seenGeneration, gains: gains, preamp: &preamp, enabled: &enabled) {
            if seenGeneration != 0 && !enabled { resetState() }
            seenGeneration = g
            needsRecompute = true
        }
        if needsRecompute {
            // All ten sections are always present (identity when a band is flat) so filter memory keeps
            // its meaning while the user drags a slider: no clicks from re-indexed state.
            for b in 0..<Self.bands {
                sections[b] = EqualizerDesign.band(b, gainDB: gains[b], sampleRate: sampleRate)
            }
            preampGain = Float(pow(10, min(12, max(-12, preamp)) / 20))
            needsRecompute = false
        }
        guard enabled, supportedFormat, frames > 0 else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        let channelCount = min(buffers.count, Self.maxChannels)
        for ch in 0..<channelCount {
            let buffer = buffers[ch]
            guard let data = buffer.mData else { continue }
            let count = min(frames, Int(buffer.mDataByteSize) / MemoryLayout<Float>.size)
            EqualizerDesign.process(data.assumingMemoryBound(to: Float.self), count: count,
                                    sections: UnsafePointer(sections), sectionCount: Self.bands,
                                    state: state + ch * Self.bands * 2, gain: preampGain)
        }
    }
}

// MARK: - MTAudioProcessingTap callbacks (C function pointers: no captures)

private func equalizerContext(_ tap: MTAudioProcessingTap) -> EqualizerTapContext? {
    let raw: UnsafeMutableRawPointer? = MTAudioProcessingTapGetStorage(tap)
    guard let raw else { return nil }
    return Unmanaged<EqualizerTapContext>.fromOpaque(raw).takeUnretainedValue()
}

private let equalizerTapInit: MTAudioProcessingTapInitCallback = { _, clientInfo, tapStorageOut in
    // clientInfo is the retained EqualizerTapContext; it becomes the tap's storage.
    tapStorageOut.pointee = clientInfo
}

private let equalizerTapFinalize: MTAudioProcessingTapFinalizeCallback = { tap in
    let raw: UnsafeMutableRawPointer? = MTAudioProcessingTapGetStorage(tap)
    guard let raw else { return }
    Unmanaged<EqualizerTapContext>.fromOpaque(raw).release()
}

private let equalizerTapPrepare: MTAudioProcessingTapPrepareCallback = { tap, _, processingFormat in
    equalizerContext(tap)?.prepare(processingFormat.pointee)
}

private let equalizerTapUnprepare: MTAudioProcessingTapUnprepareCallback = { tap in
    equalizerContext(tap)?.resetState()
}

private let equalizerTapProcess: MTAudioProcessingTapProcessCallback = { tap, numberFrames, _, bufferListInOut, numberFramesOut, flagsOut in
    let status = MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut, flagsOut, nil, numberFramesOut)
    guard status == noErr else { return }
    equalizerContext(tap)?.process(bufferListInOut, frames: Int(numberFramesOut.pointee))
}

// MARK: - Engine

/// Owns the shared parameters and attaches taps to player items. Main actor.
@MainActor
final class EqualizerEngine {
    let parameters = EqualizerParameters()

    private(set) var settings: EqualizerSettings
    /// Remote config switch (`features.equalizer`); off means bypass regardless of the user setting.
    var featureEnabled = true { didSet { if featureEnabled != oldValue { push() } } }

    init(settings: EqualizerSettings) {
        self.settings = settings
        push()
    }

    func update(_ settings: EqualizerSettings) {
        self.settings = settings
        push()
    }

    private func push() { parameters.update(settings, active: featureEnabled) }

    /// Adds the EQ tap to the item's audio track. Safe to call while the item plays (the mix applies
    /// from the next render cycle). Items without a loadable audio track (e.g. HLS) are left untouched.
    func attach(to item: AVPlayerItem) async {
        guard item.audioMix == nil else { return }
        let asset = item.asset
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio), let track = tracks.first,
              let tap = makeTap() else { return }
        let input = AVMutableAudioMixInputParameters(track: track)
        input.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [input]
        item.audioMix = mix
    }

    private func makeTap() -> MTAudioProcessingTap? {
        let context = EqualizerTapContext(parameters: parameters)
        let clientInfo = Unmanaged.passRetained(context).toOpaque()
        var callbacks = MTAudioProcessingTapCallbacks(
            version: Int32(kMTAudioProcessingTapCallbacksVersion_0),
            clientInfo: clientInfo,
            init: equalizerTapInit,
            finalize: equalizerTapFinalize,
            prepare: equalizerTapPrepare,
            unprepare: equalizerTapUnprepare,
            process: equalizerTapProcess)
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks,
                                                MTAudioProcessingTapCreationFlags(kMTAudioProcessingTapCreationFlag_PreEffects), &tap)
        guard status == noErr, let tap else {
            // init never ran, so nothing owns the context: balance passRetained here.
            Unmanaged<EqualizerTapContext>.fromOpaque(clientInfo).release()
            return nil
        }
        return tap
    }
}
