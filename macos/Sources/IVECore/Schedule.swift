// Ideal Video Encoder for macOS
// https://github.com/alex-mcdermott/Ideal-Video-Encoder
// Copyright (C) 2026 the Ideal Video Encoder contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// When to start: now, or later at a time of day typed by the user (v1.2).
public enum StartWhen: String, CaseIterable, Sendable, Identifiable {
    case now = "Now", later = "Later at"
    public var id: String { rawValue }
}

public enum Schedule {
    public struct TimeOfDay: Sendable, Equatable {
        public var hour: Int
        public var minute: Int
        public init(hour: Int, minute: Int) { self.hour = hour; self.minute = minute }
    }

    /// `ConvertTo-TimeOfDay`: "04:30", "4:30", "4.30", "0430", "16:45", "4:30 pm", "4pm" -> time of day; nil if not a time.
    public static func parse(_ text: String) -> TimeOfDay? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: ".", with: ":")
        guard let re = try? NSRegularExpression(pattern: #"^(\d{1,2})(?::?(\d{2}))?(am|pm|a|p)?$"#),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        func group(_ i: Int) -> String? { Range(m.range(at: i), in: s).map { String(s[$0]) } }
        guard var h = group(1).flatMap(Int.init) else { return nil }
        let mins = group(2).flatMap(Int.init) ?? 0
        if let ap = group(3) {
            if h < 1 || h > 12 { return nil }
            if ap.hasPrefix("p") && h < 12 { h += 12 }
            if ap.hasPrefix("a") && h == 12 { h = 0 }
        }
        if h > 23 || mins > 59 { return nil }
        return TimeOfDay(hour: h, minute: mins)
    }

    /// `Get-NextStartUtc`: the next occurrence of a local time of day in the calendar's time zone. A time skipped by
    /// the spring-forward gap starts just after the gap (02:30 for 01:30 when clocks jump from 01:00 to 02:00);
    /// a repeated time in the autumn uses its second (standard-time) occurrence, as .NET's ConvertTimeToUtc does.
    public static func nextStart(_ t: TimeOfDay, after now: Date = Date(), calendar: Calendar = .current) -> Date {
        calendar.nextDate(after: now, matching: DateComponents(hour: t.hour, minute: t.minute, second: 0),
                          matchingPolicy: .nextTimePreservingSmallerComponents, repeatedTimePolicy: .last, direction: .forward)
            ?? now.addingTimeInterval(86_400)
    }

    /// `Format-Countdown`: total hours, then mm:ss.
    public static func countdown(_ seconds: Double) -> String {
        let t = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d:%02d", t / 3600, (t / 60) % 60, t % 60)
    }

    /// `Format-LocalStart`: "Tue 04:30" plus the time zone's name unless `zone` is false.
    public static func localStart(_ date: Date, zone: Bool = true, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let day = DateFormatter(); day.calendar = calendar; day.timeZone = calendar.timeZone; day.locale = locale; day.dateFormat = "EEE"
        let time = DateFormatter(); time.calendar = calendar; time.timeZone = calendar.timeZone; time.locale = locale
        time.dateStyle = .none; time.timeStyle = .short
        var s = "\(day.string(from: date)) \(time.string(from: date))"
        if zone {
            let tz = calendar.timeZone
            let name = tz.localizedName(for: tz.isDaylightSavingTime(for: date) ? .daylightSaving : .standard, locale: locale) ?? tz.identifier
            s += " " + name
        }
        return s
    }

    /// `Update-ScheduleUi`'s hint: "Starts Tue 04:30 British Summer Time, in 5 h 32 min".
    public static func hint(for text: String, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        guard let t = parse(text) else { return "Enter a time, e.g. 04:30 or 4:30 pm." }
        let at = nextStart(t, after: now, calendar: calendar)
        let left = at.timeIntervalSince(now)
        let inText: String
        if left < 60 { inText = "in under a minute" }
        else if left < 3600 { inText = "in \(Int((left / 60).rounded(.up))) min" }
        else { inText = "in \(Int(left / 3600)) h \(Int(left.truncatingRemainder(dividingBy: 3600) / 60)) min" }
        return "Starts \(localStart(at, calendar: calendar, locale: locale)), \(inText)"
    }
}
