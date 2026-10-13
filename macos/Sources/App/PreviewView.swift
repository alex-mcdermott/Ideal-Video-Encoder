// Ideal Video Encoder for macOS
// https://github.com/alex-mcdermott/Ideal-Video-Encoder
// Copyright (C) 2026 the Ideal Video Encoder contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import AVFoundation
import AVKit
import IVECore
import SwiftUI

/// The live preview: AVFoundation playback through the encode's look (exposure -> LUT), in Core Image.
/// Look changes apply to the next frame; trim changes rebuild the gapless loop.
@MainActor @Observable
final class PreviewModel {
    @ObservationIgnored weak var app: AppModel?
    var nowPlaying: String?
    var isPlaying = false
    var busy: String?
    var isProxy = false
    /// Playback position, e.g. "0:01.2"
    var timeText = ""
    let player = AVQueuePlayer()

    @ObservationIgnored private let look = LockedBox(PreviewLook())
    @ObservationIgnored private var path: String?
    @ObservationIgnored private var asset: AVAsset?
    @ObservationIgnored private var duration: CMTime = .zero
    @ObservationIgnored private var composition: AVVideoComposition?
    @ObservationIgnored private var looper: AVPlayerLooper?
    @ObservationIgnored private var loopRange: CMTimeRange?
    @ObservationIgnored private var isFull = false
    @ObservationIgnored private var lutCache: (path: String, lut: CubeLUT)?
    @ObservationIgnored private var updateTask: Task<Void, Never>?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var rangeCache: [String: Bool] = [:]

    init() {
        player.automaticallyWaitsToMinimizeStalling = false
        player.actionAtItemEnd = .advance
        player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 10), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self, self.isActive, t.isNumeric else { return }
                let s = max(0, t.seconds)
                self.timeText = String(format: "%d:%04.1f", Int(s) / 60, s.truncatingRemainder(dividingBy: 60))
            }
        }
    }

    var isActive: Bool { nowPlaying != nil }

    /// `Start-Preview`: the selected clip (or the first one).
    func start() {
        guard let app, let item = app.previewTarget else { app?.appendLog("Add a clip to preview."); return }
        loadTask?.cancel()
        loadTask = Task { await load(item.path, name: item.name) }
    }

    private func load(_ source: String, name: String) async {
        guard let app else { return }
        stopPlayback()
        nowPlaying = name
        busy = "Opening…"
        defer { busy = nil }
        // Range decides the exposure offset (see PreviewLook)
        if let cached = rangeCache[source] { isFull = cached }
        else if let ffprobe = app.toolReport?.paths[.ffprobe], let m = try? await Probe.run(ffprobe: ffprobe, path: source) {
            isFull = m.isFullRange; rangeCache[source] = isFull
        }
        var url = URL(fileURLWithPath: source)
        var a: AVAsset = AVURLAsset(url: url)
        isProxy = false
        if !(await PreviewSource.canDecode(a)) {
            // AVFoundation can't decode it (e.g. hev1-tagged HEVC): play an ffmpeg-made proxy instead
            guard let ffmpeg = app.toolReport?.paths[.ffmpeg] else { app.appendLog("Preview: this file can't be decoded by macOS and ffmpeg is missing."); nowPlaying = nil; return }
            busy = "Making a preview proxy…"
            app.appendLog("Preview: macOS can't decode \(name); making a preview proxy with ffmpeg.")
            do {
                url = URL(fileURLWithPath: try await PreviewSource.makeProxy(ffmpeg: ffmpeg, source: source))
                a = AVURLAsset(url: url)
                isProxy = true
            } catch {
                app.appendLog("Preview failed: \(error.localizedDescription)")
                nowPlaying = nil
                return
            }
        }
        guard !Task.isCancelled else { return }
        do {
            updateLook()
            composition = try await PreviewComposition.make(asset: a, look: look)
        } catch {
            app.appendLog("Preview failed: \(error.localizedDescription)")
            nowPlaying = nil
            return
        }
        duration = (try? await a.load(.duration)) ?? .zero
        asset = a
        path = source
        rebuildLoop(force: true)
        player.play()
        isPlaying = true
        if let hw = await HardwareDecode.isSupported(for: AVURLAsset(url: url)) {
            app.appendLog("Preview: \(name)\(isProxy ? " (proxy)" : "") \(Fmt.dot) \(hw ? "hardware" : "software") decoding")
        }
    }

    func stop() {
        loadTask?.cancel()
        stopPlayback()
        nowPlaying = nil
        path = nil
        asset = nil
    }

    private func stopPlayback() {
        player.pause()
        looper?.disableLooping()
        looper = nil
        player.removeAllItems()
        isPlaying = false
    }

    func togglePlay() {
        guard isActive else { start(); return }
        if player.rate == 0 { player.play(); isPlaying = true } else { player.pause(); isPlaying = false }
    }

    /// Debounced, like the Windows preview's 150 ms timer.
    func requestUpdate() {
        guard isActive else { return }
        updateTask?.cancel()
        updateTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled, let self else { return }
            self.updateLook()
            self.rebuildLoop(force: false)
            self.refreshIfPaused()
        }
    }

    private func updateLook() {
        guard let app else { return }
        var lut: CubeLUT?
        if let p = app.currentLut {
            if let c = lutCache, c.path == p { lut = c.lut }
            else {
                do { lut = try CubeLUT.load(p); lutCache = (p, lut!) }
                catch { app.appendLog("Preview: could not read the LUT: \(error.localizedDescription)") }
            }
        }
        look.mutate { $0 = PreviewLook(exposure: app.exposure, isFullRange: isFull, lut: lut) }
    }

    /// The trim range as a loop range (invalid or empty fields mean the whole clip).
    private func trimRange(duration: CMTime) -> CMTimeRange {
        guard let app else { return CMTimeRange(start: .zero, duration: duration) }
        var a: Double?, b: Double?
        if case .seconds(let v) = Trim.parse(app.trimStart) { a = v }
        if case .seconds(let v) = Trim.parse(app.trimEnd) { b = v }
        if let x = a, let y = b, y <= x { b = nil }
        let total = duration.seconds
        let start = min(max(0, a ?? 0), max(0, total - 0.05))
        let end = min(b ?? total, total)
        return CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                           end: CMTime(seconds: max(end, start + 0.05), preferredTimescale: 600))
    }

    private func rebuildLoop(force: Bool) {
        guard let asset, let composition else { return }
        let range = trimRange(duration: duration)
        guard force || range != loopRange else { return }
        let wasPlaying = force || player.rate != 0
        // Keep the current position if it is still inside the new range
        let current = player.currentTime()
        looper?.disableLooping()
        player.removeAllItems()
        let template = AVPlayerItem(asset: asset)
        template.videoComposition = composition
        looper = AVPlayerLooper(player: player, templateItem: template, timeRange: range)
        if !force || range.duration != duration {
            app?.appendLog(String(format: "Preview loops %.2f-%.2f s", range.start.seconds, range.end.seconds))
        }
        loopRange = range
        if !force, range.containsTime(current) {
            player.seek(to: current, toleranceBefore: .zero, toleranceAfter: .zero)
        }
        if wasPlaying { player.play() } else { player.pause() }
    }

    /// A paused player keeps showing the old frame; re-render it with the new look.
    private func refreshIfPaused() {
        guard player.rate == 0, let item = player.currentItem else { return }
        item.videoComposition = composition?.mutableCopy() as? AVVideoComposition
        player.seek(to: player.currentTime(), toleranceBefore: .zero, toleranceAfter: .zero)
    }
}

/// AVPlayerView without its own controls (the transport lives below the video).
struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = player
        v.controlsStyle = .none
        v.videoGravity = .resizeAspect
        v.setAccessibilityLabel("Preview video")
        return v
    }
    func updateNSView(_ v: AVPlayerView, context: Context) { if v.player !== player { v.player = player } }
}

struct PreviewPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let preview = model.preview
        VStack(spacing: 6) {
            ZStack {
                Color.black
                if preview.isActive {
                    PlayerSurface(player: preview.player)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "play.rectangle").font(.system(size: 40)).foregroundStyle(.white.opacity(0.8))
                        Text("Live preview").font(.title3.weight(.semibold)).foregroundStyle(.white.opacity(0.9))
                        Text("Select a clip and press Preview. Exposure, LUT and trim changes apply instantly.")
                            .font(.callout).foregroundStyle(.white.opacity(0.6)).multilineTextAlignment(.center)
                    }
                    .padding()
                    .accessibilityElement(children: .combine)
                }
                if let busy = preview.busy {
                    VStack(spacing: 8) { ProgressView().controlSize(.large).tint(.white); Text(busy).foregroundStyle(.white) }
                        .padding(16)
                        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
                        .accessibilityElement(children: .combine)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))

            HStack(spacing: 8) {
                Button { model.preview.start() } label: { Label("Preview", systemImage: "play.rectangle") }
                    .disabled(model.items.isEmpty)
                    .help("Preview the selected clip (Return or double-click in the queue)")
                Button { model.preview.togglePlay() } label: {
                    Label(preview.isPlaying ? "Pause" : "Play", systemImage: preview.isPlaying ? "pause.fill" : "play.fill")
                        .labelStyle(.iconOnly)
                }
                .disabled(!preview.isActive)
                .help("Play / pause (Space)")
                .accessibilityLabel(preview.isPlaying ? "Pause preview" : "Play preview")
                Button { model.preview.stop() } label: { Label("Stop", systemImage: "stop.fill").labelStyle(.iconOnly) }
                    .disabled(!preview.isActive)
                    .help("Stop the preview")
                    .accessibilityLabel("Stop preview")
                if preview.isActive {
                    Text(preview.timeText).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        .accessibilityLabel("Playback position")
                        .accessibilityValue(preview.timeText)
                }
                Text(preview.nowPlaying.map { $0 + (preview.isProxy ? "  (proxy)" : "") } ?? "")
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .accessibilityLabel("Now previewing")
                    .accessibilityValue(preview.nowPlaying ?? "nothing")
                Spacer()
            }
        }
        .padding(8)
    }
}
