// Ideal Video Encoder for macOS
// https://github.com/alex-mcdermott/Ideal-Video-Encoder
// Copyright (C) 2026 the Ideal Video Encoder contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import AVFoundation
import CoreMedia
import Foundation
import MediaToolbox

/// The preview's timeline for a speed change and replacement music (Windows v1.3.0), matching the encode:
/// the video (and the clip's own audio, pitch-preserved at playback) is time-scaled by 1/speed, so slowed
/// high-frame-rate footage shows every frame; music is not time-stretched, and loops to fill the clip.
public enum PreviewTimeline {
    /// The asset to play: the source itself at 1x without music, otherwise a composition. Music starts at
    /// `musicFrom` (the start of the preview's loop, as the encode starts it at the trim start).
    public static func make(source: AVAsset, speed: Double, music: URL?, musicFrom: CMTime = .zero) async throws -> AVAsset {
        if SpeedAudio.isNormal(speed) && music == nil { return source }
        let comp = AVMutableComposition()
        let duration = try await source.load(.duration)
        let full = CMTimeRange(start: .zero, duration: duration)
        let scaled = CMTimeMultiplyByFloat64(duration, multiplier: 1 / speed)
        guard let v = try await source.loadTracks(withMediaType: .video).first,
              let cv = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ProcessError("the clip has no video track")
        }
        try cv.insertTimeRange(full, of: v, at: .zero)
        cv.preferredTransform = try await v.load(.preferredTransform)
        if !SpeedAudio.isNormal(speed) { cv.scaleTimeRange(full, toDuration: scaled) }

        if let music {
            let m = AVURLAsset(url: music)
            if let ma = try await m.loadTracks(withMediaType: .audio).first,
               let ca = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                let md = try await m.load(.duration)
                guard md.seconds > 0.01 else { return comp }
                var at = CMTimeMaximum(.zero, CMTimeMinimum(musicFrom, scaled))
                while at < scaled {   // loop the music to cover the clip (-stream_loop -1), cut at its end
                    let piece = CMTimeMinimum(md, scaled - at)
                    try ca.insertTimeRange(CMTimeRange(start: .zero, duration: piece), of: ma, at: at)
                    at = at + piece
                }
            }
        } else if let a = try await source.loadTracks(withMediaType: .audio).first,
                  let ca = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try ca.insertTimeRange(full, of: a, at: .zero)
            if !SpeedAudio.isNormal(speed) { ca.scaleTimeRange(full, toDuration: scaled) }
        }
        return comp
    }

    /// Audio mix for the preview: the loudness gain (always attached, 0 dB when normalising is off) and, with
    /// music, a fade-out over the last min(2 s, a quarter) of the loop, as the encode fades the end of the output.
    public static func audioMix(for asset: AVAsset, gain: LoudnessGain, fadeOutEnding loop: CMTimeRange?) async -> AVAudioMix? {
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first else { return nil }
        let p = AVMutableAudioMixInputParameters(track: track)
        p.audioTapProcessor = gain.makeTap()
        if let loop, loop.duration.seconds > 0 {
            let fade = min(2.0, loop.duration.seconds / 4)
            let start = loop.end - CMTime(seconds: fade, preferredTimescale: 600)
            p.setVolume(1, at: .zero)
            p.setVolumeRamp(fromStartVolume: 1, toEndVolume: 0, timeRange: CMTimeRange(start: start, end: loop.end))
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = [p]
        return mix
    }
}

/// A gain applied to the preview's audio through an MTAudioProcessingTap. Normalising measures the source with
/// the same loudnorm first pass as the encode, then plays it at gain = -16 LUFS - measured, with peaks limited to
/// -1.5 dBTP; the gain can change while playing.
public final class LoudnessGain: @unchecked Sendable {
    private let lock = NSLock()
    private var _linear: Float = 1
    private var _frames = 0
    fileprivate var isFloat32 = false
    /// -1.5 dBTP, the encode's true-peak target
    static let peak: Float = powf(10, -1.5 / 20)

    public init() {}

    /// Gain in dB (0 = unchanged).
    public var decibels: Double {
        get { lock.lock(); defer { lock.unlock() }; return 20 * log10(Double(_linear)) }
        set { lock.lock(); _linear = Float(pow(10, newValue / 20)); lock.unlock() }
    }

    fileprivate var linear: Float { lock.lock(); defer { lock.unlock() }; return _linear }

    /// Audio frames that have passed through the tap (to check it runs on every loop).
    public var processedFrames: Int { lock.lock(); defer { lock.unlock() }; return _frames }
    fileprivate func count(_ n: Int) { lock.lock(); _frames += n; lock.unlock() }

    /// The gain that brings a measured integrated loudness to -16 LUFS (clamped to +-50 dB; silence -> 0 dB).
    public static func decibels(toTarget measuredLUFS: Double?) -> Double {
        guard let m = measuredLUFS, m.isFinite, m > -70 else { return 0 }
        return min(50, max(-50, -16 - m))
    }

    public func makeTap() -> MTAudioProcessingTap? {
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: Unmanaged.passRetained(self).toOpaque(),
            init: { _, clientInfo, storageOut in storageOut.pointee = clientInfo },
            finalize: { tap in Unmanaged<LoudnessGain>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release() },
            prepare: { tap, _, format in
                let box = Unmanaged<LoudnessGain>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                let f = format.pointee
                box.isFloat32 = f.mFormatID == kAudioFormatLinearPCM && (f.mFormatFlags & kAudioFormatFlagIsFloat) != 0 && f.mBitsPerChannel == 32
            },
            unprepare: nil,
            process: { tap, frames, _, bufferList, framesOut, flagsOut in
                guard MTAudioProcessingTapGetSourceAudio(tap, frames, bufferList, flagsOut, nil, framesOut) == noErr else { return }
                let box = Unmanaged<LoudnessGain>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                box.count(framesOut.pointee)
                let g = box.linear
                guard box.isFloat32, g != 1 else { return }
                let limit = LoudnessGain.peak
                for buffer in UnsafeMutableAudioBufferListPointer(bufferList) {
                    guard let data = buffer.mData else { continue }
                    let n = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                    let s = data.assumingMemoryBound(to: Float.self)
                    for i in 0..<n { s[i] = max(-limit, min(limit, s[i] * g)) }
                }
            })
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
        if status != noErr { Unmanaged<LoudnessGain>.fromOpaque(callbacks.clientInfo!).release(); return nil }
        return tap
    }
}

/// Renders a preview timeline's audio (with its audio mix) to a WAV file, for tests and checks.
public enum PreviewAudioRender {
    public static func render(_ asset: AVAsset, mix: AVAudioMix?, timeRange: CMTimeRange? = nil, channels: Int = 2, to url: URL) async throws {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw ProcessError("no audio") }
        let reader = try AVAssetReader(asset: asset)
        if let timeRange { reader.timeRange = timeRange }
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                                       AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false, AVSampleRateKey: 48000, AVNumberOfChannelsKey: channels]
        let out = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: settings)
        out.audioMix = mix
        out.audioTimePitchAlgorithm = .spectral
        reader.add(out)
        try? FileManager.default.removeItem(at: url)
        let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: channels,
                                                               AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true],
                                   commonFormat: .pcmFormatFloat32, interleaved: true)
        guard reader.startReading() else { throw reader.error ?? ProcessError("reader failed") }
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: AVAudioChannelCount(channels), interleaved: true)!
        while let sb = out.copyNextSampleBuffer() {
            let n = AVAudioFrameCount(CMSampleBufferGetNumSamples(sb))
            guard n > 0, let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n) else { continue }
            buf.frameLength = n
            guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0, frameCount: Int32(n), into: buf.mutableAudioBufferList) == noErr else { continue }
            try file.write(from: buf)
        }
        if reader.status == .failed { throw reader.error ?? ProcessError("reader failed") }
    }
}
