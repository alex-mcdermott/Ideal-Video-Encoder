// Ideal Video Encoder for macOS
// https://github.com/alex-mcdermott/Ideal-Video-Encoder
// Copyright (C) 2026 the Ideal Video Encoder contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import IVECore

/// Runs the real ffmpeg: a LUT whose file name needs escaping must load and actually be applied.
@Suite(.enabled(if: ToolLocator.locate(.ffmpeg) != nil, "ffmpeg not installed"))
struct FFmpegEscapingTests {
    static let names = ["plain.cube", "with space.cube", "co:lon.cube", "it's.cube", "back\\slash.cube",
                        "all: it's [x],y;z=1.cube", "dir with 'quotes'"]

    @Test(arguments: names)
    func lutPathSurvivesLavfi(name: String) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ive-esc-\(UUID().uuidString)/sub: it's here")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        // Inverting LUT: black in -> white out
        var cube = "LUT_3D_SIZE 2\n"
        for b in 0...1 { for g in 0...1 { for r in 0...1 { cube += "\(1 - r) \(1 - g) \(1 - b)\n" } } }
        let lut = dir.appendingPathComponent(name.hasSuffix(".cube") ? name : name + ".cube")
        try cube.write(to: lut, atomically: true, encoding: .utf8)

        let vf = FilterChain.filters(exposure: 0, lutPath: lut.path, isFullRange: false).joined(separator: ",")
        let r = try await ProcessRunner.run(ToolLocator.locate(.ffmpeg)!, [
            "-v", "error", "-f", "lavfi", "-i", "color=c=black:s=16x16:d=0.1", "-vf", vf + ",format=rgb24",
            "-frames:v", "1", "-f", "rawvideo", "-",
        ])
        #expect(r.exitCode == 0, "\(r.stderrText)")
        #expect(r.stdout.count == 16 * 16 * 3)
        #expect(r.stdout.allSatisfy { $0 >= 250 }, "LUT not applied")
    }
}
