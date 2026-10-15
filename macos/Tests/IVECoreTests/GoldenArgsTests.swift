// Ideal Video Encoder for macOS
// https://github.com/alex-mcdermott/Ideal-Video-Encoder
// Copyright (C) 2026 the Ideal Video Encoder contributors
// SPDX-License-Identifier: GPL-3.0-or-later

// Golden tests: the exact argument arrays the Windows script builds for the same settings
// (worked out by hand from Get-FilterChain, Get-VideoCodecArgs, Get-X265Args and the worker).

import Testing
@testable import IVECore

private let src = "/Volumes/Card/DCIM/DSCF0001.MOV"
private let out = "/Volumes/Card/DCIM/From FFmpeg/DSCF0001.MOV"
private let x265Off = "aq-mode=3:aq-strength=1.2:psy-rd=2:psy-rdoq=1:qg-size=16:sao=1:rect=1:amp=1"
private let x265Light = "aq-mode=3:aq-strength=1.0:psy-rd=2:psy-rdoq=4:qg-size=16:sao=0:strong-intra-smoothing=0:deblock=-1,-1:rect=1:amp=1"
private let tag = EncodeCommand.bt709Tagging
private let tail = ["-c:a", "aac", "-b:a", "320k", "-ar", "48000", "-ac", "2",
                    "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709", "-color_range", "tv",
                    "-movflags", "+faststart"]

@Suite("Golden ffmpeg arguments")
struct GoldenArgsTests {
    @Test func hevcDefaults() {
        let cmd = EncodeCommand(source: src, output: out, codec: .hevc, crf: 21, grain: .off, cap: 35, exposure: 0,
                                lutPath: nil, isFullRange: false, width: 6240, height: 4160)
        #expect(cmd.arguments == ["-y", "-nostdin", "-hide_banner", "-i", src, "-vf", tag, "-map", "0:v:0", "-map", "0:a:0",
                                  "-c:v", "libx265", "-preset", "slow", "-crf", "21", "-maxrate", "35M", "-bufsize", "70M",
                                  "-x265-params", x265Off, "-pix_fmt", "yuv420p10le", "-tag:v", "hvc1"] + tail + [out])
    }

    @Test func hevcLightNoCapWithEverything() {
        let lut = "/Users/me/LUTs/F:Log2 Bob's.cube"
        let cmd = EncodeCommand(source: src, output: out, codec: .hevc, crf: 19, grain: .light, cap: 0, exposure: 0.5,
                                lutPath: lut, isFullRange: true, width: 3840, height: 2160, trimStart: 1.5, trimEnd: 10)
        let vf = "lutyuv=y=val+0.0369*(maxval-minval),format=gbrp10le,lut3d=file='/Users/me/LUTs/F\\:Log2 Bob'\\\\\\''s.cube',zscale=rangein=full:range=limited:matrix=709"
        #expect(cmd.arguments == ["-y", "-nostdin", "-hide_banner", "-ss", "1.5", "-to", "10", "-i", src, "-vf", vf + "," + tag, "-map", "0:v:0", "-map", "0:a:0",
                                  "-c:v", "libx265", "-preset", "slow", "-crf", "19",
                                  "-x265-params", x265Light, "-pix_fmt", "yuv420p10le", "-tag:v", "hvc1"] + tail + [out])
    }

    @Test func hevcStrongFractionalCap() {
        let cmd = EncodeCommand(source: src, output: out, codec: .hevc, crf: 23, grain: .strong, cap: 12.5, exposure: -1.3,
                                lutPath: nil, isFullRange: false, width: 1920, height: 1080, trimStart: 90)
        #expect(cmd.arguments == ["-y", "-nostdin", "-hide_banner", "-ss", "90", "-i", src,
                                  "-vf", "lutyuv=y=val-0.0959*(maxval-minval)," + tag, "-map", "0:v:0", "-map", "0:a:0",
                                  "-c:v", "libx265", "-preset", "slow", "-crf", "23", "-maxrate", "12.5M", "-bufsize", "25M",
                                  "-tune", "grain", "-x265-params", "qg-size=16:rect=1:amp=1",
                                  "-pix_fmt", "yuv420p10le", "-tag:v", "hvc1"] + tail + [out])
    }

    @Test func av1SixKLightCapped() {
        let o = "/x/DSCF0001.MP4"
        let cmd = EncodeCommand(source: src, output: o, codec: .av1, crf: 28, grain: .light, cap: 60, exposure: 0,
                                lutPath: "/l/a.cube", isFullRange: false, width: 6240, height: 4160, trimEnd: 5)
        #expect(cmd.arguments == ["-y", "-nostdin", "-hide_banner", "-to", "5", "-i", src,
                                  "-vf", "format=gbrp10le,lut3d=file='/l/a.cube'," + tag, "-map", "0:v:0", "-map", "0:a:0",
                                  "-c:v", "libsvtav1", "-preset", "5", "-crf", "28", "-maxrate", "60M", "-bufsize", "120M",
                                  "-svtav1-params", "tune=0:film-grain=6:film-grain-denoise=0", "-pix_fmt", "yuv420p10le"] + tail + [o])
    }

    @Test func av1FourKStrongUncappedFullRange() {
        let o = "/x/DSCF0001.MP4"
        let cmd = EncodeCommand(source: src, output: o, codec: .av1, crf: 35, grain: .strong, cap: 0, exposure: 2,
                                lutPath: nil, isFullRange: true, width: 4096, height: 2304)
        #expect(cmd.arguments == ["-y", "-nostdin", "-hide_banner", "-i", src,
                                  "-vf", "lutyuv=y=val+0.1476*(maxval-minval),zscale=rangein=full:range=limited:matrix=709," + tag, "-map", "0:v:0", "-map", "0:a:0",
                                  "-c:v", "libsvtav1", "-preset", "4", "-crf", "35",
                                  "-svtav1-params", "tune=0:film-grain=12:film-grain-denoise=0", "-pix_fmt", "yuv420p10le"] + tail + [o])
    }

    @Test func av1GrainOff() {
        #expect(CodecArgs.video(codec: .av1, crf: 30, cap: 0, grain: .off, width: 1920, height: 1080) ==
                ["-c:v", "libsvtav1", "-preset", "4", "-crf", "30", "-svtav1-params", "tune=0", "-pix_fmt", "yuv420p10le"])
    }

    @Test(arguments: [(4096, 2304, "4"), (3840, 2160, "4"), (4097, 2160, "5"), (4096, 2305, "5"), (6240, 4160, "5"), (0, 0, "4")])
    func av1PresetBoundary(w: Int, h: Int, preset: String) {
        #expect(CodecArgs.video(codec: .av1, crf: 30, cap: 0, grain: .off, width: w, height: h)[3] == preset)
    }

    @Test func x265PerGrain() {
        #expect(CodecArgs.x265(.off) == ["-x265-params", x265Off])
        #expect(CodecArgs.x265(.light) == ["-x265-params", x265Light])
        #expect(CodecArgs.x265(.strong) == ["-tune", "grain", "-x265-params", "qg-size=16:rect=1:amp=1"])
    }

    @Test(arguments: [(0.1, "lutyuv=y=val+0.0074*(maxval-minval)"), (-0.1, "lutyuv=y=val-0.0074*(maxval-minval)"),
                      (1.0, "lutyuv=y=val+0.0738*(maxval-minval)"), (-2.0, "lutyuv=y=val-0.1476*(maxval-minval)"),
                      (0.7, "lutyuv=y=val+0.0517*(maxval-minval)"), (1.5, "lutyuv=y=val+0.1107*(maxval-minval)")])
    func exposure(ev: Double, expected: String) {
        #expect(FilterChain.filters(exposure: ev, lutPath: nil, isFullRange: false) == [expected])
    }

    @Test func builtInScaleFallback() {
        // macOS addition: without zscale the same step uses FFmpeg's built-in scale filter
        #expect(FilterChain.filters(exposure: 0.5, lutPath: "/l.cube", isFullRange: true, zscale: false) ==
                ["lutyuv=y=val+0.0369*(maxval-minval)", "format=gbrp10le", "lut3d=file='/l.cube'", "scale=in_range=pc:out_range=tv:out_color_matrix=bt709"])
        var cmd = EncodeCommand(source: src, output: out, codec: .hevc, crf: 21, grain: .off, cap: 0, exposure: 0,
                                lutPath: nil, isFullRange: true, width: 1920, height: 1080)
        #expect(cmd.arguments.contains("zscale=rangein=full:range=limited:matrix=709," + tag))
        cmd.useZscale = false
        #expect(cmd.arguments.contains("scale=in_range=pc:out_range=tv:out_color_matrix=bt709," + tag))
    }

    @Test func zeroExposureOmitted() {
        #expect(FilterChain.filters(exposure: 0, lutPath: nil, isFullRange: false).isEmpty)
        #expect(FilterChain.filters(exposure: 0.004, lutPath: "", isFullRange: false).isEmpty)
        #expect(FilterChain.filters(exposure: 0, lutPath: nil, isFullRange: true) == ["zscale=rangein=full:range=limited:matrix=709"])
    }

    @Test func lavfiEscaping() {
        #expect(FilterChain.lavfiPath("/a b/x.cube") == "'/a b/x.cube'")
        #expect(FilterChain.lavfiPath("/a:b/x.cube") == "'/a\\:b/x.cube'")
        #expect(FilterChain.lavfiPath("/it's/x.cube") == "'/it'\\\\\\''s/x.cube'")
        #expect(FilterChain.lavfiPath("/back\\slash.cube") == "'/back\\\\slash.cube'")
    }

    @Test func av1CrfMapping() {
        #expect(CodecArgs.av1Crf(fromHevc: 21) == 28)
        #expect(CodecArgs.av1Crf(fromHevc: 16) == 23)
        #expect(CodecArgs.av1Crf(fromHevc: 24) == 31)
        #expect(CodecArgs.av1Crf(fromHevc: 60) == 63)
        #expect(CodecArgs.av1Crf(fromHevc: -10) == 0)
    }

    @Test func clipAnalysisArgs() {
        #expect(ClipAnalysis.statsArguments("/c.mov") == ["-v", "info", "-nostdin", "-hide_banner", "-i", "/c.mov", "-vf",
                                                          "scale=iw/2:ih/2,format=yuv420p,signalstats,metadata=print", "-f", "null", "-"])
        #expect(ClipAnalysis.noiseArguments("/c.mov") == ["-v", "info", "-nostdin", "-hide_banner", "-i", "/c.mov", "-filter_complex",
                                                          "[0:v]scale=iw/2:ih/2,split=2[a][b];[b]hqdn3d=4:4:6:6[dn];[a][dn]psnr", "-f", "null", "-"])
    }

    @Test func targetDuration() {
        #expect(EncodeCommand.targetDuration(source: 30, trimStart: nil, trimEnd: nil) == 30)
        #expect(EncodeCommand.targetDuration(source: 30, trimStart: 5, trimEnd: nil) == 25)
        #expect(EncodeCommand.targetDuration(source: 30, trimStart: nil, trimEnd: 8) == 8)
        #expect(EncodeCommand.targetDuration(source: 30, trimStart: 2, trimEnd: 8) == 6)
    }

    // MARK: speed and audio (Windows v1.3.0, issue #10)

    @Test func speedFilters() {
        let r2997 = FrameRate(num: 30000, den: 1001), r11988 = FrameRate(num: 120000, den: 1001)
        #expect(SpeedAudio.speedFilters(1, rate: r2997).isEmpty)
        // 120 fps at 0.25x is conformed: every captured frame, played at 29.97
        #expect(SpeedAudio.speedFilters(0.25, rate: r11988) == ["setpts=PTS/0.25", "fps=fps=30000/1001"])
        #expect(SpeedAudio.speedFilters(0.5, rate: FrameRate(num: 60000, den: 1001)) == ["setpts=PTS/0.5", "fps=fps=30000/1001"])
        // Otherwise the source rate is kept (frames repeat when slowed, drop when sped up)
        #expect(SpeedAudio.speedFilters(0.5, rate: r2997) == ["setpts=PTS/0.5", "fps=fps=30000/1001"])
        #expect(SpeedAudio.speedFilters(0.125, rate: r2997) == ["setpts=PTS/0.125", "fps=fps=30000/1001"])
        #expect(SpeedAudio.speedFilters(2, rate: FrameRate(num: 30, den: 1)) == ["setpts=PTS/2", "fps=fps=30/1"])
        #expect(SpeedAudio.speedFilters(1.5, rate: FrameRate(num: 25, den: 1)) == ["setpts=PTS/1.5", "fps=fps=25/1"])
        #expect(FrameRate.parse("120000/1001") == r11988 && FrameRate.parse("0/0") == .fallback && FrameRate.parse(nil) == .fallback)
    }

    @Test func atempo() {
        #expect(SpeedAudio.atempoFilters(1).isEmpty)
        #expect(SpeedAudio.atempoFilters(0.125) == ["atempo=0.5", "atempo=0.5", "atempo=0.5"])
        #expect(SpeedAudio.atempoFilters(0.25) == ["atempo=0.5", "atempo=0.5"])
        #expect(SpeedAudio.atempoFilters(0.5) == ["atempo=0.5"])
        #expect(SpeedAudio.atempoFilters(0.75) == ["atempo=0.75"])
        #expect(SpeedAudio.atempoFilters(1.5) == ["atempo=1.5"])
        #expect(SpeedAudio.atempoFilters(8) == ["atempo=8"])
    }

    func audioCmd(speed: Double = 1, trim: (Double?, Double?) = (nil, nil), plan: EncodeCommand.AudioPlan) -> EncodeCommand {
        var c = EncodeCommand(source: src, output: out, codec: .hevc, crf: 21, grain: .off, cap: 0, exposure: 0,
                              lutPath: nil, isFullRange: false, width: 1920, height: 1080, trimStart: trim.0, trimEnd: trim.1)
        c.speed = speed; c.rate = FrameRate(num: 30000, den: 1001); c.sourceDuration = 10; c.audio = plan
        return c
    }
    let video = ["-c:v", "libx265", "-preset", "slow", "-crf", "21", "-x265-params", x265Off, "-pix_fmt", "yuv420p10le", "-tag:v", "hvc1"]
    let colour = ["-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709", "-color_range", "tv", "-movflags", "+faststart"]
    let aac = ["-c:a", "aac", "-b:a", "320k", "-ar", "48000", "-ac", "2"]
    let loud = "loudnorm=I=-16:TP=-1.5:LRA=11:measured_I=-51.80:measured_TP=-40.02:measured_LRA=0.00:measured_thresh=-61.80:offset=0.04:linear=true"

    @Test func audioOffAndNoAudioStream() {
        let off = audioCmd(plan: .init(include: false))
        #expect(off.arguments == ["-y", "-nostdin", "-hide_banner", "-i", src, "-vf", tag, "-map", "0:v:0"] + video + ["-an"] + colour + [out])
        #expect(off.audioText == "no audio")
        // Audio on, but the clip has none and no music: -an, no error
        let silent = audioCmd(plan: .init(include: true, sourceHasAudio: false))
        #expect(silent.arguments == off.arguments)
        // Off also ignores a chosen music file
        #expect(audioCmd(plan: .init(include: false, musicPath: "/m/song.mp3")).arguments == off.arguments)
    }

    @Test func clipAudioSlowedAndNormalised() {
        var p = EncodeCommand.AudioPlan(include: true, sourceHasAudio: true)
        p.loudnorm = loud
        let c = audioCmd(speed: 0.125, plan: p)
        #expect(c.arguments == ["-y", "-nostdin", "-hide_banner", "-i", src, "-vf", "setpts=PTS/0.125,fps=fps=30000/1001," + tag,
                                "-map", "0:v:0", "-map", "0:a:0"] + video + aac +
                               ["-af", "atempo=0.5,atempo=0.5,atempo=0.5," + loud] + colour + [out])
        #expect(c.audioText == "clip audio, normalised")
        #expect(c.outDuration == 80)
    }

    @Test func musicTwiceAsFastNormalisedTrimmed() {
        var p = EncodeCommand.AudioPlan(include: true, sourceHasAudio: true, musicPath: "/m/song.mp3")
        p.loudnorm = loud
        let c = audioCmd(speed: 2, trim: (1, 5), plan: p)
        // Music input after the clip; -vf and every other output option after both; music not time-stretched;
        // fade = min(2, 2/4) = 0.5 s ending at the output length (4 s / 2 = 2 s)
        #expect(c.arguments == ["-y", "-nostdin", "-hide_banner", "-ss", "1", "-to", "5", "-i", src,
                                "-stream_loop", "-1", "-i", "/m/song.mp3",
                                "-vf", "setpts=PTS/2,fps=fps=30000/1001," + tag, "-map", "0:v:0", "-map", "1:a:0"] + video + aac +
                               ["-af", loud + ",afade=t=out:st=1.5:d=0.5", "-shortest", "-t", "2"] + colour + [out])
        #expect(c.audioText == "music: song.mp3, normalised")
        // The loudness pass measures the music on its own (0:a:0) over the output length
        #expect(SpeedAudio.loudnormMeasureArguments(inputs: c.musicInput, map: "0:a:0", pre: c.audioPreFilters, duration: c.outDuration) ==
                ["-hide_banner", "-nostdin", "-stream_loop", "-1", "-i", "/m/song.mp3", "-map", "0:a:0", "-vn",
                 "-af", "loudnorm=I=-16:TP=-1.5:LRA=11:print_format=json", "-t", "2", "-f", "null", "-"])
    }

    @Test func loudnessMeasureOfClip() {
        let c = audioCmd(speed: 0.75, trim: (2, nil), plan: .init())
        #expect(SpeedAudio.loudnormMeasureArguments(inputs: c.clipInput, map: "0:a:0", pre: c.audioPreFilters, duration: 0) ==
                ["-hide_banner", "-nostdin", "-ss", "2", "-i", src, "-map", "0:a:0", "-vn",
                 "-af", "atempo=0.75,loudnorm=I=-16:TP=-1.5:LRA=11:print_format=json", "-f", "null", "-"])
        let stderr = """
            [Parsed_loudnorm_1 @ 0x600] \u{20}
            {
            \t"input_i" : "-51.80",
            \t"input_tp" : "-40.02",
            \t"input_lra" : "0.00",
            \t"input_thresh" : "-61.80",
            \t"output_i" : "-16.09",
            \t"output_tp" : "-4.31",
            \t"output_lra" : "0.00",
            \t"output_thresh" : "-26.09",
            \t"normalization_type" : "linear",
            \t"target_offset" : "0.04"
            }
            """
        let l = SpeedAudio.parseLoudness(stderr)
        #expect(l?.secondPassFilter == loud && l?.integrated == -51.8)
        #expect(SpeedAudio.parseLoudness("no json here") == nil)
    }

    @Test func fadeAndDurations() {
        #expect(SpeedAudio.fadeFilter(outDuration: 4) == "afade=t=out:st=3:d=1")
        #expect(SpeedAudio.fadeFilter(outDuration: 30) == "afade=t=out:st=28:d=2")
        #expect(SpeedAudio.fadeFilter(outDuration: 0) == nil)
        #expect(SpeedAudio.outDuration(source: 10, trimStart: 1, trimEnd: 3, speed: 0.5) == 4)
        #expect(Fmt.upTo3(30000) == "30000" && Fmt.upTo3(2.5) == "2.5" && Fmt.upTo3(0.125) == "0.125" && Fmt.upTo3(1.0004) == "1")
        #expect(SpeedAudio.label(1) == "1x (normal)" && SpeedAudio.label(0.125) == "0.125x" && SpeedAudio.label(8) == "8x")
    }
}
