// Ideal Video Encoder for macOS
// https://github.com/alex-mcdermott/Ideal-Video-Encoder
// Copyright (C) 2026 the Ideal Video Encoder contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A validated snapshot of the settings for one run (the script's `$Opt`).
public struct RunOptions: Sendable, Equatable {
    public var codec: Codec = .hevc
    public var crf = 21
    public var autoCrf = false
    public var grain: Grain = .off
    public var autoGrain = false
    public var vbrEnabled = true
    public var maxRate = 35.0
    public var exposure = 0.0
    public var lutPath: String?
    public var trimStart: Double?
    public var trimEnd: Double?
    public var outputMode: OutputMode = .source
    public var outputFolder = ""
    public var subfolder = "From FFmpeg"
    public var csvEnabled = false
    public var csvPath = ""
    /// Analysis only.
    public var targetVmaf = 95.0
    /// Encode: 0 = off, else measure each clip for this VMAF (93/95/97) before encoding it.
    public var qualityTarget = 0
    /// Everything a measured CRF depends on (`Get-LookKey`); per-clip results are reused only when it matches.
    public var lookKey = ""
    /// Per-clip results ("Use per clip" or earlier quality-target runs), by source path.
    public var overrides: [String: ClipOverride] = [:]

    public init() {}

    public var cap: Double { vbrEnabled ? maxRate : 0 }
    public var exposureText: String { Fmt.signed1(exposure) }
    public var vbvText: String { vbrEnabled ? Fmt.num(maxRate) + "M" : "off" }

    /// `Get-RunOptions`. Throws a `ProcessError` with the same message the Windows app shows.
    /// `exposure` is the slider value; `trimStart`/`trimEnd` are the raw field texts.
    public static func validate(settings s: AppSettings, exposure: Double, trimStart: String, trimEnd: String,
                                forAnalysis: Bool = false) throws -> RunOptions {
        var o = RunOptions()
        o.qualityTarget = s.qualityTarget
        o.lookKey = lookKey(settings: s, exposure: exposure)
        o.autoCrf = s.autoCrf
        o.autoGrain = s.autoGrain
        o.codec = s.codec
        let crfText = s.crf(for: s.codec).trimmingCharacters(in: .whitespaces)
        if let c = Int(crfText), c >= 0, c <= s.codec.maxCrf {
            o.crf = c
        } else {
            if !o.autoCrf && o.qualityTarget == 0 { throw ProcessError("CRF must be a whole number from 0 to \(s.codec.maxCrf) for \(s.codec.displayName).") }
            o.crf = s.codec == .av1 ? CodecArgs.av1Crf(fromHevc: 21) : 21
        }
        o.grain = s.grainLevel

        o.vbrEnabled = s.vbrEnabled
        let rate = Trim.parseFloat(s.maxRate) ?? 0
        if o.vbrEnabled && o.qualityTarget == 0 && rate <= 0 { throw ProcessError("Max rate must be a positive number of Mbps.") }
        o.maxRate = rate

        o.exposure = Fmt.round(exposure, 1)
        if s.lutEnabled {
            guard !s.lutPath.isEmpty, FileManager.default.fileExists(atPath: s.lutPath) else {
                throw ProcessError("Choose a LUT file, or turn off Apply LUT.")
            }
            o.lutPath = s.lutPath
        }

        let a = Trim.parse(trimStart), b = Trim.parse(trimEnd)
        if a == .invalid || b == .invalid { throw ProcessError("Trim times must be seconds (90) or mm:ss (1:30).") }
        if case .seconds(let v) = a { o.trimStart = v }
        if case .seconds(let v) = b { o.trimEnd = v }
        if let x = o.trimStart, let y = o.trimEnd, y <= x { throw ProcessError("Trim end must be after the start.") }

        if forAnalysis { return o }

        o.outputMode = s.outputMode
        o.outputFolder = s.outputFolder.trimmingCharacters(in: .whitespacesAndNewlines)
        if o.outputMode == .custom, let err = OutputPaths.validateCustomFolder(o.outputFolder) { throw ProcessError(err) }
        o.subfolder = OutputPaths.cleanSubfolder(s.subfolder)
        if let err = OutputPaths.validateSubfolder(o.subfolder) { throw ProcessError(err) }

        o.csvEnabled = s.csvEnabled
        o.csvPath = s.csvPath
        return o
    }
}

extension RunOptions {
    /// `Get-LookKey`: "codec|EV|LUT path (when applied)|grain index|auto grain".
    public static func lookKey(settings s: AppSettings, exposure: Double) -> String {
        let lut = s.lutEnabled && !s.lutPath.isEmpty && FileManager.default.fileExists(atPath: s.lutPath) ? s.lutPath : ""
        return "\(s.codec.rawValue)|\(Fmt.num(Fmt.round(exposure, 1)))|\(lut)|\(s.grainLevel.rawValue)|\(s.autoGrain ? "True" : "False")"
    }
}

/// Source signals used by Auto CRF / Auto grain (`Analyze-Clip`).
public struct ClipSignals: Sendable, Equatable {
    public var motion: Double?
    public var colour: Double?
    public var brightMin: Int?
    public var brightMax: Int?
    /// Never computed by the Windows script, so the detail rules never fire; kept for parity.
    public var detailVar: Double?
    public var noisePSNR: Double?
    public init() {}
}

public enum ClipAnalysis {
    /// Pass A: signalstats averaged over all frames. `-v info` is required: metadata=print logs at info level.
    public static func statsArguments(_ path: String) -> [String] {
        ["-v", "info", "-nostdin", "-hide_banner", "-i", path, "-vf", "scale=iw/2:ih/2,format=yuv420p,signalstats,metadata=print", "-f", "null", "-"]
    }

    /// Pass B: noise proxy via denoised-vs-original PSNR (the summary also logs at info level).
    public static func noiseArguments(_ path: String) -> [String] {
        ["-v", "info", "-nostdin", "-hide_banner", "-i", path, "-filter_complex", "[0:v]scale=iw/2:ih/2,split=2[a][b];[b]hqdn3d=4:4:6:6[dn];[a][dn]psnr", "-f", "null", "-"]
    }

    /// Accumulates pass A lines.
    public struct StatsAccumulator: Sendable {
        var ydif = 0.0, nd = 0, sat = 0.0, ns = 0
        public var brightMin: Int?
        public var brightMax: Int?
        public init() {}

        public mutating func add(_ line: String) {
            if let v = Self.match(line, "signalstats\\.YDIF=([\\d\\.]+)").flatMap(Double.init) { ydif += v; nd += 1 }
            else if let v = Self.match(line, "signalstats\\.SATAVG=([\\d\\.]+)").flatMap(Double.init) { sat += v; ns += 1 }
            else if let v = Self.match(line, "signalstats\\.YMIN=(\\d+)").flatMap(Int.init) { brightMin = min(brightMin ?? v, v) }
            else if let v = Self.match(line, "signalstats\\.YMAX=(\\d+)").flatMap(Int.init) { brightMax = max(brightMax ?? v, v) }
        }
        public var motion: Double? { nd > 0 ? ydif / Double(nd) : nil }
        public var colour: Double? { ns > 0 ? sat / Double(ns) : nil }

        static func match(_ s: String, _ pattern: String) -> String? {
            guard let r = s.range(of: pattern, options: .regularExpression) else { return nil }
            let m = String(s[r])
            return m.split(separator: "=", maxSplits: 1).last.map(String.init)
        }
    }

    /// Pass B: the last "PSNR ... average:x" value.
    public static func psnr(from line: String) -> Double? {
        guard line.range(of: "PSNR ", options: []) != nil,
              let r = line.range(of: "average:([\\d\\.]+)", options: .regularExpression) else { return nil }
        return Double(line[r].dropFirst("average:".count))
    }

    public static func run(ffmpeg: String, path: String) async throws -> ClipSignals {
        var result = ClipSignals()
        let acc = LockedBox(StatsAccumulator())
        _ = try? await ProcessRunner.streamStderr(ffmpeg, statsArguments(path)) { line in acc.mutate { $0.add(line) } }
        try Task.checkCancellation()
        let s = acc.value
        result.motion = s.motion; result.colour = s.colour; result.brightMin = s.brightMin; result.brightMax = s.brightMax
        let noise = LockedBox<Double?>(nil)
        _ = try? await ProcessRunner.streamStderr(ffmpeg, noiseArguments(path)) { line in
            if let v = psnr(from: line) { noise.mutate { $0 = v } }
        }
        try Task.checkCancellation()
        result.noisePSNR = noise.value
        return result
    }
}

/// The worker's Auto grain / Auto CRF rules.
public enum AutoRules {
    public static func grain(manual: Grain, auto: Bool, isFLog2: Bool, iso: Int?, psnr: Double?) -> Grain {
        guard auto else { return manual }
        var g = 0
        if isFLog2 || (iso ?? 0) >= 3200 { g = 2 }
        if let p = psnr, p != 0, p < 35 { g = max(g, 2) }
        else if let p = psnr, p != 0, p < 38 { g = max(g, 1) }
        return Grain(rawValue: g) ?? .off
    }

    public static func crf(manual: Int, auto: Bool, codec: Codec, isFLog2: Bool, iso: Int?, signals: ClipSignals) -> Int {
        guard auto else { return manual }
        var crf = 22
        if let p = signals.noisePSNR, p != 0 {
            if p < 35 { crf -= 3 } else if p < 38 { crf -= 2 } else if p < 40 { crf -= 1 }
        } else if isFLog2 || (iso ?? 0) >= 3200 {
            crf -= 2
        }
        if let m = signals.motion, m != 0, m > 50 { crf -= 1 }
        if let d = signals.detailVar, d != 0, d > 8000 { crf -= 1 }
        if let m = signals.motion, m != 0, m < 10, let d = signals.detailVar, d != 0, d < 3000 { crf += 1 }
        crf = min(24, max(16, crf))
        return codec == .av1 ? CodecArgs.av1Crf(fromHevc: crf) : crf
    }

    /// Analysis tab: no noise pass, just ISO / F-Log2.
    public static func analysisGrain(manual: Grain, auto: Bool, isFLog2: Bool, iso: Int?) -> Grain {
        guard auto else { return manual }
        return (isFLog2 || (iso ?? 0) >= 3200) ? .strong : .off
    }
}

/// A tiny lock-protected box for values written from process-reading threads.
public final class LockedBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    public init(_ v: T) { _value = v }
    public var value: T { lock.lock(); defer { lock.unlock() }; return _value }
    public func mutate(_ f: (inout T) -> Void) { lock.lock(); f(&_value); lock.unlock() }
}
