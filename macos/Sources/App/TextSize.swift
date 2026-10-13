// Ideal Video Encoder for macOS
// https://github.com/alex-mcdermott/Ideal-Video-Encoder
// Copyright (C) 2026 the Ideal Video Encoder contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// In-app text size (View > Bigger / Smaller / Actual Size). SwiftUI on macOS doesn't scale text with Dynamic
/// Type, so the app scales its own fonts: every view uses `.appFont(_:)`, and the window's default font follows.
enum TextSize {
    static let steps: [CGFloat] = [1.0, 1.15, 1.3, 1.5]
    static let key = "TextSizeStep"

    /// macOS point sizes of the text styles the app uses.
    static func base(_ style: Font.TextStyle) -> CGFloat {
        switch style {
        case .largeTitle: 26
        case .title: 22
        case .title2: 17
        case .title3: 15
        case .headline, .body: 13
        case .callout: 12
        case .subheadline: 11
        default: 10   // footnote, caption, caption2
        }
    }
}

private struct TextScaleKey: EnvironmentKey { static let defaultValue: CGFloat = 1 }

extension EnvironmentValues {
    var textScale: CGFloat {
        get { self[TextScaleKey.self] }
        set { self[TextScaleKey.self] = newValue }
    }
}

private struct AppFont: ViewModifier {
    @Environment(\.textScale) private var scale
    let style: Font.TextStyle
    var weight: Font.Weight?
    var design: Font.Design = .default
    var monospacedDigit = false

    func body(content: Content) -> some View {
        var f = Font.system(size: TextSize.base(style) * scale, weight: weight ?? (style == .headline ? .semibold : .regular), design: design)
        if monospacedDigit { f = f.monospacedDigit() }
        return content.font(f)
    }
}

extension View {
    func appFont(_ style: Font.TextStyle, weight: Font.Weight? = nil, design: Font.Design = .default, monospacedDigit: Bool = false) -> some View {
        modifier(AppFont(style: style, weight: weight, design: design, monospacedDigit: monospacedDigit))
    }

    /// Root of each window: the scale, the default (body) font and a larger control size at the biggest steps.
    func textSizeRoot(_ scale: CGFloat) -> some View {
        environment(\.textScale, scale)
            .font(.system(size: 13 * scale))
            .controlSize(scale >= 1.3 ? .large : .regular)
    }
}
