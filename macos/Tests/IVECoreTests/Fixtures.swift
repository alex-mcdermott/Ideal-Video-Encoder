// Ideal Video Encoder for macOS
// https://github.com/alex-mcdermott/Ideal-Video-Encoder
// Copyright (C) 2026 the Ideal Video Encoder contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
@testable import IVECore

/// Long integration tests run only with IVE_INTEGRATION=1
/// (`TEST_RUNNER_IVE_INTEGRATION=1 xcodebuild test ...`).
let integrationEnabled = ProcessInfo.processInfo.environment["IVE_INTEGRATION"] == "1"
    && ToolLocator.locate(.ffmpeg) != nil && ToolLocator.locate(.exiftool) != nil

/// Synthetic clips made with ffmpeg, created once per test process in a temporary folder.
actor Fixtures {
    static let shared = Fixtures()
    let dir: URL = FileManager.default.temporaryDirectory.appendingPathComponent("ive-fixtures-\(ProcessInfo.processInfo.processIdentifier)")
    private var made: [String: URL] = [:]

    nonisolated var tools: ToolPaths {
        ToolPaths(ffmpeg: ToolLocator.locate(.ffmpeg)!, ffprobe: ToolLocator.locate(.ffprobe)!, exiftool: ToolLocator.locate(.exiftool)!)
    }

    static let captureTime = "2024:05:06 07:08:09"

    /// 10-bit 4:2:2 HEVC with stereo-less 44.1 kHz mono audio, tagged with camera metadata.
    func clip(_ name: String, size: String = "1280x720", seconds: Double = 3, fullRange: Bool = false,
              source: String = "testsrc2", audio: Bool = true, busy: Bool = false) async throws -> URL {
        let key = "\(name)|\(size)|\(seconds)|\(fullRange)|\(source)|\(audio)|\(busy)"
        if let u = made[key] { return u }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        var a = ["-v", "error", "-y", "-f", "lavfi", "-i", "\(source)=s=\(size):r=30"]
        if audio { a += ["-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100"] }
        a += ["-t", Fmt.num(seconds)]
        if busy { a += ["-vf", "noise=alls=60:allf=t+u"] }
        a += ["-c:v", "libx265", "-preset", "ultrafast", "-x265-params", "log-level=error", "-crf", "8", "-pix_fmt", "yuv422p10le",
              "-color_range", fullRange ? "pc" : "tv", "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709"]
        if audio { a += ["-c:a", "aac", "-ac", "1"] }
        a.append(url.path)
        let r = try await ProcessRunner.run(tools.ffmpeg, a)
        guard r.exitCode == 0 else { throw ProcessError("fixture \(name): \(r.stderrText)") }
        let e = try await ProcessRunner.run(tools.exiftool, [
            "-q", "-overwrite_original", "-Make=TestCam", "-Model=Model X", "-UserData:DateTimeOriginal=\(Self.captureTime)",
            "-LensModel=Test 23mm F2", "-FocalLength=23", "-GPSCoordinates=51.5, -0.12, 30", url.path,
        ])
        guard e.exitCode == 0 else { throw ProcessError("fixture tags: \(e.stderrText)") }
        made[key] = url
        return url
    }

    /// A gently warming 17-point LUT (non-identity, so its effect is measurable).
    func lut(named name: String = "warm look.cube") throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        try Self.cubeText(size: 17) { r, g, b in (min(1, r * 1.06 + 0.02), g, max(0, b * 0.92)) }
            .write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func cubeText(size n: Int, _ f: (Double, Double, Double) -> (Double, Double, Double)) -> String {
        var s = "TITLE \"test\"\nLUT_3D_SIZE \(n)\nDOMAIN_MIN 0 0 0\nDOMAIN_MAX 1 1 1\n"
        for b in 0..<n { for g in 0..<n { for r in 0..<n {
            let v = f(Double(r) / Double(n - 1), Double(g) / Double(n - 1), Double(b) / Double(n - 1))
            s += String(format: "%.6f %.6f %.6f\n", v.0, v.1, v.2)
        } } }
        return s
    }

    func scratch(_ name: String) throws -> URL {
        let u = dir.appendingPathComponent("out-\(name)-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
}

/// ffprobe fields of an output file.
struct Probed {
    var v: [String: Any] = [:]
    var a: [String: Any]?
    var format: [String: Any] = [:]
    func s(_ k: String) -> String? { v[k] as? String }
    var duration: Double { Double(format["duration"] as? String ?? "") ?? 0 }
    var videoBitRate: Double { Double(v["bit_rate"] as? String ?? "") ?? 0 }

    static func load(_ path: String, tools: ToolPaths) async throws -> Probed {
        let r = try await ProcessRunner.run(tools.ffprobe, ["-v", "error", "-show_streams", "-show_format", "-of", "json", path])
        let o = try JSONSerialization.jsonObject(with: r.stdout) as! [String: Any]
        let streams = o["streams"] as? [[String: Any]] ?? []
        var p = Probed()
        p.v = streams.first { $0["codec_type"] as? String == "video" } ?? [:]
        p.a = streams.first { $0["codec_type"] as? String == "audio" }
        p.format = o["format"] as? [String: Any] ?? [:]
        return p
    }
}

/// Collects worker events for assertions.
final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [WorkerEvent] = []
    func add(_ e: WorkerEvent) { lock.lock(); events.append(e); lock.unlock() }
    var all: [WorkerEvent] { lock.lock(); defer { lock.unlock() }; return events }
    var logs: [String] { all.compactMap { if case .log(let s) = $0 { s } else { nil } } }
    var finished: (ok: Int, failed: Int, cancelled: Bool)? {
        for e in all.reversed() { if case .finished(let o, let f, let c, _) = e { return (o, f, c) } }
        return nil
    }
    func lastItem(_ path: String) -> (status: String, state: ItemState, detail: String?)? {
        for e in all.reversed() { if case .item(let p, let s, let st, _, let d) = e, p == path { return (s, st, d) } }
        return nil
    }
    /// Output paths from the worker's "<name> -> <path> | saved ..." lines (not "source range full -> zscale ...").
    var outputs: [String] {
        logs.compactMap { l in
            guard let r = l.range(of: #" -> (/.+) \| saved"#, options: .regularExpression) else { return nil }
            return String(l[r].dropFirst(4).components(separatedBy: " | saved")[0])
        }
    }
}

func baseOptions(codec: Codec = .hevc, crf: Int? = nil, grain: Grain = .off, cap: Double? = nil, outDir: URL) -> RunOptions {
    var o = RunOptions()
    o.codec = codec
    o.crf = crf ?? (codec == .av1 ? 28 : 21)
    o.grain = grain
    o.vbrEnabled = cap != nil
    o.maxRate = cap ?? 0
    o.outputMode = .custom
    o.outputFolder = outDir.path
    o.subfolder = ""
    return o
}
