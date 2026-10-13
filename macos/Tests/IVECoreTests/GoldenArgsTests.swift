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
        #expect(cmd.arguments == ["-y", "-nostdin", "-hide_banner", "-i", src, "-vf", tag,
                                  "-c:v", "libx265", "-preset", "slow", "-crf", "21", "-maxrate", "35M", "-bufsize", "70M",
                                  "-x265-params", x265Off, "-pix_fmt", "yuv420p10le", "-tag:v", "hvc1"] + tail + [out])
    }

    @Test func hevcLightNoCapWithEverything() {
        let lut = "/Users/me/LUTs/F:Log2 Bob's.cube"
        let cmd = EncodeCommand(source: src, output: out, codec: .hevc, crf: 19, grain: .light, cap: 0, exposure: 0.5,
                                lutPath: lut, isFullRange: true, width: 3840, height: 2160, trimStart: 1.5, trimEnd: 10)
        let vf = "lutyuv=y=val+0.0369*(maxval-minval),format=gbrp10le,lut3d=file='/Users/me/LUTs/F\\:Log2 Bob'\\\\\\''s.cube',zscale=rangein=full:range=limited:matrix=709"
        #expect(cmd.arguments == ["-y", "-nostdin", "-hide_banner", "-ss", "1.5", "-to", "10", "-i", src, "-vf", vf + "," + tag,
                                  "-c:v", "libx265", "-preset", "slow", "-crf", "19",
                                  "-x265-params", x265Light, "-pix_fmt", "yuv420p10le", "-tag:v", "hvc1"] + tail + [out])
    }

    @Test func hevcStrongFractionalCap() {
        let cmd = EncodeCommand(source: src, output: out, codec: .hevc, crf: 23, grain: .strong, cap: 12.5, exposure: -1.3,
                                lutPath: nil, isFullRange: false, width: 1920, height: 1080, trimStart: 90)
        #expect(cmd.arguments == ["-y", "-nostdin", "-hide_banner", "-ss", "90", "-i", src,
                                  "-vf", "lutyuv=y=val-0.0959*(maxval-minval)," + tag,
                                  "-c:v", "libx265", "-preset", "slow", "-crf", "23", "-maxrate", "12.5M", "-bufsize", "25M",
                                  "-tune", "grain", "-x265-params", "qg-size=16:rect=1:amp=1",
                                  "-pix_fmt", "yuv420p10le", "-tag:v", "hvc1"] + tail + [out])
    }

    @Test func av1SixKLightCapped() {
        let o = "/x/DSCF0001.MP4"
        let cmd = EncodeCommand(source: src, output: o, codec: .av1, crf: 28, grain: .light, cap: 60, exposure: 0,
                                lutPath: "/l/a.cube", isFullRange: false, width: 6240, height: 4160, trimEnd: 5)
        #expect(cmd.arguments == ["-y", "-nostdin", "-hide_banner", "-to", "5", "-i", src,
                                  "-vf", "format=gbrp10le,lut3d=file='/l/a.cube'," + tag,
                                  "-c:v", "libsvtav1", "-preset", "5", "-crf", "28", "-maxrate", "60M", "-bufsize", "120M",
                                  "-svtav1-params", "tune=0:film-grain=6:film-grain-denoise=0", "-pix_fmt", "yuv420p10le"] + tail + [o])
    }

    @Test func av1FourKStrongUncappedFullRange() {
        let o = "/x/DSCF0001.MP4"
        let cmd = EncodeCommand(source: src, output: o, codec: .av1, crf: 35, grain: .strong, cap: 0, exposure: 2,
                                lutPath: nil, isFullRange: true, width: 4096, height: 2304)
        #expect(cmd.arguments == ["-y", "-nostdin", "-hide_banner", "-i", src,
                                  "-vf", "lutyuv=y=val+0.1476*(maxval-minval),zscale=rangein=full:range=limited:matrix=709," + tag,
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
}
