// Ideal Video Encoder for macOS
// https://github.com/alex-mcdermott/Ideal-Video-Encoder
// Copyright (C) 2026 the Ideal Video Encoder contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import IVECore

@Suite struct CubeLUTTests {
    @Test func parsesOrderAndDomain() throws {
        let text = """
            # comment
            TITLE "x"
            LUT_3D_SIZE 2
            DOMAIN_MIN 0 0 0
            DOMAIN_MAX 1 1 1
            0 0 0
            1 0 0
            0 1 0
            1 1 0
            0 0 1
            1 0 1
            0 1 1
            1 1 1
            """
        let lut = try CubeLUT.parse(text)
        #expect(lut.size == 2 && lut.values.count == 24)
        // red index varies fastest: entry 1 is (r=1, g=0, b=0)
        #expect(Array(lut.values[3..<6]) == [1, 0, 0])
        #expect(lut.colorCubeData.count == 8 * 4 * 4)
        let shifted = try CubeLUT.parse("LUT_3D_SIZE 2\nDOMAIN_MIN -0.1 0 0\nDOMAIN_MAX 1.1 1 1\n" + String(repeating: "0 0 0\n", count: 8))
        #expect(shifted.domainMin == [-0.1, 0, 0] && shifted.domainMax == [1.1, 1, 1])
    }

    @Test func rejectsBadFiles() {
        #expect(throws: (any Error).self) { try CubeLUT.parse("LUT_1D_SIZE 4\n0 0 0") }
        #expect(throws: (any Error).self) { try CubeLUT.parse("0 0 0\n") }
        #expect(throws: (any Error).self) { try CubeLUT.parse("LUT_3D_SIZE 2\n0 0 0\n") }
    }

    @Test func exposureOffsetMatchesEncode() {
        // lutyuv adds K x 876 code values: K in limited-range RGB, K x 876/1023 for full-range sources
        #expect(PreviewLook(exposure: 1).rgbOffset == 0.0738)
        #expect(PreviewLook(exposure: -0.5).rgbOffset == -0.0369)
        #expect(abs(PreviewLook(exposure: 1, isFullRange: true).rgbOffset - 0.0738 * 876 / 1023) < 1e-12)
        #expect(PreviewLook(exposure: 0.004).rgbOffset == 0)
        #expect(PreviewLook().isIdentity)
    }
}

/// Preview pipeline vs ffmpeg with the encode's filters, on synthetic 10-bit 4:2:2 HEVC (hvc1, so AVFoundation decodes it).
@Suite(.enabled(if: integrationEnabled, "set IVE_INTEGRATION=1"), .serialized)
struct PreviewFidelityTests {
    static func clip(_ range: String) async throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ive-preview-fixtures")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("grad-\(range).MOV")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let r = try await ProcessRunner.run(Fixtures.shared.tools.ffmpeg, [
            "-v", "error", "-y", "-f", "lavfi", "-i", "gradients=s=1280x720:r=30:speed=0.02", "-t", "1.5",
            "-c:v", "libx265", "-preset", "ultrafast", "-x265-params", "log-level=error", "-crf", "6", "-pix_fmt", "yuv422p10le",
            "-color_range", range, "-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709", "-tag:v", "hvc1", url.path,
        ])
        guard r.exitCode == 0 else { throw ProcessError(r.stderrText) }
        return url
    }

    @Test(arguments: ["tv", "pc"], [0.0, 1.0, -1.0])
    func matchesFfmpeg(range: String, ev: Double) async throws {
        let src = try await Self.clip(range)
        let lutURL = try await Fixtures.shared.lut(named: "preview test.cube")
        for withLut in [false, true] {
            let look = PreviewLook(exposure: ev, isFullRange: range == "pc", lut: withLut ? try CubeLUT.load(lutURL.path) : nil)
            let r = try await PreviewVerifier.compare(path: src.path, index: 12, look: look, lutPath: withLut ? lutURL.path : nil,
                                                      ffmpeg: Fixtures.shared.tools.ffmpeg)
            print(String(format: "preview vs ffmpeg range=%@ ev=%+.0f lut=%@: MAD %.3f/255 (R %.3f G %.3f B %.3f) max %d",
                         range, ev, withLut ? "yes" : "no", r.overall, r.mad[0], r.mad[1], r.mad[2], r.maxDiff))
            #expect(r.overall < 2, "range \(range) ev \(ev) lut \(withLut): \(r.overall)")
            #expect(r.maxDiff <= 4)
        }
    }

    /// Negative control: the comparison must notice a wrong look (here the limited-range exposure rule on a
    /// full-range clip at +2 EV, about 5/255 too bright), or the passing results above mean nothing.
    @Test func detectsWrongExposureRule() async throws {
        let src = try await Self.clip("pc")
        let wrong = PreviewLook(exposure: 2, isFullRange: false)
        let r = try await PreviewVerifier.compare(path: src.path, index: 12, look: wrong, lutPath: nil, ffmpeg: Fixtures.shared.tools.ffmpeg)
        print(String(format: "control (wrong rule, full range +2 EV): MAD %.3f/255", r.overall))
        #expect(r.overall > 2)
    }
}
