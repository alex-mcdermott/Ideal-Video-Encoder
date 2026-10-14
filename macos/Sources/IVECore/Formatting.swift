// Ideal Video Encoder for macOS
// https://github.com/alex-mcdermott/Ideal-Video-Encoder
// Copyright (C) 2026 the Ideal Video Encoder contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Number and time formatting that reproduces what the Windows script prints with
/// .NET's invariant culture, so arguments, logs and CSV rows are byte-identical.
public enum Fmt {
    /// .NET `Double.ToString(InvariantCulture)`: shortest round-trip form, no trailing ".0".
    public static func num(_ v: Double) -> String {
        if v.isNaN { return "NaN" }
        if v.isInfinite { return v < 0 ? "-Infinity" : "Infinity" }
        if v == v.rounded(), abs(v) < 1e15 { return String(Int64(v)) }
        return "\(v)".replacingOccurrences(of: "e", with: "E")
    }

    /// .NET `Math.Round(v, digits)` (midpoints to even).
    public static func round(_ v: Double, _ digits: Int) -> Double {
        let scale = pow(10.0, Double(digits))
        return (v * scale).rounded(.toNearestOrEven) / scale
    }

    /// Custom formats "0", "0.0", "0.00", "0.000".
    public static func fixed(_ v: Double, _ decimals: Int) -> String {
        let s = String(format: "%.\(decimals)f", v)
        // "-0.0" -> "0.0", as .NET prints negative zero
        if s.hasPrefix("-"), Double(s) == 0 { return String(s.dropFirst()) }
        return s
    }

    /// Custom format "0.#" (at most one decimal, no trailing zero).
    public static func upTo1(_ v: Double) -> String {
        var s = fixed(v, 1)
        if s.hasSuffix(".0") { s.removeLast(2) }
        return s
    }

    /// Custom format "+0.0;-0.0;0.0" used for exposure.
    public static func signed1(_ v: Double) -> String {
        let s = fixed(abs(v), 1)
        if s == "0.0" { return s }
        return (v < 0 ? "-" : "+") + s
    }

    /// TimeSpan "hh\:mm\:ss" (hours keep counting past 24 rather than wrapping).
    public static func clock(_ seconds: Double) -> String {
        let t = max(0, Int(seconds.rounded(.down)))
        return String(format: "%02d:%02d:%02d", t / 3600, (t / 60) % 60, t % 60)
    }

    /// `Format-Duration`: "m:ss", or "h:mm:ss" from one hour.
    public static func duration(_ seconds: Double) -> String {
        let t = Int(seconds.rounded(.toNearestOrEven))
        if t >= 3600 { return String(format: "%d:%02d:%02d", t / 3600, (t / 60) % 60, t % 60) }
        return String(format: "%d:%02d", t / 60, t % 60)
    }

    /// `Format-Size`: "0.00 GB" from 1 GiB, otherwise "0 MB" (binary units, as on Windows).
    public static func size(_ bytes: Double) -> String {
        if bytes >= 1_073_741_824 { return fixed(bytes / 1_073_741_824, 2) + " GB" }
        return fixed(bytes / 1_048_576, 0) + " MB"
    }

    public static let dot = "\u{00B7}"
    public static let arrow = "\u{2192}"
}
