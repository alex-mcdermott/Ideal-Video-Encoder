// Ideal Video Encoder for macOS
// https://github.com/alex-mcdermott/Ideal-Video-Encoder
// Copyright (C) 2026 the Ideal Video Encoder contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A frame rate as the rational ffprobe reports (`r_frame_rate`, e.g. 30000/1001).
public struct FrameRate: Sendable, Equatable {
    public var num: Double
    public var den: Double
    public init(num: Double, den: Double) { self.num = num; self.den = den }
    public static let fallback = FrameRate(num: 30, den: 1)
    public var fps: Double { num / den }

    /// "30000/1001" -> 30000/1001; anything else -> 30/1, as `Get-FrameRate` does.
    public static func parse(_ s: String?) -> FrameRate {
        guard let s, let r = s.range(of: #"^(\d+)/(\d+)$"#, options: .regularExpression) else { return fallback }
        let p = s[r].split(separator: "/")
        guard let n = Double(p[0]), let d = Double(p[1]), d > 0 else { return fallback }
        return FrameRate(num: n, den: d)
    }
}

/// Speed and audio, ported from Windows v1.3.0 (`Get-SpeedFilters`, `Get-AtempoFilters`, `Get-LoudnormFilter`).
public enum SpeedAudio {
    /// The speed menu (0.125x to 8x); 1x is the default and isn't saved.
    public static let speeds: [Double] = [0.125, 0.25, 0.5, 0.75, 1, 1.5, 2, 4, 8]

    public static func isNormal(_ speed: Double) -> Bool { abs(speed - 1) < 0.0001 }

    public static func label(_ speed: Double) -> String { isNormal(speed) ? "1x (normal)" : Fmt.upTo3(speed) + "x" }

    public static func hint(_ speed: Double) -> String {
        if speed < 1 { return "Slower. High-frame-rate footage plays smoothly (120 fps at 0.25x becomes 30 fps)." }
        if speed > 1 { return "Faster. Frames are dropped to keep the frame rate." }
        return "Normal speed."
    }

    /// Video filters for a speed change. Slowing down high-frame-rate footage conforms it (120 fps at 0.25x plays as
    /// smooth 30 fps); otherwise the source frame rate is kept (frames repeat when slowed, drop when sped up).
    public static func speedFilters(_ speed: Double, rate fr: FrameRate) -> [String] {
        if isNormal(speed) { return [] }
        var rate = "\(Fmt.num(fr.num))/\(Fmt.num(fr.den))"
        if speed < 1 && fr.num * speed / fr.den >= 23.9 { rate = "\(Fmt.upTo3(fr.num * speed))/\(Fmt.num(fr.den))" }
        return ["setpts=PTS/\(Fmt.num(speed))", "fps=fps=\(rate)"]
    }

    /// Pitch-preserving tempo change; atempo takes 0.5-100 per instance, so it is chained for slower speeds.
    public static func atempoFilters(_ speed: Double) -> [String] {
        if isNormal(speed) { return [] }
        var f: [String] = [], s = speed
        while s < 0.5 { f.append("atempo=0.5"); s /= 0.5 }
        if abs(s - 1) > 0.0001 { f.append("atempo=" + Fmt.num(s)) }
        return f
    }

    /// Output length after trim and speed.
    public static func outDuration(source: Double, trimStart: Double?, trimEnd: Double?, speed: Double) -> Double {
        EncodeCommand.targetDuration(source: source, trimStart: trimStart, trimEnd: trimEnd) / speed
    }

    /// Fade-out of a replacement music track: min(2 s, a quarter of the output), ending with the output.
    public static func fadeFilter(outDuration d: Double) -> String? {
        guard d > 0 else { return nil }
        let fade = min(2.0, d / 4)
        return "afade=t=out:st=\(Fmt.upTo3(d - fade)):d=\(Fmt.upTo3(fade))"
    }

    // MARK: loudness (EBU R128, two passes)

    /// "Normalise loudness" target.
    public static let loudnormTarget = "I=-16:TP=-1.5:LRA=11"

    /// First pass: measure the audio exactly as it will be encoded (`Get-LoudnormFilter`).
    public static func loudnormMeasureArguments(inputs: [String], map: String, pre: [String], duration: Double) -> [String] {
        var a = ["-hide_banner", "-nostdin"] + inputs + ["-map", map, "-vn", "-af", (pre + ["loudnorm=\(loudnormTarget):print_format=json"]).joined(separator: ",")]
        if duration > 0 { a += ["-t", Fmt.upTo3(duration)] }
        return a + ["-f", "null", "-"]
    }

    public struct Loudness: Sendable, Equatable {
        public var inputI: String, inputTP: String, inputLRA: String, inputThresh: String, targetOffset: String
        /// Second pass, applied in linear mode.
        public var secondPassFilter: String {
            "loudnorm=\(loudnormTarget):measured_I=\(inputI):measured_TP=\(inputTP):measured_LRA=\(inputLRA):measured_thresh=\(inputThresh):offset=\(targetOffset):linear=true"
        }
        public var integrated: Double? { Double(inputI) }
    }

    /// The JSON block loudnorm prints at the end of the first pass.
    public static func parseLoudness(_ stderr: String) -> Loudness? {
        guard let r = stderr.range(of: #"\{[^{}]*"input_i"[^{}]*\}"#, options: .regularExpression),
              let obj = try? JSONSerialization.jsonObject(with: Data(stderr[r].utf8)) as? [String: Any] else { return nil }
        func v(_ k: String) -> String? { (obj[k] as? String) ?? (obj[k] as? NSNumber)?.stringValue }
        guard let i = v("input_i"), let tp = v("input_tp"), let lra = v("input_lra"), let th = v("input_thresh"),
              let off = v("target_offset") else { return nil }
        return Loudness(inputI: i, inputTP: tp, inputLRA: lra, inputThresh: th, targetOffset: off)
    }

    /// Runs the first pass; cancellable (the ffmpeg process is killed with the task).
    public static func measureLoudness(ffmpeg: String, inputs: [String], map: String, pre: [String], duration: Double,
                                       niceness: Int32 = 10) async throws -> Loudness {
        let lines = LockedBox<[String]>([])
        let code = try await ProcessRunner.streamStderr(ffmpeg, loudnormMeasureArguments(inputs: inputs, map: map, pre: pre, duration: duration),
                                                        niceness: niceness) { l in lines.mutate { $0.append(l) } }
        if Task.isCancelled { throw CancellationError() }
        let text = lines.value.joined(separator: "\n")
        if code != 0 { throw ProcessError("ffmpeg failed: " + lines.value.filter { !$0.isEmpty }.suffix(3).joined(separator: " | ")) }
        guard let l = parseLoudness(text) else { throw ProcessError("loudness measurement failed") }
        return l
    }

    public static let musicExtensions = ["mp3", "m4a", "aac", "wav", "flac", "ogg", "opus", "aif", "aiff"]
}

extension Probe {
    /// `Test-HasAudio`: whether the file has any audio stream.
    public static func hasAudio(ffprobe: String, path: String) async -> Bool {
        guard let r = try? await ProcessRunner.run(ffprobe, ["-v", "error", "-select_streams", "a", "-show_entries", "stream=index", "-of", "csv=p=0", path]) else { return false }
        return !r.lines.isEmpty
    }
}
