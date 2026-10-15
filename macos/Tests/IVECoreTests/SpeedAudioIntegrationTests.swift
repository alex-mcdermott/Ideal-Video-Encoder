// Ideal Video Encoder for macOS
// https://github.com/alex-mcdermott/Ideal-Video-Encoder
// Copyright (C) 2026 the Ideal Video Encoder contributors
// SPDX-License-Identifier: GPL-3.0-or-later

// Speed, audio on/off, loudness normalisation and music replacement through the real worker:
// the test table from Windows v1.3.0 (issue #10), measured with ffprobe and FFmpeg's EBU R128 meter.

import AVFoundation
import Foundation
import Testing
@testable import IVECore

@Suite(.enabled(if: integrationEnabled, "set IVE_INTEGRATION=1"), .serialized)
struct SpeedAudioIntegrationTests {
    let fx = Fixtures.shared
    var tools: ToolPaths { fx.tools }

    /// A synthetic clip with a quiet 440 Hz tone (about -51 LUFS), or none.
    func clip(_ name: String, rate: String = "30000/1001", seconds: Double = 4, audio: Bool = true, size: String = "640x360") async throws -> URL {
        let url = try await fx.scratch("sa-src").appendingPathComponent(name)
        var a = ["-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=s=\(size):r=\(rate)"]
        if audio { a += ["-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000,volume=-36dB"] }
        a += ["-t", Fmt.num(seconds), "-c:v", "libx265", "-preset", "ultrafast", "-x265-params", "log-level=error", "-crf", "12",
              "-tag:v", "hvc1", "-pix_fmt", "yuv422p10le", "-color_range", "tv", "-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709"]
        if audio { a += ["-c:a", "aac", "-b:a", "192k"] }
        let r = try await ProcessRunner.run(tools.ffmpeg, a + [url.path])
        guard r.exitCode == 0 else { throw ProcessError(r.stderrText) }
        return url
    }

    func music(seconds: Double) async throws -> URL {
        let url = try await fx.scratch("sa-music").appendingPathComponent("tune.m4a")
        let r = try await ProcessRunner.run(tools.ffmpeg, ["-v", "error", "-y", "-f", "lavfi", "-i", "sine=frequency=660:sample_rate=44100,volume=-30dB",
                                                         "-t", Fmt.num(seconds), "-c:a", "aac", url.path])
        guard r.exitCode == 0 else { throw ProcessError(r.stderrText) }
        return url
    }

    func run(_ src: URL, speed: Double = 1, audio: Bool = true, normalize: Bool = false, music: URL? = nil,
             trim: (Double?, Double?) = (nil, nil), codec: Codec = .hevc) async throws -> (out: String, events: EventLog) {
        var o = baseOptions(codec: codec, outDir: try await fx.scratch("sa-out"))
        o.speed = speed; o.audioEnabled = audio; o.normalize = normalize && audio; o.musicPath = music?.path
        o.trimStart = trim.0; o.trimEnd = trim.1
        let ev = EventLog()
        await EncodeWorker(tools: tools, hasZscale: true).run(jobs: [src.path], options: o) { ev.add($0) }
        #expect(ev.finished?.ok == 1, "\(ev.logs)")
        return (try #require(ev.outputs.first, "\(ev.logs)"), ev)
    }

    struct Streams { var video: [String: Any]; var audio: [String: Any]?; var duration: Double }
    func streams(_ path: String) async throws -> Streams {
        let p = try await Probed.load(path, tools: tools)
        return Streams(video: p.v, audio: p.a, duration: p.duration)
    }

    /// Integrated loudness (LUFS) of the whole file.
    func lufs(_ path: String) async throws -> Double {
        let r = try await ProcessRunner.run(tools.ffmpeg, ["-hide_banner", "-nostdin", "-i", path, "-map", "0:a:0", "-af", "ebur128", "-f", "null", "-"])
        let summary = r.stderrText.components(separatedBy: "Summary:").last ?? ""
        guard let m = summary.range(of: #"I:\s+(-?[\d.]+) LUFS"#, options: .regularExpression),
              let v = Double(summary[m].split(separator: " ").filter { !$0.isEmpty }[1]) else { throw ProcessError("no ebur128 summary") }
        return v
    }

    /// Mean volume (dBFS) of a window of the audio.
    func meanVolume(_ path: String, from: Double, length: Double) async throws -> Double {
        let r = try await ProcessRunner.run(tools.ffmpeg, ["-hide_banner", "-nostdin", "-ss", Fmt.num(from), "-t", Fmt.num(length), "-i", path,
                                                         "-map", "0:a:0", "-af", "volumedetect", "-f", "null", "-"])
        guard let m = r.stderrText.range(of: #"mean_volume: (-?[\d.]+|-inf) dB"#, options: .regularExpression) else { return -.infinity }
        return Double(r.stderrText[m].dropFirst("mean_volume: ".count).dropLast(3)) ?? -.infinity
    }

    @Test func slowMotionConformsHighFrameRate() async throws {
        let src = try await clip("hfr.mov", rate: "120000/1001", seconds: 4)
        let (out, ev) = try await run(src, speed: 0.25)
        let s = try await streams(out)
        print(String(format: "120 fps at 0.25x: %@ fps, %.3f s", s.video["r_frame_rate"] as? String ?? "?", s.duration))
        #expect(s.video["r_frame_rate"] as? String == "30000/1001")
        #expect(abs(s.duration - 16) < 0.1)
        #expect(ev.logs.contains { $0.contains("filters setpts=PTS/0.25,fps=fps=30000/1001") })
        #expect(ev.lastItem(src.path)?.detail?.contains("· 0.25x") == true)
    }

    @Test(arguments: [(2.0, 2.0), (0.5, 8.0)])
    func speedChangesDuration(speed: Double, expected: Double) async throws {
        let src = try await clip("speed.mov", seconds: 4)
        let (out, _) = try await run(src, speed: speed)
        let s = try await streams(out)
        print(String(format: "%.1fx: %.3f s video, audio %.3f s, %@ fps", speed, s.duration,
                     Double(s.audio?["duration"] as? String ?? "") ?? 0, s.video["r_frame_rate"] as? String ?? "?"))
        #expect(abs(s.duration - expected) < 0.1)
        #expect(s.video["r_frame_rate"] as? String == "30000/1001")   // 29.97 x 0.5 < 23.9: rate kept, frames repeat
        #expect(abs((Double(s.audio?["duration"] as? String ?? "") ?? 0) - expected) < 0.15)   // atempo kept audio in step
    }

    @Test func trimThenSlow() async throws {
        let src = try await clip("trim.mov", seconds: 4)
        let (out, _) = try await run(src, speed: 0.5, trim: (1, 3))
        let d = try await streams(out).duration
        print(String(format: "trim 1-3 s at 0.5x: %.3f s", d))
        #expect(abs(d - 4) < 0.1)
    }

    @Test func audioOffAndSourceWithoutAudio() async throws {
        let src = try await clip("withaudio.mov", seconds: 2)
        let (out, ev) = try await run(src, audio: false)
        #expect(try await streams(out).audio == nil)
        #expect(ev.lastItem(src.path)?.detail?.contains("· no audio") == true)
        let silent = try await clip("noaudio.mov", seconds: 2, audio: false)
        let (out2, ev2) = try await run(silent)   // audio on, nothing to include: -an, no error
        #expect(try await streams(out2).audio == nil)
        #expect(ev2.finished?.failed == 0)
    }

    @Test func normaliseLoudness() async throws {
        let src = try await clip("quiet.mov", seconds: 4)
        let before = try await lufs(src.path)
        let (out, ev) = try await run(src, normalize: true)
        let after = try await lufs(out)
        print(String(format: "normalise: %.1f -> %.1f LUFS", before, after))
        #expect(before < -45)
        #expect(abs(after - -16) < 0.6)
        #expect(ev.all.contains { if case .item(_, let s, _, _, _) = $0 { s == "Measuring loudness" } else { false } })
        #expect(ev.lastItem(src.path)?.detail?.contains("· clip audio, normalised") == true)
    }

    @Test func musicLoopsAndFades() async throws {
        let src = try await clip("formusic.mov", seconds: 4)
        let tune = try await music(seconds: 1.5)
        let (out, ev) = try await run(src, music: tune)
        let s = try await streams(out)
        let early = try await meanVolume(out, from: 0.3, length: 0.6)
        let looped = try await meanVolume(out, from: 2.2, length: 0.6)   // past the end of the 1.5 s file: it looped
        let last = try await meanVolume(out, from: 3.6, length: 0.35)     // fade: last second
        print(String(format: "music 1.5 s on 4 s: video %.2f s, audio %.2f s; mean volume %.1f / %.1f (looped) / %.1f dB (fading)",
                     s.duration, Double(s.audio?["duration"] as? String ?? "") ?? 0, early, looped, last))
        #expect(abs(s.duration - 4) < 0.1)
        #expect(abs(looped - early) < 1.5)
        #expect(last < early - 6)
        #expect(ev.lastItem(src.path)?.detail?.contains("· music: tune.m4a") == true)
    }

    @Test func musicFastNormalised() async throws {
        let src = try await clip("fastmusic.mov", seconds: 4)
        let tune = try await music(seconds: 1.5)
        let (out, ev) = try await run(src, speed: 2, normalize: true, music: tune)
        let s = try await streams(out)
        let l = try await lufs(out)
        let mid = try await meanVolume(out, from: 0.4, length: 0.5), end = try await meanVolume(out, from: 1.7, length: 0.25)
        print(String(format: "music + 2x + normalise: %.1f LUFS, %.2f s, mean volume %.1f -> %.1f dB at the end", l, s.duration, mid, end))
        #expect(abs(s.duration - 2) < 0.1)
        #expect(abs(l - -16) < 1.0)   // the fade lowers the integrated value slightly (Windows measured -16.3)
        #expect(end < mid - 3)
        #expect(ev.lastItem(src.path)?.detail?.contains("· 2x · music: tune.m4a, normalised") == true)
    }

    @Test func applePhotosMakeModel() async throws {
        let src = try await fx.clip("lim422.mov", seconds: 3)
        var o = baseOptions(outDir: try await fx.scratch("keys")); o.trimEnd = 1
        let ev = EventLog()
        await EncodeWorker(tools: tools, hasZscale: true).run(jobs: [src.path], options: o) { ev.add($0) }
        let r = try await ProcessRunner.run(tools.exiftool, ["-a", "-s", "-G1", "-Make", "-Model", try #require(ev.outputs.first)])
        print(r.stdoutText)
        // QuickTime before Keys: Keys (what Photos reads), UserData and XMP all get them (#1)
        for g in ["[Keys]", "[UserData]", "[XMP-tiff]"] {
            #expect(r.stdoutText.contains { _ in true } && r.stdoutText.components(separatedBy: "\n").contains { $0.hasPrefix(g) && $0.contains("TestCam") }, "\(g) Make")
        }
    }

    /// The analysis samples get the same speed change. At 0.5x every frame is shown twice, so VMAF's motion feature
    /// is 0 and even a lossless sample scores only about 97.4 (measured: lossless 97.43, CRF 14 97.18; at 1x CRF 14
    /// scores 99.92). The sanity check is therefore against that ceiling, not 99.
    @Test func analysisWithSpeed() async throws {
        let src = try await fx.clip("sanity.mov", size: "1280x720", seconds: 6, audio: false)
        var opt = RunOptions(); opt.speed = 0.5
        let w = AnalysisWorker(tools: tools)
        let (clip, _) = try await w.prepare(path: src.path, id: 0, options: opt)
        #expect(clip.vf == ["setpts=PTS/0.5", "fps=fps=30/1"])
        let t = try await fx.scratch("ana-speed")
        let hi = try await w.measure(clip, codec: .hevc, crf: 14, cap: 0, tmp: t)
        let lo = try await w.measure(clip, codec: .hevc, crf: 40, cap: 0, tmp: t)
        print(String(format: "analysis at 0.5x: CRF 14 VMAF %.3f, CRF 40 VMAF %.3f", hi.vmaf, lo.vmaf))
        #expect(hi.vmaf > 96.9 && hi.vmaf < 97.6)
        #expect(lo.vmaf < hi.vmaf - 5)
    }

    // MARK: preview (AVFoundation) follows speed, music and loudness

    /// Video frames AVFoundation delivers in [0, seconds) of an asset's timeline.
    func frames(_ asset: AVAsset, seconds: Double) async throws -> Int {
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: seconds, preferredTimescale: 600))
        // decoded frames follow the composition's time scaling (compressed samples keep the source's timing)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(out)
        #expect(reader.startReading(), "\(String(describing: reader.error))")
        var n = 0
        while let sb = out.copyNextSampleBuffer() {
            let t = CMSampleBufferGetPresentationTimeStamp(sb).seconds
            if CMSampleBufferGetNumSamples(sb) > 0, t >= 0, t < seconds { n += 1 }
        }
        return n
    }

    @Test func previewSlowMotionShowsEveryFrame() async throws {
        let src = try await clip("hfr-preview.mov", rate: "120000/1001", seconds: 2)
        let asset = try await PreviewTimeline.make(source: AVURLAsset(url: src), speed: 0.25, music: nil)
        let d = try await asset.load(.duration).seconds
        let n = try await frames(asset, seconds: 1)
        print(String(format: "preview 120 fps at 0.25x: %.2f s timeline, %d frames in the first second", d, n))
        #expect(abs(d - 8) < 0.05)
        #expect(abs(n - 30) <= 1)   // 120 fps x 0.25: every captured frame at 30 per second
        #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)
    }

    @Test func previewMusicLoopsAndFades() async throws {
        let src = try await clip("prev-music.mov", seconds: 8)
        let tune = try await music(seconds: 1.5)
        let asset = try await PreviewTimeline.make(source: AVURLAsset(url: src), speed: 2, music: tune)
        let d = try await asset.load(.duration).seconds
        let loop = CMTimeRange(start: .zero, duration: try await asset.load(.duration))
        let mix = await PreviewTimeline.audioMix(for: asset, gain: LoudnessGain(), fadeOutEnding: loop)
        let wav = try await fx.scratch("pv-audio").appendingPathComponent("music.wav")
        try await PreviewAudioRender.render(asset, mix: mix, to: wav)
        let early = try await meanVolume(wav.path, from: 0.2, length: 0.4)
        let late = try await meanVolume(wav.path, from: 1.6, length: 0.4)    // past the 1.5 s file: looped, not stretched
        let end = try await meanVolume(wav.path, from: 3.82, length: 0.15)   // the fade is the last 1 s of 4
        print(String(format: "preview music at 2x: %.2f s, mean volume %.1f / %.1f (looped) / %.1f dB (fade)", d, early, late, end))
        #expect(abs(d - 4) < 0.05)
        #expect(abs(late - early) < 2)
        #expect(end < early - 6)
    }

    @Test func previewLoudnessGain() async throws {
        let src = try await clip("prev-quiet.mov", seconds: 4)
        let measured = try await SpeedAudio.measureLoudness(ffmpeg: tools.ffmpeg, inputs: ["-i", src.path], map: "0:a:0", pre: [], duration: 0)
        let gain = LoudnessGain()
        gain.decibels = LoudnessGain.decibels(toTarget: measured.integrated)
        let asset = try await PreviewTimeline.make(source: AVURLAsset(url: src), speed: 0.5, music: nil)
        let mix = await PreviewTimeline.audioMix(for: asset, gain: gain, fadeOutEnding: nil)
        let wav = try await fx.scratch("pv-audio").appendingPathComponent("normalised.wav")
        try await PreviewAudioRender.render(asset, mix: mix, channels: 1, to: wav)   // the clip is mono, as the encode keeps it
        let l = try await lufs(wav.path)
        let length = try await Probed.load(wav.path, tools: tools).duration
        print(String(format: "preview normalise: measured %@ LUFS, gain %+.1f dB, played at 0.5x: %.1f LUFS over %.2f s", measured.inputI, gain.decibels, l, length))
        #expect(abs(l - -16) < 1)
        #expect(abs(length - 8) < 0.1)   // the clip's own audio slowed with the video
        gain.decibels = 0                // off: back to the source level, live
        try await PreviewAudioRender.render(asset, mix: await PreviewTimeline.audioMix(for: asset, gain: gain, fadeOutEnding: nil), channels: 1, to: wav)
        #expect(try await lufs(wav.path) < -45)
    }

    /// AVPlayerLooper copies the template item; the gain tap must keep working on every copy.
    @MainActor @Test func previewGainTapSurvivesLooping() async throws {
        let src = try await clip("prev-loop.mov", seconds: 3)
        let asset = try await PreviewTimeline.make(source: AVURLAsset(url: src), speed: 2, music: nil)
        let gain = LoudnessGain()
        gain.decibels = 6
        let mix = await PreviewTimeline.audioMix(for: asset, gain: gain, fadeOutEnding: nil)
        let template = AVPlayerItem(asset: asset)
        template.audioMix = mix
        template.audioTimePitchAlgorithm = .spectral
        let player = AVQueuePlayer()
        player.volume = 0
        let looper = AVPlayerLooper(player: player, templateItem: template,
                                    timeRange: CMTimeRange(start: .zero, duration: CMTime(seconds: 0.5, preferredTimescale: 600)))
        player.play()
        try await Task.sleep(for: .seconds(1.2))
        let first = gain.processedFrames
        try await Task.sleep(for: .seconds(1.5))   // more 0.5 s loops
        let later = gain.processedFrames
        print("preview tap: \(first) frames after 1.2 s, \(later) after 2.7 s, \(looper.loopCount) loops")
        player.pause()
        looper.disableLooping()
        #expect(looper.loopCount >= 2)   // the copies after the first are what matter
        #expect(later - first > 48000)   // about 1.5 s of audio passed the tap after the first copies
    }
}
