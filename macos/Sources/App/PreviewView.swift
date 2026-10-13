// Ideal Video Encoder for macOS
// https://github.com/alex-mcdermott/Ideal-Video-Encoder
// Copyright (C) 2026 the Ideal Video Encoder contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import IVECore
import SwiftUI

/// Preview state (filled in by the AVFoundation preview milestone).
@MainActor @Observable
final class PreviewModel {
    @ObservationIgnored weak var app: AppModel?
    var nowPlaying: String?
    var isPlaying = false

    func start() {
        guard let item = app?.previewTarget else { app?.appendLog("Add a clip to preview."); return }
        nowPlaying = item.name
    }
    func stop() { nowPlaying = nil; isPlaying = false }
    func togglePlay() { isPlaying.toggle() }
    func requestUpdate() {}
}

struct PreviewPane: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        ZStack {
            Color.black
            VStack(spacing: 8) {
                Image(systemName: "play.rectangle").font(.system(size: 40)).foregroundStyle(.white.opacity(0.8))
                Text("Live preview").font(.title3.weight(.semibold)).foregroundStyle(.white.opacity(0.9))
                Text("Select a clip and press Preview. Exposure, LUT and trim changes apply instantly.")
                    .font(.callout).foregroundStyle(.white.opacity(0.6)).multilineTextAlignment(.center)
            }
            .padding()
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(8)
    }
}
