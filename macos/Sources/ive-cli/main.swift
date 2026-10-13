// Ideal Video Encoder for macOS
// https://github.com/alex-mcdermott/Ideal-Video-Encoder
// Copyright (C) 2026 the Ideal Video Encoder contributors
// SPDX-License-Identifier: GPL-3.0-or-later

// Command-line harness for the core library: check tools, probe clips, print the ffmpeg command.

import AVFoundation
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

case "encode":
    // Runs the real worker with the saved settings, overridden by flags. Ctrl-C cancels.
    let (files, f) = options(argv.dropFirst(2))
    guard !files.isEmpty else { fail(usage) }
    var s = settings
    if let c = f["codec"].flatMap(Codec.init(rawValue:)) { s.codec = c }
    if let v = f["crf"] { s.setCrf(v, for: s.codec) }
    if let g = f["grain"].flatMap(Int.init).flatMap(Grain.init(rawValue:)) { s.grainLevel = g }
    if let v = f["cap"] { if v == "off" { s.vbrEnabled = false } else { s.vbrEnabled = true; s.maxRate = v } }
    if let v = f["lut"] { s.lutPath = v; s.lutEnabled = !v.isEmpty }
    if let v = f["outdir"] { s.outputMode = .custom; s.outputFolder = v }
    if let v = f["sub"] { s.subfolder = v }
    if let v = f["csv"] { s.csvEnabled = true; s.csvPath = v }
    if f["auto-crf"] != nil { s.autoCrf = true }
    if f["auto-grain"] != nil { s.autoGrain = true }
    if let t = f["target"].flatMap(Int.init) { s.qualityTarget = t }
    let report = await ToolReport.check(settings: s)
    guard let tools = report.toolPaths else { fail("missing tools: \(report.missingTools.map(\.rawValue))") }
    let opt: RunOptions
    do { opt = try RunOptions.validate(settings: s, exposure: Double(f["ev"] ?? "0") ?? 0, trimStart: f["start"] ?? "", trimEnd: f["end"] ?? "") }
    catch { fail(error.localizedDescription) }
    let worker = EncodeWorker(tools: tools, hasZscale: report.hasZscale)
    let task = Task {
        await worker.run(jobs: files, options: opt) { e in
            switch e {
            case .log(let t): print("[log] \(t)")
            case .item(let p, let st, let state, let pr, let d):
                if !st.hasPrefix("Encoding") || (pr.map { Int($0) % 25 == 0 } ?? false) {
                    print("[item] \((p as NSString).lastPathComponent): \(st) (\(state.rawValue)) \(d ?? "")")
                }
            case .overall: break
            case .finished(let ok, let failed, let cancelled, let elapsed):
                print("[end] ok=\(ok) failed=\(failed) cancelled=\(cancelled) elapsed=\(Fmt.clock(elapsed))")
            case .analysisFinished: break
            case .clipResult(let p, let r, let remember):
                print("[result] \((p as NSString).lastPathComponent): CRF \(r.crf) cap \(r.cap) grain \(r.grain.rawValue) target \(Fmt.num(r.target)) met \(r.met) remember=\(remember)")
            }
        }
    }
    signal(SIGINT, SIG_IGN)
    let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    sigint.setEventHandler { print("[cli] cancelling"); task.cancel() }
    sigint.resume()
    await task.value

case "analyse":
    // ive-cli analyse <files...> [--codec hevc|av1] [--target 93|95|97] [--crf N] [--cap MBPS|off] [--ev X] [--lut FILE] [--auto-crf]
    let (files, f) = options(argv.dropFirst(2))
    guard !files.isEmpty else { fail(usage) }
    var s = settings
    if let c = f["codec"].flatMap(Codec.init(rawValue:)) { s.codec = c }
    if let v = f["crf"] { s.setCrf(v, for: s.codec) }
    if let v = f["cap"] { if v == "off" { s.vbrEnabled = false } else { s.vbrEnabled = true; s.maxRate = v } }
    if let v = f["lut"] { s.lutPath = v; s.lutEnabled = !v.isEmpty }
    if f["auto-crf"] != nil { s.autoCrf = true }
    let report = await ToolReport.check(settings: s)
    guard let tools = report.toolPaths, report.hasVmaf else { fail("needs ffmpeg with libvmaf, ffprobe and exiftool") }
    var opt: RunOptions
    do { opt = try RunOptions.validate(settings: s, exposure: Double(f["ev"] ?? "0") ?? 0, trimStart: "", trimEnd: "", forAnalysis: true) }
    catch { fail(error.localizedDescription) }
    opt.targetVmaf = Double(f["target"] ?? "95") ?? 95
    let worker = AnalysisWorker(tools: tools)
    let task = Task {
        await worker.run(jobs: files, options: opt) { e in
            switch e {
            case .log(let t): print("[log] \(t)")
            case .item(let p, let st, let state, _, let d):
                if state != .active || st == "Preparing" { print("[item] \((p as NSString).lastPathComponent): \(st) (\(state.rawValue))\n\(d ?? "")") }
            case .analysisFinished(let c, let sug, let el):
                print("[end] cancelled=\(c) suggestion=\(sug.map { "CRF \($0.crf) cap \($0.cap)" } ?? "none") elapsed=\(Fmt.clock(el))")
            default: break
            }
        }
    }
    signal(SIGINT, SIG_IGN)
    let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    sigint.setEventHandler { print("[cli] cancelling"); task.cancel() }
    sigint.resume()
    _ = await task.value

case "measure":
    // One Measure-Point: ive-cli measure <file> --crf N [--codec] [--cap N]
    let (pos, f) = options(argv.dropFirst(2))
    guard let file = pos.first else { fail(usage) }
    let report = await ToolReport.check(settings: settings)
    guard let tools = report.toolPaths else { fail("missing tools") }
    var opt = RunOptions()
    opt.codec = Codec(rawValue: f["codec"] ?? "hevc") ?? .hevc
    let w = AnalysisWorker(tools: tools)
    do {
        let (clip, _) = try await w.prepare(path: file, id: 0, options: opt)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ive-measure-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        for crf in (f["crf"] ?? "14").split(separator: ",").compactMap({ Int($0) }) {
            let p = try await w.measure(clip, codec: opt.codec, crf: crf, cap: Int(f["cap"] ?? "0") ?? 0, tmp: tmp)
            print(String(format: "CRF %d cap %d: avg %.2f Mbps, peak %.2f Mbps, VMAF %.3f, worst 1%% %.2f", p.crf, p.cap, p.avg, p.peak, p.vmaf, p.low))
        }
    } catch { fail(error.localizedDescription) }

case "previewcheck":
    // Preview pipeline vs ffmpeg for one frame: ive-cli previewcheck <file> [--frame N] [--ev X] [--lut FILE]
    let (pos, f) = options(argv.dropFirst(2))
    guard let file = pos.first, let ffmpeg = ToolLocator.locate(.ffmpeg, override: settings.ffmpegPath),
          let ffprobe = ToolLocator.locate(.ffprobe, override: settings.ffprobePath) else { fail(usage) }
    do {
        let m = try await Probe.run(ffprobe: ffprobe, path: file)
        let lut = try f["lut"].map { try CubeLUT.load($0) }
        let look = PreviewLook(exposure: Double(f["ev"] ?? "0") ?? 0, isFullRange: m.isFullRange, lut: lut)
        let r = try await PreviewVerifier.compare(path: file, index: Int(f["frame"] ?? "10") ?? 10, look: look, lutPath: f["lut"], ffmpeg: ffmpeg)
        print(String(format: "%dx%d range=%@ ev=%@ lut=%@  MAD R %.3f G %.3f B %.3f overall %.3f /255  max %d  >2: %.3f%%  means %.2f vs %.2f",
                     r.width, r.height, m.isFullRange ? "full" : "limited", f["ev"] ?? "0", f["lut"] == nil ? "no" : "yes",
                     r.mad[0], r.mad[1], r.mad[2], r.overall, r.maxDiff, r.over2 * 100, r.previewMean, r.ffmpegMean))
    } catch { fail(error.localizedDescription) }

case "playbench":
    // ive-cli playbench <file> [--seconds 15] [--ev X] [--lut FILE]
    let (pos, f) = options(argv.dropFirst(2))
    guard let file = pos.first, let ffprobe = ToolLocator.locate(.ffprobe, override: settings.ffprobePath) else { fail(usage) }
    do {
        let m = try await Probe.run(ffprobe: ffprobe, path: file)
        let look = PreviewLook(exposure: Double(f["ev"] ?? "0") ?? 0, isFullRange: m.isFullRange, lut: try f["lut"].map { try CubeLUT.load($0) })
        let r = try await PlaybackBench.run(path: file, look: look, seconds: Double(f["seconds"] ?? "15") ?? 15)
        print(String(format: "%dx%d %@ ev=%@ lut=%@: %.1f s video in %.1f s wall -> speed %.2fx; composited %d frames (%.1f fps, expected %.0f); delivered %d; dropped %@",
                     m.width, m.height, m.pixelFormat ?? "?", f["ev"] ?? "0", f["lut"] == nil ? "no" : "yes", r.videoSeconds, r.wallSeconds, r.speed,
                     r.framesRendered, Double(r.framesRendered) / r.wallSeconds, r.expectedFrames, r.framesDelivered,
                     r.droppedFrames.map(String.init) ?? "n/a"))
    } catch { fail(error.localizedDescription) }

case "hwdecode":
    let (pos, _) = options(argv.dropFirst(2))
    for file in pos {
        let hw = await HardwareDecode.isSupported(for: AVURLAsset(url: URL(fileURLWithPath: file)))
        print("\((file as NSString).lastPathComponent): hardware decode \(hw.map { $0 ? "yes" : "no" } ?? "unknown")")
    }

default:
    fail(usage)
}
