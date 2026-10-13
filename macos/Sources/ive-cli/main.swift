// Ideal Video Encoder for macOS
// https://github.com/alex-mcdermott/Ideal-Video-Encoder
// Copyright (C) 2026 the Ideal Video Encoder contributors
// SPDX-License-Identifier: GPL-3.0-or-later

// Command-line harness for the core library: check tools, probe clips, print the ffmpeg command.

import Foundation
import IVECore

let usage = """
    usage: ive-cli check
           ive-cli probe <file>
           ive-cli args <file> [--codec hevc|av1] [--crf N] [--grain 0|1|2] [--cap MBPS] [--ev STOPS]
                               [--lut FILE] [--start T] [--end T] [--out FILE]
    """

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
    exit(1)
}

func options(_ args: ArraySlice<String>) -> (positional: [String], flags: [String: String]) {
    var pos: [String] = [], flags: [String: String] = [:]
    var it = args.makeIterator()
    while let a = it.next() {
        if a.hasPrefix("--") { flags[String(a.dropFirst(2))] = it.next() ?? "" } else { pos.append(a) }
    }
    return (pos, flags)
}

let argv = CommandLine.arguments
guard argv.count >= 2 else { fail(usage) }
let settings = (try? SettingsStore().load()) ?? AppSettings()

switch argv[1] {
case "check":
    let r = await ToolReport.check(settings: settings)
    for t in Tool.allCases { print("\(t.rawValue): \(r.paths[t] ?? "NOT FOUND")") }
    print("version: \(r.ffmpegVersion ?? "-")")
    print("encoders: " + ToolReport.requiredEncoders.map { "\($0)=\(r.encoders.contains($0) ? "yes" : "NO")" }.joined(separator: " "))
    print("filters: " + (ToolReport.requiredFilters + ToolReport.otherFilters).map { "\($0)=\(r.filters.contains($0) ? "yes" : "NO")" }.joined(separator: " "))
    for p in r.problems { print("\nPROBLEM: \(p.title)\n  \(p.explanation)\n  Fix:\n    " + p.fix.replacingOccurrences(of: "\n", with: "\n    ")) }
    exit(r.isComplete ? 0 : 2)

case "probe":
    let (pos, _) = options(argv.dropFirst(2))
    guard let file = pos.first, let ffprobe = ToolLocator.locate(.ffprobe, override: settings.ffprobePath) else { fail(usage) }
    do {
        let m = try await Probe.run(ffprobe: ffprobe, path: file)
        print("\(m.width)x\(m.height) \(m.pixelFormat ?? "?") range=\(m.colorRange ?? "?") full=\(m.isFullRange) duration=\(m.duration) bitrate=\(m.streamBitRate.map(Fmt.num) ?? "-") fps=\(m.frameRate.map { String(format: "%.3f", $0) } ?? "-") heat=\(Heat.bar(m.complexity))")
    } catch { fail(error.localizedDescription) }

case "args":
    let (pos, f) = options(argv.dropFirst(2))
    guard let file = pos.first, let ffprobe = ToolLocator.locate(.ffprobe, override: settings.ffprobePath) else { fail(usage) }
    do {
        let m = try await Probe.run(ffprobe: ffprobe, path: file)
        let codec = Codec(rawValue: f["codec"] ?? "hevc") ?? .hevc
        let out = f["out"] ?? ((file as NSString).deletingPathExtension + "_out" + codec.fileExtension)
        func secs(_ k: String) -> Double? { if case .seconds(let v) = Trim.parse(f[k] ?? "") { return v }; return nil }
        let cmd = EncodeCommand(source: file, output: out, codec: codec, crf: Int(f["crf"] ?? "") ?? (codec == .av1 ? 28 : 21),
                                grain: Grain(rawValue: Int(f["grain"] ?? "0") ?? 0) ?? .off, cap: Double(f["cap"] ?? "0") ?? 0,
                                exposure: Double(f["ev"] ?? "0") ?? 0, lutPath: f["lut"], isFullRange: m.isFullRange,
                                width: m.width, height: m.height, trimStart: secs("start"), trimEnd: secs("end"))
        // One argument per line so spaces and quotes are unambiguous
        for a in cmd.arguments { print(a) }
    } catch { fail(error.localizedDescription) }

default:
    fail(usage)
}
