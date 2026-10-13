// Ideal Video Encoder for macOS
// https://github.com/alex-mcdermott/Ideal-Video-Encoder
// Copyright (C) 2026 the Ideal Video Encoder contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// One measured CRF/cap point (`Measure-Point`): bitrates in Mbps, VMAF mean and worst 1%.
public struct AnalysisPoint: Sendable, Equatable {
    public var crf: Int
    public var cap: Int
    public var avg: Double
    public var peak: Double
    public var vmaf: Double
    public var low: Double
}

/// `Find-QualityCrf`'s result.
public struct QualityResult: Sendable {
    public var crf: Int
    public var cap: Int
    public var grain: Grain
    public var met: Bool
    public var best: AnalysisPoint
    public var current: AnalysisPoint?
    public var points: [AnalysisPoint]
    public var width: Int
    public var height: Int
    public var sourceMbps: Double
    public var samples: Int
    public var sampleLength: Double
}

/// A clip's own CRF/cap/grain from an analysis ("Use per clip") or a quality-target measurement. Only used while
/// `key` (codec, exposure, LUT, grain) matches the current settings.
public struct ClipOverride: Sendable, Equatable {
    public var crf: Int
    public var cap: Int
    public var grain: Grain
    public var target: Double
    public var key: String
    public var codecName: String
    public var met: Bool
    public var vmaf: Double
    public init(crf: Int, cap: Int, grain: Grain, target: Double, key: String, codecName: String, met: Bool, vmaf: Double) {
        self.crf = crf; self.cap = cap; self.grain = grain; self.target = target; self.key = key
        self.codecName = codecName; self.met = met; self.vmaf = vmaf
    }

    /// The queue's note line (`Update-OverrideNotes`).
    public func note(currentKey: String) -> String {
        let text = "Analysed for VMAF \(Fmt.num(target)): \(codecName) CRF \(crf), \(cap) Mbps cap"
        return key == currentKey ? text : text + " (made with different settings, not used)"
    }
}

public struct AnalysisSuggestion: Sendable, Equatable {
    public var crf: Int
    public var cap: Int
    public var codec: Codec
    public var count: Int
}

/// What a clip's analysis needs to know (the script's `$clip` hashtable).
public struct AnalysisClip: Sendable {
    public var id: Int
    public var path: String
    public var starts: [Double]
    public var segLen: Double
    public var vf: [String]
    public var refTail: [String]
    public var grain: Grain
    public var width: Int
    public var height: Int

    /// Samples: one 3 s segment from the middle of clips up to 20 s, two (at 30% and 70%) from longer ones.
    public static func samples(duration dur: Double) -> (starts: [Double], segLen: Double) {
        let segLen = min(3.0, max(0.5, dur - 0.1))
        let starts = dur <= 20 ? [max(0, (dur - segLen) / 2)] : [dur * 0.3 - segLen / 2, dur * 0.7 - segLen / 2]
        return (starts, segLen)
    }
}

/// Port of `$AnalyzeScript`: encodes short samples with the real settings, scores them with VMAF against the
/// identically filtered source, searches for the highest CRF that meets the target, and suggests a cap
/// ~20% above the busiest second. Cancel the surrounding Task to stop; temporary files are removed.
public struct AnalysisWorker: Sendable {
    public var tools: ToolPaths
    public var threads = ProcessInfo.processInfo.activeProcessorCount
    /// Where the temporary sample folder goes (tests point it somewhere they can inspect).
    public var tempRoot = FileManager.default.temporaryDirectory
    public var niceness: Int32 = 10

    public init(tools: ToolPaths) { self.tools = tools }

    // MARK: building blocks (also used by the sanity tests)

    public func sampleEncodeArguments(_ clip: AnalysisClip, codec: Codec, crf: Int, cap: Int, start: Double, output: String) -> [String] {
        var a = ["-hide_banner", "-nostdin", "-loglevel", "error", "-y", "-ss", Fmt.fixed(start, 3), "-t", Fmt.fixed(clip.segLen, 3), "-i", clip.path]
        if !clip.vf.isEmpty { a += ["-vf", clip.vf.joined(separator: ",")] }
        a += ["-an", "-fps_mode", "passthrough"]
        a += CodecArgs.video(codec: codec, crf: crf, cap: Double(cap), grain: clip.grain, width: clip.width, height: clip.height)
        a += CodecArgs.colorTags + [output]
        return a
    }

    /// Frames are paired by index (setpts=N/30/TB on both sides): pairing by timestamp shifts by a frame.
    public func vmafArguments(_ clip: AnalysisClip, sample: String, start: Double, json: String) -> [String] {
        let refChain = clip.vf + clip.refTail + ["format=yuv420p10le"]
        let lavfi = "[0:v]setpts=N/30/TB,format=yuv420p10le[d];[1:v]" + refChain.joined(separator: ",") + ",setpts=N/30/TB" +
            "[r];[d][r]libvmaf=log_fmt=json:log_path=\(FilterChain.lavfiPath(json)):n_threads=\(threads):shortest=1"
        return ["-hide_banner", "-nostdin", "-loglevel", "error", "-i", sample, "-ss", Fmt.fixed(start, 3), "-t", Fmt.fixed(clip.segLen, 3),
                "-i", clip.path, "-lavfi", lavfi, "-f", "null", "-"]
    }

    /// Bits and the busiest 1-second window from (pts, bytes) packets, as the script computes them.
    public static func packetStats(_ packets: [(t: Double, bytes: Double)], peakSoFar: Double) -> (bits: Double, secs: Double, peak: Double) {
        let pk = packets.map { (t: $0.t, b: $0.bytes * 8) }.sorted { $0.t < $1.t }
        guard let first = pk.first, let last = pk.last else { return (0, 0, peakSoFar) }
        let frameDur = pk.count > 1 ? (last.t - first.t) / Double(pk.count - 1) : 1.0 / 30
        let bits = pk.reduce(0) { $0 + $1.b }
        let secs = (last.t - first.t) + frameDur
        var peak = peakSoFar, j = 0, acc = 0.0
        for k in 0..<pk.count {
            acc += pk[k].b
            while pk[k].t - pk[j].t >= 1.0 { acc -= pk[j].b; j += 1 }
            if pk[k].t - first.t + frameDur >= 1.0 || pk.count < 2 { peak = max(peak, acc) }
        }
        if peak == 0 { peak = acc }
        return (bits, secs, peak)
    }

    func ff(_ args: [String]) async throws -> String {
        var lines: [String] = []
        let box = LockedBox<[String]>([])
        let code = try await ProcessRunner.streamStderr(tools.ffmpeg, args, niceness: niceness) { l in box.mutate { $0.append(l) } }
        lines = box.value
        if Task.isCancelled { throw CancellationError() }
        if code != 0 {
            throw ProcessError("ffmpeg failed: " + lines.filter { !$0.isEmpty }.suffix(3).joined(separator: " | "))
        }
        return lines.joined(separator: "\n")
    }

    /// `Measure-Point`: encode every sample at one CRF/cap and score it.
    public func measure(_ clip: AnalysisClip, codec: Codec, crf: Int, cap: Int, tmp: URL) async throws -> AnalysisPoint {
        var bits = 0.0, secs = 0.0, peak = 0.0
        var scores: [Double] = []
        for (i, start) in clip.starts.enumerated() {
            let out = tmp.appendingPathComponent("\(clip.id)-c\(crf)-m\(cap)-s\(i + 1).mp4").path
            _ = try await ff(sampleEncodeArguments(clip, codec: codec, crf: crf, cap: cap, start: start, output: out))

            let probe = try await ProcessRunner.run(tools.ffprobe, ["-v", "error", "-select_streams", "v:0", "-show_entries", "packet=pts_time,size",
                                                                    "-of", "csv=p=0", out])
            let packets: [(t: Double, bytes: Double)] = probe.lines.compactMap { l in
                let p = l.split(separator: ",")
                guard p.count >= 2, let t = Double(p[0]), let s = Double(p[1]) else { return nil }
                return (t, s)
            }
            if packets.isEmpty { throw ProcessError("sample encode produced no video") }
            let st = Self.packetStats(packets, peakSoFar: peak)
            bits += st.bits; secs += st.secs; peak = st.peak

            let json = tmp.appendingPathComponent("vmaf-\(clip.id)-c\(crf)-m\(cap)-s\(i + 1).json").path
            _ = try await ff(vmafArguments(clip, sample: out, start: start, json: json))
            let data = try Data(contentsOf: URL(fileURLWithPath: json))
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            for f in (root?["frames"] as? [[String: Any]]) ?? [] {
                if let v = (f["metrics"] as? [String: Any])?["vmaf"] as? Double { scores.append(v) }
            }
            try? FileManager.default.removeItem(atPath: out)
            try? FileManager.default.removeItem(atPath: json)
        }
        guard !scores.isEmpty else { throw ProcessError("VMAF returned no scores") }
        let sorted = scores.sorted()
        return AnalysisPoint(crf: crf, cap: cap, avg: bits / secs / 1e6, peak: peak / 1e6,
                             vmaf: scores.reduce(0, +) / Double(scores.count), low: sorted[Int((Double(sorted.count) * 0.01).rounded(.down))])
    }

    /// Prepares a clip for analysis (probe, grain rule, samples, filters).
    public func prepare(path: String, id: Int, options opt: RunOptions) async throws -> (clip: AnalysisClip, info: MediaInfo) {
        let info = try await Probe.run(ffprobe: tools.ffprobe, path: path)
        guard info.duration > 0 else { throw ProcessError("could not read the clip duration") }
        var grain = opt.grain
        if opt.autoGrain {
            // Auto rule from ISO / F-Log2 (no noise pass here, to save time)
            let iso = Metadata.parseISO((try? await ProcessRunner.run(tools.exiftool, Metadata.isoArguments(path)))?.lines ?? [])
            let flog = Metadata.isFLog2((try? await ProcessRunner.run(tools.exiftool, Metadata.userCommentArguments(path)))?.lines ?? [])
            grain = AutoRules.analysisGrain(manual: opt.grain, auto: true, isFLog2: flog, iso: iso)
        }
        let s = AnalysisClip.samples(duration: info.duration)
        let vf = FilterChain.filters(exposure: opt.exposure, lutPath: opt.lutPath, isFullRange: info.isFullRange)
        // A LUT leaves RGB; convert the reference the way the encoder does (BT.709, limited)
        let refTail = (opt.lutPath?.isEmpty ?? true) ? [] : ["scale=out_color_matrix=bt709:out_range=tv"]
        return (AnalysisClip(id: id, path: path, starts: s.starts, segLen: s.segLen, vf: vf, refTail: refTail, grain: grain,
                             width: info.width, height: info.height), info)
    }

    /// `Find-QualityCrf` (shared by the Analysis tab and the Quality target encode mode): the highest CRF whose
    /// samples meet VMAF `target` with the current look, grain and codec, and a cap ~20% above the busiest second
    /// at that CRF. `onTest(label, percent)` runs before each test encode, `onPoint(point, label)` after it.
    /// `compare` also scores the current CRF/cap (not with Auto CRF or a quality target).
    public func findQualityCrf(path: String, options opt: RunOptions, target: Double, id: Int = 0, tmp: URL, compare: Bool = false,
                               onTest: (String, Double) -> Void = { _, _ in },
                               onPoint: (AnalysisPoint, String) -> Void = { _, _ in }) async throws -> QualityResult {
        let (clip, info) = try await prepare(path: path, id: id, options: opt)
        var points: [String: AnalysisPoint] = [:]
        var evals = 0
        let maxEvals = 7
        func measure(_ crf: Int, _ cap: Int) async throws -> AnalysisPoint {
            let key = "\(crf)/\(cap)"
            if let p = points[key] { return p }
            evals += 1
            let label = cap != 0 ? "CRF \(crf) + \(cap) Mbps cap" : "CRF \(crf)"
            onTest(label, min(95, Double(evals) / Double(maxEvals) * 100))
            let p = try await self.measure(clip, codec: opt.codec, crf: crf, cap: cap, tmp: tmp)
            points[key] = p
            onPoint(p, label)
            return p
        }
        func good() -> [AnalysisPoint] { points.values.filter { $0.cap == 0 && $0.vmaf >= target }.sorted { $0.crf < $1.crf } }
        func bad() -> [AnalysisPoint] { points.values.filter { $0.cap == 0 && $0.vmaf < target }.sorted { $0.crf < $1.crf } }

        // Bracket the target between two measured CRFs, then interpolate (secant). SVT-AV1's CRF runs 0-63, x265's 0-51.
        let (lo, hi, p1, p2, step) = opt.codec == .av1 ? (20, 55, 30, 40, 6) : (14, 34, 22, 28, 4)
        _ = try await measure(p1, 0)
        _ = try await measure(p2, 0)
        while good().isEmpty, let b = bad().first, b.crf > lo, evals < maxEvals - 1 {
            _ = try await measure(max(lo, b.crf - step), 0)
        }
        while bad().isEmpty, let g = good().last, g.crf < hi, evals < maxEvals - 1 {
            _ = try await measure(min(hi, g.crf + step), 0)
        }
        while let g = good().last, let b = bad().first, b.crf - g.crf > 1, evals < maxEvals - 1 {
            let guess = Double(g.crf) + (g.vmaf - target) * Double(b.crf - g.crf) / max(0.01, g.vmaf - b.vmaf)
            let next = max(g.crf + 1, min(b.crf - 1, Int(guess.rounded(.toNearestOrEven))))
            _ = try await measure(next, 0)
        }
        let met = !good().isEmpty
        guard let best = met ? good().last : points.values.filter({ $0.cap == 0 }).min(by: { $0.crf < $1.crf }) else {
            throw ProcessError("nothing was measured")
        }
        let cap = Int((best.peak * 1.2 / 5).rounded(.up) * 5)

        var current: AnalysisPoint?
        if compare && !opt.autoCrf && opt.qualityTarget == 0 {
            current = try await measure(opt.crf, opt.vbrEnabled ? Int(opt.maxRate.rounded(.toNearestOrEven)) : 0)
        }
        return QualityResult(crf: best.crf, cap: cap, grain: clip.grain, met: met, best: best, current: current,
                             points: points.values.filter { $0.cap == 0 }.sorted { $0.crf < $1.crf },
                             width: info.width, height: info.height, sourceMbps: (info.streamBitRate ?? 0) / 1e6,
                             samples: clip.starts.count, sampleLength: clip.segLen)
    }

    public func run(jobs: [String], options opt: RunOptions, emit: @escaping WorkerSink) async -> AnalysisSuggestion? {
        let dot = Fmt.dot, arrow = Fmt.arrow
        let target = opt.targetVmaf
        let total = jobs.count
        let t0 = Date()
        let tmp = tempRoot.appendingPathComponent("IdealVE-analysis-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased())
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        var results: [(crf: Int, cap: Int, met: Bool)] = []
        func log(_ s: String) { emit(.log(s)) }
        func setAna(_ path: String, _ status: String, _ state: ItemState, _ progress: Double?, _ detail: String?) {
            emit(.item(path: path, status: status, state: state, progress: progress, detail: detail))
        }

        for (index, file) in jobs.enumerated() {
            if Task.isCancelled { break }
            let name = (file as NSString).lastPathComponent
            do {
                setAna(file, "Preparing", .active, 0, "Reading clip...")
                let r = try await findQualityCrf(path: file, options: opt, target: target, id: index, tmp: tmp, compare: true,
                    onTest: { label, pct in
                        setAna(file, "Testing \(label)", .active, pct, "\(opt.codec.displayName) \(dot) target VMAF \(Fmt.num(target))")
                        let frac = (Double(index) + pct / 100) / Double(total)
                        let el = Date().timeIntervalSince(t0)
                        emit(.overall(percent: frac * 100, text: "Analysing \(index + 1) of \(total)",
                                      eta: frac > 0.02 ? "ETA " + Fmt.clock(el * (1 - frac) / frac) : ""))
                    },
                    onPoint: { p, label in
                        log("\(name): \(label) \(arrow) \(Fmt.fixed(p.avg, 1)) Mbps avg, \(Fmt.fixed(p.peak, 1)) Mbps peak, VMAF \(Fmt.fixed(p.vmaf, 2)) (worst 1% \(Fmt.fixed(p.low, 1)))")
                    })
                let best = r.best

                var lines = ["\(opt.codec.displayName) \(dot) \(r.width)x\(r.height) \(dot) source \(Fmt.fixed(r.sourceMbps, 0)) Mbps \(dot) \(r.samples) sample(s) of \(Fmt.upTo1(r.sampleLength)) s"]
                lines.append("Suggested: CRF \(r.crf) + \(r.cap) Mbps cap \(arrow) ~\(Fmt.fixed(best.avg, 0)) Mbps avg (~\(Fmt.fixed(best.avg * 0.45, 0)) GB per hour), VMAF \(Fmt.fixed(best.vmaf, 1)), worst 1% \(Fmt.fixed(best.low, 1))")
                if !r.met { lines.append("Even CRF \(r.crf) stayed below VMAF \(Fmt.fixed(target, 0)); this is the best tested.") }
                if let c = r.current {
                    let curLabel = c.cap != 0 ? "CRF \(c.crf) + \(c.cap) Mbps cap" : "CRF \(c.crf), no cap"
                    lines.append("Your current \(curLabel) \(arrow) \(Fmt.fixed(c.avg, 0)) Mbps, VMAF \(Fmt.fixed(c.vmaf, 1)), worst 1% \(Fmt.fixed(c.low, 1))")
                }
                lines.append("Tested: " + r.points.map { "CRF \($0.crf): \(Fmt.fixed($0.avg, 0)) Mbps / VMAF \(Fmt.fixed($0.vmaf, 1))" }.joined(separator: "  \(dot)  "))

                setAna(file, "CRF \(r.crf) \(dot) \(r.cap) Mbps cap", r.met ? .done : .error, 100, lines.joined(separator: "\n"))
                emit(.clipResult(path: file, result: ClipOverride(crf: r.crf, cap: r.cap, grain: r.grain, target: target, key: opt.lookKey,
                                                                  codecName: opt.codec.displayName, met: r.met, vmaf: best.vmaf), remember: false))
                results.append((r.crf, r.cap, r.met))
            } catch {
                if Task.isCancelled || error is CancellationError { setAna(file, "Cancelled", .cancelled, 0, nil); break }
                let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                setAna(file, "Failed", .error, 0, "Analysis failed: " + msg)
                log("\(name): analysis failed - \(msg)")
            }
        }

        let cancelled = Task.isCancelled
        let suggestion = results.isEmpty ? nil
            : AnalysisSuggestion(crf: results.map(\.crf).min()!, cap: results.map(\.cap).max()!, codec: opt.codec, count: results.count)
        emit(.analysisFinished(cancelled: cancelled, suggestion: suggestion, elapsed: Date().timeIntervalSince(t0)))
        return suggestion
    }
}
