// Ideal Video Encoder for macOS
// https://github.com/alex-mcdermott/Ideal-Video-Encoder
// Copyright (C) 2026 the Ideal Video Encoder contributors
// SPDX-License-Identifier: GPL-3.0-or-later

// End-to-end encodes of synthetic clips through the real worker, checked with ffprobe and ExifTool.

import Foundation
import Testing
@testable import IVECore

@Suite(.enabled(if: integrationEnabled, "set IVE_INTEGRATION=1"), .serialized)
struct EncodeIntegrationTests {
    let fx = Fixtures.shared
    var tools: ToolPaths { fx.tools }

    func hasZscale() async -> Bool { await ToolReport.check(settings: AppSettings()).hasZscale }

    func encode(_ files: [URL], _ opt: RunOptions, log: (@Sendable (String) -> Void)? = nil) async -> EventLog {
        let events = EventLog()
        var w = EncodeWorker(tools: tools, hasZscale: await hasZscale())
        w.encoderLog = log
        await w.run(jobs: files.map(\.path), options: opt) { events.add($0) }
        return events
    }

    // MARK: settings take effect

    static let matrix: [(Codec, Grain)] = [(.hevc, .off), (.hevc, .light), (.hevc, .strong), (.av1, .off), (.av1, .light), (.av1, .strong)]

    @Test(arguments: matrix)
    func codecGrainTrim(codec: Codec, grain: Grain) async throws {
        let src = try await fx.clip("lim422.mov", seconds: 3)
        let out = try await fx.scratch("matrix")
        var o = baseOptions(codec: codec, grain: grain, cap: 35, outDir: out)
        o.trimStart = 0.5; o.trimEnd = 2.5
        let lines = LockedBox<[String]>([])
        let ev = await encode([src], o) { l in lines.mutate { $0.append(l) } }
        #expect(ev.finished?.ok == 1, "\(ev.logs)")
        let path = try #require(ev.outputs.first)
        #expect(path.hasSuffix(codec == .av1 ? "lim422.MP4" : "lim422.MOV"))
        let p = try await Probed.load(path, tools: tools)
        #expect(p.s("codec_name") == (codec == .av1 ? "av1" : "hevc"))
        #expect(p.s("codec_tag_string") == (codec == .av1 ? "av01" : "hvc1"))
        #expect(p.s("pix_fmt") == "yuv420p10le")
        #expect(p.s("color_range") == "tv")
        #expect(p.s("color_primaries") == "bt709" && p.s("color_transfer") == "bt709" && p.s("color_space") == "bt709")
        #expect(abs(p.duration - 2.0) < 0.1, "duration \(p.duration)")
        #expect(p.a?["codec_name"] as? String == "aac")
        #expect(p.a?["sample_rate"] as? String == "48000")
        #expect(p.a?["channels"] as? Int == 2)

        // The encoder reports the grain tuning and the cap
        let log = lines.value.joined(separator: "\n")
        let tools = Set(lines.value.filter { $0.contains("x265 [info]: tools:") }
            .flatMap { $0.components(separatedBy: "tools:")[1].split(separator: " ").map(String.init) })
        if codec == .hevc {
            #expect(log.contains("70000 / 35000"), "x265 VBV not reported")
            switch grain {
            case .off: #expect(tools.isSuperset(of: ["psy-rd=2.00", "psy-rdoq=1.00", "sao", "deblock", "strong-intra-smoothing"]), "\(tools)")
            case .light: #expect(tools.isSuperset(of: ["psy-rd=2.00", "psy-rdoq=4.00", "deblock(tC=-1:B=-1)"]) && !tools.contains("sao")
                                 && !tools.contains("strong-intra-smoothing"), "\(tools)")
            case .strong: #expect(tools.isSuperset(of: ["psy-rd=4.00", "psy-rdoq=10.00"]) && !tools.contains("sao"), "\(tools)")
            }
        } else {
            #expect(log.contains("capped CRF / 28.00 / 35000"), "SVT-AV1 cap not reported")
            #expect(log.contains("preset / tune / pred struct") && log.contains(": 4 / VQ"))
            switch grain {
            case .off: #expect(!log.contains("film grain synth"))
            case .light: #expect(log.contains("film grain synth / denoising / level / adaptive blocksize \t: 1 / 0 / 6"))
            case .strong: #expect(log.contains("film grain synth / denoising / level / adaptive blocksize \t: 1 / 0 / 12"))
            }
        }
    }

    @Test func trimFormats() async throws {
        let src = try await fx.clip("lim422.mov", seconds: 3)
        for (start, end, expected) in [("1", "", 2.0), ("0:00.5", "0:01.5", 1.0), ("00:00:01.250", "00:00:02.750", 1.5)] {
            let out = try await fx.scratch("trim")
            var o = try RunOptions.validate(settings: AppSettings(), exposure: 0, trimStart: start, trimEnd: end)
            o.outputMode = .custom; o.outputFolder = out.path; o.subfolder = ""
            let ev = await encode([src], o)
            let p = try await Probed.load(try #require(ev.outputs.first), tools: tools)
            #expect(abs(p.duration - expected) < 0.1, "\(start)-\(end): \(p.duration)")
        }
    }

    // MARK: bitrate cap

    @Test func av1CapIsApplied() async throws {
        let src = try await fx.clip("busy.mov", size: "1280x720", seconds: 4, audio: false, busy: true)
        var rates: [Double] = []
        for cap in [3.0, nil] as [Double?] {
            let out = try await fx.scratch("cap")
            let ev = await encode([src], baseOptions(codec: .av1, crf: 10, cap: cap, outDir: out))
            let path = try #require(ev.outputs.first)
            let p = try await Probed.load(path, tools: tools)
            let size = Double((try FileManager.default.attributesOfItem(atPath: path)[.size] as! NSNumber).int64Value)
            rates.append(size * 8 / p.duration / 1e6)
        }
        print("AV1 CRF 10 busy clip: capped(3 Mbps) = \(String(format: "%.2f", rates[0])) Mbps, uncapped = \(String(format: "%.2f", rates[1])) Mbps")
        #expect(rates[0] < 3 * 1.25)
        #expect(rates[1] > 3 * 3)
    }

    @Test func hevcCapIsApplied() async throws {
        let src = try await fx.clip("busy.mov", size: "1280x720", seconds: 4, audio: false, busy: true)
        var rates: [Double] = []
        for cap in [3.0, nil] as [Double?] {
            let out = try await fx.scratch("cap")
            let ev = await encode([src], baseOptions(codec: .hevc, crf: 10, cap: cap, outDir: out))
            let path = try #require(ev.outputs.first)
            let size = Double((try FileManager.default.attributesOfItem(atPath: path)[.size] as! NSNumber).int64Value)
            rates.append(size * 8 / (try await Probed.load(path, tools: tools)).duration / 1e6)
        }
        print("HEVC CRF 10 busy clip: capped(3 Mbps) = \(String(format: "%.2f", rates[0])) Mbps, uncapped = \(String(format: "%.2f", rates[1])) Mbps")
        #expect(rates[0] < 3 * 1.25)
        #expect(rates[1] > 3 * 3)
    }

    // MARK: sizes, ranges, LUT

    @Test func sixKUsesAV1Preset5() async throws {
        let src = try await fx.clip("big6k.mov", size: "6240x4160", seconds: 0.5, source: "mandelbrot", audio: false)
        let out = try await fx.scratch("6k")
        let lines = LockedBox<[String]>([])
        let ev = await encode([src], baseOptions(codec: .av1, outDir: out)) { l in lines.mutate { $0.append(l) } }
        #expect(ev.finished?.ok == 1, "\(ev.logs)")
        #expect(lines.value.contains { $0.contains("preset / tune / pred struct") && $0.contains(": 5 / VQ") })
        let p = try await Probed.load(try #require(ev.outputs.first), tools: tools)
        #expect(p.v["width"] as? Int == 6240 && p.v["height"] as? Int == 4160)
    }

    /// Full-range source with zscale (when FFmpeg has it) and with the built-in scale fallback.
    @Test(arguments: [true, false])
    func fullRangeSource(useZscale: Bool) async throws {
        if useZscale, !(await hasZscale()) { print("skipped: ffmpeg has no zscale"); return }
        let src = try await fx.clip("full422.mov", seconds: 1, fullRange: true)
        let out = try await fx.scratch("full")
        let w = EncodeWorker(tools: tools, hasZscale: useZscale)
        let ev = EventLog()
        await w.run(jobs: [src.path], options: baseOptions(outDir: out)) { ev.add($0) }
        #expect(ev.finished?.ok == 1, "\(ev.logs)")
        #expect(ev.logs.contains { $0.contains(useZscale ? "source range full -> zscale to limited" : "source range full -> scale to limited") })
        let p = try await Probed.load(try #require(ev.outputs.first), tools: tools)
        #expect(p.s("color_range") == "tv" && p.s("pix_fmt") == "yuv420p10le" && p.s("color_primaries") == "bt709")
    }

    @Test func lutAndExposureApplied() async throws {
        let src = try await fx.clip("lim422.mov", seconds: 3)
        let out = try await fx.scratch("lut")
        var o = baseOptions(outDir: out)
        o.lutPath = try await fx.lut().path
        o.exposure = 0.5
        o.trimEnd = 1
        let ev = await encode([src], o)
        #expect(ev.finished?.ok == 1, "\(ev.logs)")
        #expect(ev.logs.contains { $0.hasSuffix("filters lutyuv=y=val+0.0369*(maxval-minval),format=gbrp10le,lut3d=file=\(FilterChain.lavfiPath(o.lutPath!))") })
    }

    // MARK: metadata

    @Test func metadataCopied() async throws {
        let src = try await fx.clip("lim422.mov", seconds: 3)
        let out = try await fx.scratch("meta")
        var o = baseOptions(outDir: out)
        o.trimEnd = 1
        let ev = await encode([src], o)
        let path = try #require(ev.outputs.first)
        let r = try await ProcessRunner.run(tools.exiftool, ["-a", "-s", "-G1", "-api", "QuickTimeUTC=1", "-Make", "-Model",
                                                             "-QuickTime:CreateDate", "-Keys:CreationDate", "-LensModel",
                                                             "-GPSCoordinates", "-FileCreateDate", "-FileModifyDate", path])
        let t = r.stdoutText
        print(t)
        #expect(t.contains("[UserData]      Make                            : TestCam"))
        #expect(t.contains("[UserData]      Model                           : Model X"))
        #expect(t.contains("LensModel                       : Test 23mm F2"))
        #expect(t.contains("GPSCoordinates                  : 51 deg 30' 0.00\" N, 0 deg 7' 12.00\" W"))
        #expect(t.contains("[QuickTime]     CreateDate                      : \(Fixtures.captureTime)"))
        // File dates equal the capture time (local time, as on Windows)
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let f = DateFormatter(); f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        #expect(f.string(from: attrs[.creationDate] as! Date) == Fixtures.captureTime)
        #expect(f.string(from: attrs[.modificationDate] as! Date) == Fixtures.captureTime)
        #expect(ev.logs.contains { $0.contains("FileCreateDate/ModifyDate set from \(Fixtures.captureTime)") })
    }

    // MARK: output naming, CSV, cancel

    @Test func collisionsAndCsv() async throws {
        let src = try await fx.clip("lim422.mov", seconds: 3)
        let out = try await fx.scratch("names")
        // Same file name from two "cards"
        let card2 = out.appendingPathComponent("card2"); try FileManager.default.createDirectory(at: card2, withIntermediateDirectories: true)
        let copy = card2.appendingPathComponent("lim422.mov"); try FileManager.default.copyItem(at: src, to: copy)
        var o = baseOptions(outDir: out)
        o.trimEnd = 0.5
        o.csvEnabled = true; o.csvPath = out.appendingPathComponent("log dir/log.csv").path
        let ev = await encode([src, copy], o)
        #expect(ev.outputs.map { ($0 as NSString).lastPathComponent } == ["lim422.MOV", "lim422_2.MOV"])
        let bytes = try Data(contentsOf: URL(fileURLWithPath: o.csvPath))
        #expect(bytes.starts(with: [0xEF, 0xBB, 0xBF]))
        let rows = String(decoding: bytes.dropFirst(3), as: UTF8.self).components(separatedBy: "\r\n").filter { !$0.isEmpty }
        #expect(rows.count == 3 && rows[0] == CsvLog.header)
        #expect(rows[1].hasPrefix("\"lim422.mov\",,False,21,0,") && rows[1].hasSuffix(",\"Codec=HEVC ISO= FLog2=False Range=video EV=0.0 VBV=off\""))

        // Next to the source with no subfolder: never overwrite the source itself
        let side = try await fx.scratch("side")
        let movSrc = side.appendingPathComponent("clip.MOV"); try FileManager.default.copyItem(at: src, to: movSrc)
        var o2 = baseOptions(outDir: side); o2.outputMode = .source; o2.trimEnd = 0.5
        let ev2 = await encode([movSrc], o2)
        #expect(ev2.outputs == [side.appendingPathComponent("clip_2.MOV").path])
        let srcCodec = try await ProcessRunner.run(tools.ffprobe, ["-v", "error", "-show_entries", "stream=codec_name", "-of", "csv=p=0", movSrc.path]).stdoutText
        #expect(srcCodec.contains("hevc"))
    }

    @Test func cancelKillsFfmpegAndRemovesPartial() async throws {
        let src = try await fx.clip("long.mov", size: "1920x1080", seconds: 20, audio: false)
        let out = try await fx.scratch("cancel")
        let events = EventLog()
        let progressSeen = LockedBox(false)
        let w = EncodeWorker(tools: tools, hasZscale: await hasZscale())
        let opt = baseOptions(outDir: out)
        let task = Task { await w.run(jobs: [src.path, src.path], options: opt) { e in
            events.add(e)
            if case .item(_, let s, _, let p, _) = e, s.hasPrefix("Encoding"), (p ?? 0) > 0 { progressSeen.mutate { $0 = true } }
        } }
        let started = Date()
        while !progressSeen.value && Date().timeIntervalSince(started) < 60 { try await Task.sleep(for: .milliseconds(100)) }
        #expect(progressSeen.value)
        let partial = out.appendingPathComponent("long.MOV").path
        #expect(FileManager.default.fileExists(atPath: partial))
        task.cancel()
        await task.value
        let pg = try await ProcessRunner.run("/usr/bin/pgrep", ["-f", partial])
        #expect(pg.stdoutText.isEmpty, "ffmpeg still running: \(pg.stdoutText)")
        #expect(!FileManager.default.fileExists(atPath: partial))
        #expect(events.finished?.cancelled == true && events.finished?.ok == 0)
        #expect(events.lastItem(src.path)?.state == .cancelled)
        #expect(events.logs.contains("long.mov: cancelled, partial output removed."))
        #expect(try FileManager.default.contentsOfDirectory(atPath: out.path).isEmpty)
    }

    @Test func failureLogsTailAndRemovesOutput() async throws {
        let bad = try await fx.scratch("bad").appendingPathComponent("broken.mov")
        try Data("not a video".utf8).write(to: bad)
        let out = try await fx.scratch("badout")
        let ev = await encode([bad], baseOptions(outDir: out))
        #expect(ev.finished?.failed == 1)
        #expect(ev.logs.contains { $0.hasPrefix("broken.mov: FAILED - ") })
        #expect(try FileManager.default.contentsOfDirectory(atPath: out.path).isEmpty)
    }

    // MARK: range and levels (real RGB pixels)

    /// Luma stats (8-bit scale) from RGB48 frames: every 10th frame, scaled to 640x360 the same way on both sides.
    func lumaStats(_ path: String, filters: [String]) async throws -> (avg: Double, min: Double, max: Double, p1: Double, p99: Double, lo: Double, hi: Double) {
        let vf = (filters + ["select=not(mod(n\\,10))", "scale=640:360:flags=area", "format=rgb48le"]).joined(separator: ",")
        let r = try await ProcessRunner.run(tools.ffmpeg, ["-v", "error", "-i", path, "-vf", vf, "-fps_mode", "passthrough", "-f", "rawvideo", "-"])
        #expect(r.exitCode == 0, "\(r.stderrText)")
        var ys: [Double] = []
        ys.reserveCapacity(r.stdout.count / 6)
        r.stdout.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            let px = buf.bindMemory(to: UInt16.self)
            var i = 0
            while i + 2 < px.count {
                ys.append((0.2126 * Double(px[i]) + 0.7152 * Double(px[i + 1]) + 0.0722 * Double(px[i + 2])) / 65535 * 255)
                i += 3
            }
        }
        let sorted = ys.sorted()
        return (ys.reduce(0, +) / Double(ys.count), sorted.first!, sorted.last!,
                sorted[sorted.count / 100], sorted[sorted.count * 99 / 100], sorted[sorted.count / 1000], sorted[sorted.count * 999 / 1000])
    }

    @Test(arguments: [false, true])
    func limitedRangeLevelsMatch(withLut: Bool) async throws {
        let src = try await fx.clip("lim422.mov", seconds: 3)
        let out = try await fx.scratch("levels")
        var o = baseOptions(crf: 16, outDir: out)
        if withLut { o.lutPath = try await fx.lut().path }
        let ev = await encode([src], o)
        let path = try #require(ev.outputs.first)
        let ref = try await lumaStats(src.path, filters: FilterChain.filters(exposure: 0, lutPath: o.lutPath, isFullRange: false))
        let enc = try await lumaStats(path, filters: [])
        func f(_ x: Double) -> String { String(format: "%.2f", x) }
        print("levels lut=\(withLut): source avg \(f(ref.avg)) min \(f(ref.min)) max \(f(ref.max)) p0.1 \(f(ref.lo)) p99.9 \(f(ref.hi)) | encode avg \(f(enc.avg)) min \(f(enc.min)) max \(f(enc.max)) p0.1 \(f(enc.lo)) p99.9 \(f(enc.hi))")
        #expect(abs(ref.avg - enc.avg) < 2)
        #expect(abs(ref.p1 - enc.p1) < 2 && abs(ref.p99 - enc.p99) < 2)
        #expect(abs(ref.lo - enc.lo) < 2 && abs(ref.hi - enc.hi) < 2)
    }

    /// Full-range source (needs zscale): the encode, decoded to RGB, must match the source's own RGB picture
    /// (through the look, but WITHOUT zscale, so a range mistake in the encode chain can't hide on both sides).
    @Test(arguments: [false, true], [true, false])
    func fullRangeLevelsMatch(withLut: Bool, useZscale: Bool) async throws {
        if useZscale, !(await hasZscale()) { print("skipped: ffmpeg has no zscale"); return }
        let src = try await fx.clip("full422.mov", seconds: 3, fullRange: true)
        let out = try await fx.scratch("fulllevels")
        var o = baseOptions(crf: 16, outDir: out)
        if withLut { o.lutPath = try await fx.lut().path }
        let ev = EventLog()
        await EncodeWorker(tools: tools, hasZscale: useZscale).run(jobs: [src.path], options: o) { ev.add($0) }
        let path = try #require(ev.outputs.first, "\(ev.logs)")
        #expect(try await Probed.load(path, tools: tools).s("color_range") == "tv")
        let lookOnly = FilterChain.filters(exposure: 0, lutPath: o.lutPath, isFullRange: false)   // no zscale
        let ref = try await lumaStats(src.path, filters: lookOnly)
        let enc = try await lumaStats(path, filters: [])
        func f(_ x: Double) -> String { String(format: "%.2f", x) }
        print("full-range levels lut=\(withLut) \(useZscale ? "zscale" : "scale "): source avg \(f(ref.avg)) min \(f(ref.min)) max \(f(ref.max)) p0.1 \(f(ref.lo)) p99.9 \(f(ref.hi)) | encode avg \(f(enc.avg)) min \(f(enc.min)) max \(f(enc.max)) p0.1 \(f(enc.lo)) p99.9 \(f(enc.hi))")
        #expect(abs(ref.avg - enc.avg) < 2)
        #expect(abs(ref.lo - enc.lo) < 2 && abs(ref.hi - enc.hi) < 2)
    }
}
