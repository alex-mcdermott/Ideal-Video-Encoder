// Ideal Video Encoder for macOS
// https://github.com/alex-mcdermott/Ideal-Video-Encoder
// Copyright (C) 2026 the Ideal Video Encoder contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import AVFoundation
import CoreImage
import Foundation
import VideoToolbox

/// A parsed .cube 3D LUT.
public struct CubeLUT: Sendable, Equatable {
    public var size: Int
    public var domainMin: [Float] = [0, 0, 0]
    public var domainMax: [Float] = [1, 1, 1]
    /// RGB triples, red index fastest, then green, then blue (the .cube order, which CIColorCube shares).
    public var values: [Float]

    public init(size: Int, values: [Float], domainMin: [Float] = [0, 0, 0], domainMax: [Float] = [1, 1, 1]) {
        self.size = size; self.values = values; self.domainMin = domainMin; self.domainMax = domainMax
    }

    public static func parse(_ text: String) throws -> CubeLUT {
        var size = 0
        var dmin: [Float] = [0, 0, 0], dmax: [Float] = [1, 1, 1]
        var values: [Float] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)?
                .trimmingCharacters(in: .whitespaces) ?? ""
            if line.isEmpty { continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            switch parts[0].uppercased() {
            case "TITLE": continue
            case "LUT_1D_SIZE": throw ProcessError("1D LUTs are not supported; choose a 3D .cube LUT.")
            case "LUT_3D_SIZE":
                guard parts.count > 1, let n = Int(parts[1]), n >= 2, n <= 256 else { throw ProcessError("Invalid LUT_3D_SIZE.") }
                size = n
            case "DOMAIN_MIN", "DOMAIN_MAX":
                let v = parts.dropFirst().compactMap { Float($0) }
                guard v.count == 3 else { throw ProcessError("Invalid \(parts[0]).") }
                if parts[0].uppercased() == "DOMAIN_MIN" { dmin = v } else { dmax = v }
            case "LUT_3D_INPUT_RANGE":
                let v = parts.dropFirst().compactMap { Float($0) }
                guard v.count == 2 else { throw ProcessError("Invalid LUT_3D_INPUT_RANGE.") }
                dmin = [v[0], v[0], v[0]]; dmax = [v[1], v[1], v[1]]
            default:
                let v = parts.compactMap { Float($0) }
                if v.count == 3 && parts.count == 3 { values += v }
                // other keywords are ignored, as ffmpeg does
            }
        }
        guard size > 0 else { throw ProcessError("The LUT has no LUT_3D_SIZE.") }
        guard values.count == size * size * size * 3 else {
            throw ProcessError("The LUT has \(values.count / 3) entries; LUT_3D_SIZE \(size) needs \(size * size * size).")
        }
        return CubeLUT(size: size, values: values, domainMin: dmin, domainMax: dmax)
    }

    public static func load(_ path: String) throws -> CubeLUT {
        try parse(String(contentsOfFile: path, encoding: .utf8))
    }

    /// RGBA float data for CIColorCube.
    public var colorCubeData: Data {
        var rgba = [Float](repeating: 1, count: size * size * size * 4)
        for i in 0..<(size * size * size) {
            rgba[i * 4] = values[i * 3]; rgba[i * 4 + 1] = values[i * 3 + 1]; rgba[i * 4 + 2] = values[i * 3 + 2]
        }
        return rgba.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}

/// The preview's version of the encode's look, in Core Image, on encoded (non-linear) values.
///
/// What the encode does (measured with ffmpeg): `lutyuv` adds K x 876 code values to 10-bit luma, where
/// K = round(|EV| x 0.0738, 4), clipping only at 0 and 1023, and it ignores the range tag. With chroma
/// unchanged that is the same offset on R, G and B: K for limited-range sources and K x 876/1023 for
/// full-range ones. `format=gbrp10le` then clamps RGB to 0...1 and `lut3d` applies the LUT.
/// So: rgb + offset -> clamp -> LUT. Without a LUT the display clamps instead.
public struct PreviewLook: Sendable, Equatable {
    public var exposure: Double
    public var isFullRange: Bool
    public var lut: CubeLUT?

    public init(exposure: Double = 0, isFullRange: Bool = false, lut: CubeLUT? = nil) {
        self.exposure = exposure; self.isFullRange = isFullRange; self.lut = lut
    }

    /// The RGB offset the encode's exposure step produces.
    public var rgbOffset: Double {
        let ev = Fmt.round(exposure, 2)
        guard ev != 0 else { return 0 }
        let k = Fmt.round(abs(ev) * 0.0738, 4) * (ev < 0 ? -1 : 1)
        return isFullRange ? k * 876 / 1023 : k
    }

    public var isIdentity: Bool { rgbOffset == 0 && lut == nil }

    public func apply(to image: CIImage) -> CIImage {
        var img = image
        let off = rgbOffset
        if off != 0 {
            img = img.applyingFilter("CIColorMatrix", parameters: ["inputBiasVector": CIVector(x: off, y: off, z: off, w: 0)])
        }
        if let lut {
            img = img.applyingFilter("CIColorClamp")   // gbrp10le can't hold values outside 0...1
            if lut.domainMin != [0, 0, 0] || lut.domainMax != [1, 1, 1] {
                let s = (0..<3).map { CGFloat(1 / max(1e-6, lut.domainMax[$0] - lut.domainMin[$0])) }
                let b = (0..<3).map { -CGFloat(lut.domainMin[$0]) * s[$0] }
                img = img.applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: s[0], y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: s[1], z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: s[2], w: 0), "inputBiasVector": CIVector(x: b[0], y: b[1], z: b[2], w: 0),
                ]).applyingFilter("CIColorClamp")
            }
            img = img.applyingFilter("CIColorCube", parameters: ["inputCubeDimension": lut.size, "inputCubeData": lut.colorCubeData])
        }
        return img
    }
}

/// Builds the AVVideoComposition the preview plays through. The look is read from `look` on every
/// frame, so changes apply live. Rendering uses a CIContext without colour management (working and
/// output colour space NSNull), so exposure and LUT operate on encoded values, as ffmpeg does.
public enum PreviewComposition {
    public static let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .cacheIntermediates: false])

    public static func make(asset: AVAsset, look: LockedBox<PreviewLook>) async throws -> AVMutableVideoComposition {
        let comp = try await AVMutableVideoComposition.videoComposition(with: asset) { request in
            let l = look.value
            let out = l.isIdentity ? request.sourceImage : l.apply(to: request.sourceImage).cropped(to: request.sourceImage.extent)
            request.finish(with: out, context: context)
        }
        // Output is tagged BT.709, like the encode
        comp.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        comp.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        comp.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        return comp
    }
}

public enum HardwareDecode {
    /// Whether VideoToolbox can decode this exact format (codec, profile, chroma, bit depth) in hardware.
    public static func isSupported(for asset: AVAsset) async -> Bool? {
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let desc = try? await track.load(.formatDescriptions).first else { return nil }
        let spec = [kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true] as CFDictionary
        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(allocator: nil, formatDescription: desc, decoderSpecification: spec,
                                                  imageBufferAttributes: nil, outputCallback: nil, decompressionSessionOut: &session)
        if let session { VTDecompressionSessionInvalidate(session) }
        return status == noErr
    }
}
