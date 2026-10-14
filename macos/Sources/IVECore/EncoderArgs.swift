// Ideal Video Encoder for macOS
// https://github.com/alex-mcdermott/Ideal-Video-Encoder
// Copyright (C) 2026 the Ideal Video Encoder contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public enum Codec: String, Codable, Sendable, CaseIterable, Identifiable {
    case hevc, av1
    public var id: String { rawValue }
    public var displayName: String { self == .av1 ? "AV1" : "HEVC" }
    public var menuName: String { self == .av1 ? "AV1 (SVT-AV1)" : "HEVC (x265)" }
    /// AV1 cannot be written to MOV, so it goes to MP4.
    public var fileExtension: String { self == .av1 ? ".MP4" : ".MOV" }
    public var maxCrf: Int { self == .av1 ? 63 : 51 }
}

public enum Grain: Int, Codable, Sendable, CaseIterable, Identifiable {
    case off = 0, light = 1, strong = 2
    public var id: Int { rawValue }
    public var name: String { ["Off", "Light", "Strong"][rawValue] }
}

/// The filter graph shared by encode and analysis: exposure -> LUT -> range remap.
public enum FilterChain {
    /// Escape a path for a lavfi option value inside single quotes. Two parsing levels see it
    /// (the filtergraph, then the option string), hence the doubled escapes.
    /// The Windows script also turns `\` into `/`; on macOS a backslash is an ordinary file-name
    /// character, so it is escaped instead.
    public static func lavfiPath(_ path: String) -> String {
        var p = path.replacingOccurrences(of: "\\", with: "\\\\")
        p = p.replacingOccurrences(of: ":", with: "\\:")
        p = p.replacingOccurrences(of: "'", with: "'\\\\\\''")
        return "'" + p + "'"
    }

    /// Exposure in stops as a luma offset of 0.0738 per stop (the F-Log2 slope), at 10-bit precision.
    public static func exposureFilter(_ ev: Double) -> String {
        let k = Fmt.num(Fmt.round(abs(ev) * 0.0738, 4))
        return "lutyuv=y=val\(ev < 0 ? "-" : "+")\(k)*(maxval-minval)"
    }

    /// The script's full-to-limited step (needs zimg).
    public static let zscaleRange = "zscale=rangein=full:range=limited:matrix=709"
    /// macOS addition: the same conversion with FFmpeg's built-in scale filter, used when the installed FFmpeg has
    /// no zscale (Homebrew's standard build). Measured against zscale: mean difference 0.2-1.7 of 1023 code values.
    public static let scaleRange = "scale=in_range=pc:out_range=tv:out_color_matrix=bt709"

    public static func filters(exposure: Double, lutPath: String?, isFullRange: Bool, zscale: Bool = true) -> [String] {
        var vf: [String] = []
        let ev = Fmt.round(exposure, 2)
        if ev != 0 { vf.append(exposureFilter(ev)) }
        if let lut = lutPath, !lut.isEmpty {
            vf.append("format=gbrp10le")
            vf.append("lut3d=file=" + lavfiPath(lut))
        }
        if isFullRange { vf.append(zscale ? zscaleRange : scaleRange) }
        return vf
    }
}

public enum CodecArgs {
    /// x265 tuning per grain level, copied from `Get-X265Args`.
    public static func x265(_ grain: Grain) -> [String] {
        switch grain {
        case .light: return ["-x265-params", "aq-mode=3:aq-strength=1.0:psy-rd=2:psy-rdoq=4:qg-size=16:sao=0:strong-intra-smoothing=0:deblock=-1,-1:rect=1:amp=1"]
        case .strong: return ["-tune", "grain", "-x265-params", "qg-size=16:rect=1:amp=1"]
        case .off: return ["-x265-params", "aq-mode=3:aq-strength=1.2:psy-rd=2:psy-rdoq=1:qg-size=16:sao=1:rect=1:amp=1"]
        }
    }

    /// `Get-VideoCodecArgs`: CRF, optional VBV cap in Mbps (0 = none), grain, 10-bit 4:2:0.
    public static func video(codec: Codec, crf: Int, cap: Double, grain: Grain, width: Int = 0, height: Int = 0) -> [String] {
        var vbv: [String] = []
        if cap > 0 { vbv = ["-maxrate", Fmt.num(cap) + "M", "-bufsize", Fmt.num(cap * 2) + "M"] }
        if codec == .av1 {
            var p = "tune=0"
            if grain == .light { p += ":film-grain=6:film-grain-denoise=0" } else if grain == .strong { p += ":film-grain=12:film-grain-denoise=0" }
            // SVT-AV1 only allows preset 5+ above 4K ("8K class")
            let preset = (width > 4096 || height > 2304) ? 5 : 4
            return ["-c:v", "libsvtav1", "-preset", "\(preset)", "-crf", "\(crf)"] + vbv + ["-svtav1-params", p, "-pix_fmt", "yuv420p10le"]
        }
        return ["-c:v", "libx265", "-preset", "slow", "-crf", "\(crf)"] + vbv + x265(grain) + ["-pix_fmt", "yuv420p10le", "-tag:v", "hvc1"]
    }

    /// `ConvertTo-Av1Crf`: rough HEVC -> SVT-AV1 CRF equivalence.
    public static func av1Crf(fromHevc crf: Int) -> Int { max(0, min(63, crf + 7)) }

    public static let audio = ["-c:a", "aac", "-b:a", "320k", "-ar", "48000", "-ac", "2"]
    public static let colorTags = ["-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709", "-color_range", "tv"]
}

/// The full ffmpeg command for one clip, as the worker builds it.
public struct EncodeCommand: Sendable, Equatable {
    public var source: String
    public var output: String
    public var codec: Codec
    public var crf: Int
    public var grain: Grain
    public var cap: Double          // 0 = no cap
    public var exposure: Double
    public var lutPath: String?
    public var isFullRange: Bool
    public var width: Int
    public var height: Int
    public var trimStart: Double?
    public var trimEnd: Double?
    /// Range conversion with zscale (as on Windows) or, when FFmpeg lacks it, the built-in scale filter.
    public var useZscale = true
    /// Playback speed (Windows v1.3.0); 1 = normal.
    public var speed = 1.0
    /// The source's r_frame_rate, which speed changes conform to.
    public var rate = FrameRate.fallback
    /// Source duration, for the output length after trim and speed.
    public var sourceDuration = 0.0
    public var audio = AudioPlan()

    /// What happens to the soundtrack.
    public struct AudioPlan: Sendable, Equatable {
        /// "Include audio"; off writes no audio stream.
        public var include = true
        public var sourceHasAudio = true
        /// "Replace with a music file": looped, faded out at the end, cut to the video length.
        public var musicPath: String?
        /// Second-pass loudnorm filter when "Normalise loudness" is on (from the first-pass measurement).
        public var loudnorm: String?
        public init(include: Bool = true, sourceHasAudio: Bool = true, musicPath: String? = nil, loudnorm: String? = nil) {
            self.include = include; self.sourceHasAudio = sourceHasAudio; self.musicPath = musicPath; self.loudnorm = loudnorm
        }
        /// Off, or a clip without audio and no music: `-an`, no error.
        public var active: Bool { include && (musicPath != nil || sourceHasAudio) }
        public var usesMusic: Bool { include && musicPath != nil }
    }

    public init(source: String, output: String, codec: Codec, crf: Int, grain: Grain, cap: Double, exposure: Double,
                lutPath: String?, isFullRange: Bool, width: Int, height: Int, trimStart: Double? = nil, trimEnd: Double? = nil) {
        self.source = source; self.output = output; self.codec = codec; self.crf = crf; self.grain = grain; self.cap = cap
        self.exposure = exposure; self.lutPath = lutPath; self.isFullRange = isFullRange; self.width = width; self.height = height
        self.trimStart = trimStart; self.trimEnd = trimEnd
    }

    /// The script's filter chain (exposure -> LUT -> range).
    public var filters: [String] { FilterChain.filters(exposure: exposure, lutPath: lutPath, isFullRange: isFullRange, zscale: useZscale) }

    /// macOS addition: FFmpeg 7.1+ takes colour primaries/transfer from the frames and ignores
    /// `-color_primaries`/`-color_trc` when the source is untagged, so the output would say "unknown".
    /// Tagging the frames (metadata only, pixels untouched) restores the BT.709 tags the script asks for.
    public static let bt709Tagging = "setparams=color_primaries=bt709:color_trc=bt709"

    /// The filters actually passed to ffmpeg: the look, then the speed change, then BT.709 tagging.
    public var encodeFilters: [String] { filters + SpeedAudio.speedFilters(speed, rate: rate) + [Self.bt709Tagging] }

    /// Output length after trim and speed (progress and the music cut are measured against it).
    public var outDuration: Double {
        SpeedAudio.outDuration(source: sourceDuration, trimStart: trimStart, trimEnd: trimEnd, speed: speed)
    }

    /// The clip input, trimmed (also the input of the loudness measurement of the clip's own audio).
    public var clipInput: [String] {
        var a: [String] = []
        if let s = trimStart { a += ["-ss", Fmt.num(s)] }
        if let e = trimEnd { a += ["-to", Fmt.num(e)] }
        return a + ["-i", source]
    }

    /// The looped music input (also the only input of its loudness measurement, where it is 0:a:0).
    public var musicInput: [String] { audio.musicPath.map { ["-stream_loop", "-1", "-i", $0] } ?? [] }

    /// Filters before loudnorm: atempo for the clip's audio, none for music (it isn't time-stretched).
    public var audioPreFilters: [String] { audio.usesMusic ? [] : SpeedAudio.atempoFilters(speed) }

    /// The `-af` chain: atempo, loudnorm, fade-out (music), in that order.
    public var audioFilters: [String] {
        var af = audioPreFilters
        if let l = audio.loudnorm { af.append(l) }
        if audio.usesMusic, let f = SpeedAudio.fadeFilter(outDuration: outDuration) { af.append(f) }
        return af
    }

    /// "clip audio", "no audio" or "music: <name>", plus ", normalised" (detail line and CSV).
    public var audioText: String {
        guard audio.active else { return "no audio" }
        var t = audio.usesMusic ? "music: " + ((audio.musicPath ?? "") as NSString).lastPathComponent : "clip audio"
        if audio.loudnorm != nil { t += ", normalised" }
        return t
    }

    public var arguments: [String] {
        var a = ["-y", "-nostdin", "-hide_banner"] + clipInput
        if audio.active && audio.usesMusic { a += musicInput }
        // Output options only after every input: a -vf before the music input would break the encode
        a += ["-vf", encodeFilters.joined(separator: ",")]
        a += ["-map", "0:v:0"]
        if audio.active { a += ["-map", audio.usesMusic ? "1:a:0" : "0:a:0"] }
        a += CodecArgs.video(codec: codec, crf: crf, cap: cap, grain: grain, width: width, height: height)
        if audio.active {
            a += CodecArgs.audio
            let af = audioFilters
            if !af.isEmpty { a += ["-af", af.joined(separator: ",")] }
            if audio.usesMusic { a += ["-shortest", "-t", Fmt.upTo3(outDuration)] }
        } else {
            a += ["-an"]
        }
        a += CodecArgs.colorTags + ["-movflags", "+faststart"]
        a.append(output)
        return a
    }

    /// Expected output duration, for progress.
    public static func targetDuration(source: Double, trimStart: Double?, trimEnd: Double?) -> Double {
        if let s = trimStart, let e = trimEnd { return e - s }
        if let e = trimEnd { return e }
        if let s = trimStart { return source - s }
        return source
    }
}
