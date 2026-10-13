// Ideal Video Encoder for macOS
// https://github.com/alex-mcdermott/Ideal-Video-Encoder
// Copyright (C) 2026 the Ideal Video Encoder contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import IVECore
import SwiftUI

/// Analysis tab state (filled in by the analysis milestone).
@MainActor @Observable
final class AnalysisModel {
    @ObservationIgnored weak var app: AppModel?
    var isRunning = false
    func cancel() {}
}

struct AnalysisView: View {
    var body: some View {
        ContentUnavailableView("Find the right CRF and cap for your footage", systemImage: "chart.xyaxis.line",
                               description: Text("Pick a quality target and press Analyse."))
    }
}
