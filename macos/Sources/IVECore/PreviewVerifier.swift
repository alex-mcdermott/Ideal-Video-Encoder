// Ideal Video Encoder for macOS
// https://github.com/alex-mcdermott/Ideal-Video-Encoder
// Copyright (C) 2026 the Ideal Video Encoder contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import AVFoundation
import CoreImage
import Foundation

/// Compares one frame rendered through the preview composition with the same frame rendered by ffmpeg
/// through the encode's filters, in 8-bit RGB.
public enum PreviewVerifier {
    public struct Result: Sendable {
        public var width: Int
        public var height: Int
        /// Mean absolute difference per channel (R, G, B) and overall, in 0-255 units.
        public var mad: [Double]
        public var overall: Double { mad.reduce(0, +) / 3 }
        public var maxDiff: Int
        /// Share of samples differing by more than 2/255.
        public var over2: Double
        public var previewMean: Double
        public var ffmpegMean: Double
    }

    /// Frame `index` (0-based, decode order = display order for these files) through the preview pipeline, as RGB24.
    public static func previewFrame(path: String, index: Int, look: PreviewLook) async throws -> (Data, Int, Int) {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ProcessError("no video track") }
        let comp = try await PreviewComposition.make(asset: asset, look: LockedBox(look))
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderVideoCompositionOutput(videoTracks: [track], videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        out.videoComposition = comp
        out.alwaysCopiesSampleData = false
        reader.add(out)
        guard reader.startReading() else { throw reader.error ?? ProcessError("AVAssetReader failed") }
        var n = 0
        while let sample = out.copyNextSampleBuffer() {
            defer { n += 1 }
            guard n == index, let pb = CMSampleBufferGetImageBuffer(sample) else { continue }
            reader.cancelReading()
            CVPixelBufferLockBaseAddress(pb, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
            let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), stride = CVPixelBufferGetBytesPerRow(pb)
            let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
            var rgb = Data(count: w * h * 3)
            rgb.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
                let d = dst.bindMemory(to: UInt8.self)
                for y in 0..<h {
                    let row = base + y * stride
                    for x in 0..<w {
                        d[(y * w + x) * 3] = row[x * 4 + 2]
                        d[(y * w + x) * 3 + 1] = row[x * 4 + 1]
                        d[(y * w + x) * 3 + 2] = row[x * 4]
                    }
                }
            }
            return (rgb, w, h)
        }
        throw ProcessError("frame \(index) not found (\(n) frames)")
    }

    /// The same frame through ffmpeg: the encode's filters (minus zscale, whose job, range conversion, is
    /// done by the RGB conversion here), converted to RGB using the source's range and BT.709.
    public static func ffmpegArguments(path: String, index: Int, look: PreviewLook, lutPath: String?) -> [String] {
        var vf = FilterChain.filters(exposure: look.exposure, lutPath: lutPath, isFullRange: false)
        vf.insert("select=eq(n\\,\(index))", at: 0)
        if lutPath == nil {
            vf.append("scale=in_color_matrix=bt709:in_range=\(look.isFullRange ? "pc" : "tv"):out_range=pc:flags=accurate_rnd+full_chroma_int")
        }
        vf.append("format=rgb24")
        return ["-v", "error", "-i", path, "-vf", vf.joined(separator: ","), "-frames:v", "1", "-f", "rawvideo", "-"]
    }

    public static func compare(path: String, index: Int, look: PreviewLook, lutPath: String?, ffmpeg: String) async throws -> Result {
        let (p, w, h) = try await previewFrame(path: path, index: index, look: look)
        let r = try await ProcessRunner.run(ffmpeg, ffmpegArguments(path: path, index: index, look: look, lutPath: lutPath))
        guard r.exitCode == 0, r.stdout.count == p.count else {
            throw ProcessError("ffmpeg reference failed (\(r.stdout.count) bytes, wanted \(p.count)): \(r.stderrText)")
        }
        var sums = [0.0, 0.0, 0.0], maxD = 0, over = 0, pm = 0.0, fm = 0.0
        p.withUnsafeBytes { (a: UnsafeRawBufferPointer) in
            r.stdout.withUnsafeBytes { (b: UnsafeRawBufferPointer) in
                for i in 0..<a.count {
                    let x = Int(a[i]), y = Int(b[i])
                    let d = abs(x - y)
                    sums[i % 3] += Double(d)
                    if d > maxD { maxD = d }
                    if d > 2 { over += 1 }
                    pm += Double(x); fm += Double(y)
                }
            }
        }
        let n = Double(w * h)
        return Result(width: w, height: h, mad: sums.map { $0 / n }, maxDiff: maxD, over2: Double(over) / (n * 3),
                      previewMean: pm / (n * 3), ffmpegMean: fm / (n * 3))
    }
}
