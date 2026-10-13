// Ideal Video Encoder for macOS
// https://github.com/alex-mcdermott/Ideal-Video-Encoder
// Copyright (C) 2026 the Ideal Video Encoder contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import AVFoundation
import CoreImage
import Foundation
import QuartzCore
import VideoToolbox

public enum PreviewSource {
    /// Whether AVFoundation can decode the clip's video (hardware or software). "hev1"-tagged HEVC,
    /// for example, opens but can't be decoded, so this checks with VideoToolbox, not just `isPlayable`.
    public static func canDecode(_ asset: AVAsset) async -> Bool {
        guard let playable = try? await asset.load(.isPlayable), playable,
              let track = try? await asset.loadTracks(withMediaType: .video).first,
              let desc = try? await track.load(.formatDescriptions).first else { return false }
        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(allocator: nil, formatDescription: desc, decoderSpecification: nil,
                                                  imageBufferAttributes: nil, outputCallback: nil, decompressionSessionOut: &session)
        if let session { VTDecompressionSessionInvalidate(session) }
        return status == noErr
    }

    /// ffmpeg arguments for a preview proxy: 1080p 10-bit HEVC (hardware encoder), limited range, BT.709.
    /// The look is applied at playback, so the proxy carries the untouched picture.
    public static func proxyArguments(source: String, output: String) -> [String] {
        ["-v", "error", "-y", "-nostdin", "-i", source,
         "-vf", "scale=w=1920:h=1080:force_original_aspect_ratio=decrease:out_range=tv:out_color_matrix=bt709,format=p010le",
         "-c:v", "hevc_videotoolbox", "-profile:v", "main10", "-q:v", "70", "-tag:v", "hvc1",
         "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709", "-color_range", "tv",
         "-an", output]
    }

    public static func proxyPath(for source: String) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: source)
        let stamp = "\(source)|\((attrs?[.size] as? NSNumber)?.int64Value ?? 0)|\((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
        var h: UInt64 = 1469598103934665603
        for b in stamp.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("IdealVE-preview")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(String(h, radix: 16) + ".mov").path
    }

    public static func makeProxy(ffmpeg: String, source: String) async throws -> String {
        let out = proxyPath(for: source)
        if FileManager.default.fileExists(atPath: out) { return out }
        let tmp = out + ".part.mov"
        let r = try await ProcessRunner.run(ffmpeg, proxyArguments(source: source, output: tmp))
        guard r.exitCode == 0 else {
            try? FileManager.default.removeItem(atPath: tmp)
            throw ProcessError("could not make a preview proxy: " + (r.stderrText.split(whereSeparator: \.isNewline).last.map(String.init) ?? "exit \(r.exitCode)"))
        }
        try FileManager.default.moveItem(atPath: tmp, toPath: out)
        return out
    }
}

/// Plays a clip through the preview composition for a while and measures throughput.
public enum PlaybackBench {
    public struct Result: Sendable {
        public var wallSeconds: Double
        public var videoSeconds: Double
        public var framesRendered: Int
        public var framesDelivered: Int
        public var frameRate: Double
        public var droppedFrames: Int?
        public var speed: Double { videoSeconds / wallSeconds }
        public var expectedFrames: Double { videoSeconds * frameRate }
    }

    @MainActor
    public static func run(path: String, look: PreviewLook, seconds: Double) async throws -> Result {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let rendered = LockedBox(0)
        let box = LockedBox(look)
        let comp = try await AVMutableVideoComposition.videoComposition(with: asset) { request in
            let l = box.value
            let out = l.isIdentity ? request.sourceImage : l.apply(to: request.sourceImage).cropped(to: request.sourceImage.extent)
            rendered.mutate { $0 += 1 }
            request.finish(with: out, context: PreviewComposition.context)
        }
        let fps = Double(comp.frameDuration.timescale) / Double(max(1, comp.frameDuration.value))
        let item = AVPlayerItem(asset: asset)
        item.videoComposition = comp
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        item.add(output)
        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = false
        while item.status != .readyToPlay {
            if item.status == .failed { throw item.error ?? ProcessError("player failed") }
            try await Task.sleep(for: .milliseconds(20))
        }
        // Pull frames like a display would (120 Hz), counting distinct frames delivered
        // Short clips loop, as in the app; video time advanced is summed across loops
        let duration = try await asset.load(.duration).seconds
        let delivered = LockedBox(0)
        let t0 = CACurrentMediaTime()
        var advanced = 0.0, segmentStart = player.currentTime().seconds
        rendered.mutate { $0 = 0 }
        player.play()
        while CACurrentMediaTime() - t0 < seconds {
            let t = output.itemTime(forHostTime: CACurrentMediaTime())
            if output.hasNewPixelBuffer(forItemTime: t), output.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil) != nil {
                delivered.mutate { $0 += 1 }
            }
            let now = player.currentTime().seconds
            if now >= duration - 0.001 || (player.rate == 0 && now > segmentStart) {
                advanced += now - segmentStart
                await player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
                segmentStart = 0
                player.play()
            }
            try await Task.sleep(for: .milliseconds(8))
        }
        let wall = CACurrentMediaTime() - t0
        let v1 = player.currentTime().seconds
        let v0 = segmentStart - advanced
        player.pause()
        let dropped = item.accessLog()?.events.last.map { $0.numberOfDroppedVideoFrames }
        return Result(wallSeconds: wall, videoSeconds: v1 - v0, framesRendered: rendered.value, framesDelivered: delivered.value,
                      frameRate: fps, droppedFrames: dropped.flatMap { $0 >= 0 ? $0 : nil })
    }
}
