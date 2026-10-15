// Ideal Video Encoder for macOS
// https://github.com/alex-mcdermott/Ideal-Video-Encoder
// Copyright (C) 2026 the Ideal Video Encoder contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import IVECore

@Suite struct AnalysisUnitTests {
    @Test func samples() {
        #expect(AnalysisClip.samples(duration: 10) == ([3.5], 3.0))
        #expect(AnalysisClip.samples(duration: 20) == ([8.5], 3.0))
        #expect(AnalysisClip.samples(duration: 30) == ([7.5, 19.5], 3.0))
        #expect(AnalysisClip.samples(duration: 1.0).segLen == 0.9)
        #expect(AnalysisClip.samples(duration: 0.4).segLen == 0.5)
    }

    @Test func peakWindow() {
        // 32 fps (exact binary timestamps), 2 s of 100 kB frames with one 1 MB spike: the busiest 1 s window holds
        // 32 frames (a frame exactly 1.0 s older drops out), so 31 x 100 kB + 1 MB
        var pk: [(t: Double, bytes: Double)] = (0..<64).map { (Double($0) / 32, 100_000) }
        pk[45].bytes = 1_000_000
        let s = AnalysisWorker.packetStats(pk.shuffled(), peakSoFar: 0)
        #expect(s.secs == 2.0)
        #expect(s.bits == (63 * 100_000 + 1_000_000) * 8)
        #expect(s.peak == (31 * 100_000 + 1_000_000) * 8)
        // a bigger peak from an earlier sample is kept
        #expect(AnalysisWorker.packetStats(pk, peakSoFar: 1e9).peak == 1e9)
    }

    @Test func vmafGraphPairsByIndex() {
        let clip = AnalysisClip(id: 0, path: "/s.mov", starts: [1], segLen: 3, vf: ["format=gbrp10le", "lut3d=file='/l.cube'"],
                                refTail: ["scale=out_color_matrix=bt709:out_range=tv"], grain: .off, width: 1920, height: 1080)
        var w = AnalysisWorker(tools: ToolPaths(ffmpeg: "f", ffprobe: "p", exiftool: "e"))
        w.threads = 8
        let a = w.vmafArguments(clip, sample: "/t/s.mp4", start: 1, json: "/t/v.json")
        #expect(a == ["-hide_banner", "-nostdin", "-loglevel", "error", "-i", "/t/s.mp4", "-ss", "1.000", "-t", "3.000", "-i", "/s.mov", "-lavfi",
                      "[0:v]setpts=N/30/TB,format=yuv420p10le[d];[1:v]format=gbrp10le,lut3d=file='/l.cube',scale=out_color_matrix=bt709:out_range=tv,format=yuv420p10le,setpts=N/30/TB[r];[d][r]libvmaf=log_fmt=json:log_path='/t/v.json':n_threads=8:shortest=1",
                      "-f", "null", "-"])
        let e = w.sampleEncodeArguments(clip, codec: .hevc, crf: 22, cap: 0, start: 1, output: "/t/o.mp4")
        #expect(Array(e.prefix(14)) == ["-hide_banner", "-nostdin", "-loglevel", "error", "-y", "-ss", "1.000", "-t", "3.000", "-i", "/s.mov",
                                        "-vf", "format=gbrp10le,lut3d=file='/l.cube'", "-an"])
        #expect(e.contains("passthrough") && e.suffix(9) == ["-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709", "-color_range", "tv", "/t/o.mp4"])
    }

    @Test func overrideNotesAndLookKey() {
        var s = AppSettings()
        let k = RunOptions.lookKey(settings: s, exposure: 0.04)
        #expect(k == "hevc|0||0|False|1")
        s.codec = .av1; s.grainLevel = .light; s.autoGrain = true
        #expect(RunOptions.lookKey(settings: s, exposure: -1.25, speed: 2) == "av1|-1.2||1|True|2")
        let o = ClipOverride(crf: 24, cap: 45, grain: .off, target: 95, key: k, codecName: "HEVC", met: true, vmaf: 95.3)
        #expect(o.note(currentKey: k) == "Analysed for VMAF 95: HEVC CRF 24, 45 Mbps cap")
        #expect(o.note(currentKey: "x") == "Analysed for VMAF 95: HEVC CRF 24, 45 Mbps cap (made with different settings, not used)")
    }

    @Test func qualityTargetRelaxesValidation() throws {
        var s = AppSettings(); s.crfHevc = "abc"; s.maxRate = "0"; s.qualityTarget = 95
        let o = try RunOptions.validate(settings: s, exposure: 0, trimStart: "", trimEnd: "")
        #expect(o.qualityTarget == 95 && o.crf == 21)
    }
}

@Suite(.enabled(if: integrationEnabled, "set IVE_INTEGRATION=1"), .serialized)
struct AnalysisIntegrationTests {
    let fx = Fixtures.shared
    var tools: ToolPaths { fx.tools }

    func tmp() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("ive-ana-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// The required sanity check: CRF 14 must score > 99, a CRF far above the target clearly lower.
    /// If frames were paired by timestamp the CRF 14 score collapses (measured: ~31 for a one-frame shift).
    @Test func crf14ScoresAbove99() async throws {
        let src = try await fx.clip("sanity.mov", size: "1280x720", seconds: 6, audio: false)
        let w = AnalysisWorker(tools: tools)
        let (clip, _) = try await w.prepare(path: src.path, id: 0, options: RunOptions())
        let t = try tmp(); defer { try? FileManager.default.removeItem(at: t) }
        let hi = try await w.measure(clip, codec: .hevc, crf: 14, cap: 0, tmp: t)
        let lo = try await w.measure(clip, codec: .hevc, crf: 40, cap: 0, tmp: t)
        print(String(format: "sanity: CRF 14 VMAF %.3f (%.1f Mbps), CRF 40 VMAF %.3f (%.2f Mbps)", hi.vmaf, hi.avg, lo.vmaf, lo.avg))
        #expect(hi.vmaf > 99)
        #expect(lo.vmaf < hi.vmaf - 5)
        #expect(try FileManager.default.contentsOfDirectory(atPath: t.path).isEmpty)   // samples and JSON cleaned up
    }

    @Test func cancelStopsFfmpegAndCleansUp() async throws {
        let src = try await fx.clip("long.mov", size: "1920x1080", seconds: 20, audio: false)
        let root = try tmp(); defer { try? FileManager.default.removeItem(at: root) }
        var w = AnalysisWorker(tools: tools)
        w.tempRoot = root
        var opt = RunOptions(); opt.targetVmaf = 95
        let events = EventLog()
        let testing = LockedBox(false)
        let task = Task { await w.run(jobs: [src.path], options: opt) { e in
            events.add(e)
            if case .item(_, let s, _, _, _) = e, s.hasPrefix("Testing") { testing.mutate { $0 = true } }
        } }
        let t0 = Date()
        while !testing.value && Date().timeIntervalSince(t0) < 60 { try await Task.sleep(for: .milliseconds(100)) }
        try await Task.sleep(for: .seconds(2))   // inside a sample encode
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).count == 1)   // the IdealVE-analysis-xxxx folder
        task.cancel()
        let suggestion = await task.value
        #expect(suggestion == nil)
        let pg = try await ProcessRunner.run("/usr/bin/pgrep", ["-f", root.path])
        #expect(pg.stdoutText.isEmpty, "ffmpeg still running: \(pg.stdoutText)")
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty, "temporary files left behind")
        #expect(events.lastItem(src.path)?.state == .cancelled)
    }

    @Test func qualityTargetEncodeMeasuresThenReuses() async throws {
        let src = try await fx.clip("lim422.mov", seconds: 3)
        let out = try await fx.scratch("qt")
        var o = baseOptions(cap: 35, outDir: out)
        o.qualityTarget = 93
        o.lookKey = "hevc|0||0|False"
        o.trimEnd = 1
        let w = EncodeWorker(tools: tools, hasZscale: false)
        let ev1 = EventLog()
        await w.run(jobs: [src.path], options: o) { ev1.add($0) }
        #expect(ev1.finished?.ok == 1, "\(ev1.logs)")
        let remembered = ev1.all.compactMap { e -> ClipOverride? in
            if case .clipResult(_, let r, true) = e { return r } else { return nil }
        }.first
        let r = try #require(remembered)
        #expect(ev1.logs.contains { $0.contains("lim422.mov: VMAF 93 target → CRF \(r.crf), cap \(r.cap) Mbps") })
        #expect(ev1.lastItem(src.path)?.detail?.contains("CRF \(r.crf) (VMAF 93)") == true)
        #expect(ev1.lastItem(src.path)?.detail?.contains("cap \(r.cap) Mbps") == true)
        let mp = try await Probed.load(try #require(ev1.outputs.first), tools: tools)
        #expect(mp.s("codec_name") == "hevc")

        // Second run with the remembered result: no measuring, same CRF
        o.overrides = [src.path: r]
        let out2 = try await fx.scratch("qt2"); o.outputFolder = out2.path
        let ev2 = EventLog()
        await w.run(jobs: [src.path], options: o) { ev2.add($0) }
        #expect(ev2.logs.contains("lim422.mov: reusing its analysis for VMAF 93: CRF \(r.crf), cap \(r.cap) Mbps."))
        #expect(!ev2.all.contains { if case .item(_, let s, _, _, _) = $0 { s.hasPrefix("Measuring") } else { false } })

        // A result made with other settings is not used
        o.qualityTarget = 0
        o.overrides = [src.path: ClipOverride(crf: 30, cap: 5, grain: .off, target: 95, key: "av1|1||0|False", codecName: "AV1", met: true, vmaf: 95)]
        let out3 = try await fx.scratch("qt3"); o.outputFolder = out3.path
        let ev3 = EventLog()
        await w.run(jobs: [src.path], options: o) { ev3.add($0) }
        #expect(ev3.logs.contains("lim422.mov: its analysis was made with different codec/look/grain settings, so it isn't used."))
        #expect(ev3.lastItem(src.path)?.detail?.contains("CRF 21 ·") == true)

        // ... and a matching one ("Use per clip") is
        o.overrides = [src.path: ClipOverride(crf: 26, cap: 15, grain: .light, target: 95, key: o.lookKey, codecName: "HEVC", met: true, vmaf: 95)]
        let out4 = try await fx.scratch("qt4"); o.outputFolder = out4.path
        let ev4 = EventLog()
        let lines = LockedBox<[String]>([])
        var w4 = w; w4.encoderLog = { l in lines.mutate { $0.append(l) } }
        await w4.run(jobs: [src.path], options: o) { ev4.add($0) }
        #expect(ev4.logs.contains("lim422.mov: using its analysis: CRF 26, cap 15 Mbps."))
        #expect(ev4.lastItem(src.path)?.detail?.contains("CRF 26 (analysed) · Grain Light · cap 15 Mbps") == true)
        #expect(lines.value.contains { $0.contains("CRF-26.0") } && lines.value.contains { $0.contains("30000 / 15000") })
    }
}
