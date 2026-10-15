// Ideal Video Encoder for macOS
// https://github.com/alex-mcdermott/Ideal-Video-Encoder
// Copyright (C) 2026 the Ideal Video Encoder contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import AVFoundation
import AVKit
import IVECore
import SwiftUI

/// The live preview: AVFoundation playback through the encode's look (exposure -> LUT), in Core Image, at the
/// output speed with the output's audio (v1.3). Look changes apply to the next frame; trim, speed and music
/// changes rebuild the gapless loop; mute and loudness apply live.
@MainActor @Observable
final class PreviewModel {
    @ObservationIgnored weak var app: AppModel?
    var nowPlaying: String?
    var isPlaying = false
    var busy: String?
    var isProxy = false
    /// Playback position on the output's timeline, e.g. "0:01.2"
    var timeText = ""
    let player = AVQueuePlayer()

    /// What the current timeline was built for, and the pieces to play it.
    private struct Timeline {
        let key: String
        let speed: Double
        let asset: AVAsset
        let composition: AVVideoComposition
        let mix: AVAudioMix?
    }

    @ObservationIgnored private let look = LockedBox(PreviewLook())
    @ObservationIgnored private let gain = LoudnessGain()
    @ObservationIgnored private var path: String?
    /// The file AVFoundation plays: the source, or its proxy
    @ObservationIgnored private var playURL: URL?
    @ObservationIgnored private var duration: CMTime = .zero
    @ObservationIgnored private var timeline: Timeline?
    @ObservationIgnored private var looper: AVPlayerLooper?
    @ObservationIgnored private var loopRange: CMTimeRange?
    @ObservationIgnored private var isFull = false
    @ObservationIgnored private var lutCache: (path: String, lut: CubeLUT)?
    @ObservationIgnored private var updateTask: Task<Void, Never>?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var rangeCache: [String: Bool] = [:]
    /// Integrated loudness (LUFS) by file, from the encode's first loudnorm pass; -inf when there's no audio
    @ObservationIgnored private var loudness: [String: Double] = [:]
    @ObservationIgnored private var measureTask: Task<Void, Never>?
    @ObservationIgnored private var measuring: String?

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
        isProxy = false
        if !(await PreviewSource.canDecode(AVURLAsset(url: url))) {
            // AVFoundation can't decode it (e.g. hev1-tagged HEVC): play an ffmpeg-made proxy instead
            guard let ffmpeg = app.toolReport?.paths[.ffmpeg] else { app.appendLog("Preview: this file can't be decoded by macOS and ffmpeg is missing."); nowPlaying = nil; return }
            busy = "Making a preview proxy…"
            app.appendLog("Preview: macOS can't decode \(name); making a preview proxy with ffmpeg.")
            do {
                url = URL(fileURLWithPath: try await PreviewSource.makeProxy(ffmpeg: ffmpeg, source: source))
                isProxy = true
            } catch {
                app.appendLog("Preview failed: \(error.localizedDescription)")
                nowPlaying = nil
                return
            }
        }
        guard !Task.isCancelled else { return }
        duration = (try? await AVURLAsset(url: url).load(.duration)) ?? .zero
        playURL = url
        path = source
        timeline = nil
        updateLook()
        guard await rebuild(force: true) else {
            if !Task.isCancelled { nowPlaying = nil }
            return
        }
        player.play()
        isPlaying = true
        if let hw = await HardwareDecode.isSupported(for: AVURLAsset(url: url)) {
            app.appendLog("Preview: \(name)\(isProxy ? " (proxy)" : "") \(Fmt.dot) \(hw ? "hardware" : "software") decoding")
        }
    }

    func stop() {
        loadTask?.cancel()
        updateTask?.cancel()
        stopPlayback()
        nowPlaying = nil
        path = nil
        playURL = nil
        timeline = nil
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
            await self.rebuild(force: false)
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

    /// Mute when audio is off, and the normalising gain: each file (the clip, or the music) is measured once
    /// with the encode's first loudnorm pass, then played at -16 LUFS; the gain changes live.
    private func updateAudio() {
        guard let app else { return }
        player.isMuted = !app.settings.audioEnabled
        guard app.settings.audioEnabled, app.settings.normalizeAudio, let file = app.activeMusic ?? path else {
            gain.decibels = 0
            return
        }
        if let l = loudness[file] { gain.decibels = LoudnessGain.decibels(toTarget: l); return }
        gain.decibels = 0
        guard measuring != file, let ffmpeg = app.toolReport?.paths[.ffmpeg] else { return }
        measuring = file
        measureTask?.cancel()
        measureTask = Task { [weak self] in
            let m = try? await SpeedAudio.measureLoudness(ffmpeg: ffmpeg, inputs: ["-i", file], map: "0:a:0", pre: [], duration: 0)
            guard !Task.isCancelled, let self else { return }
            self.measuring = nil
            let lufs = m?.integrated ?? -.infinity
            self.loudness[file] = lufs
            if lufs.isFinite {
                self.app?.appendLog(String(format: "Preview: loudness %.1f LUFS, playing at %+.1f dB", lufs, LoudnessGain.decibels(toTarget: lufs)))
            }
            self.updateAudio()
        }
    }

    /// The trim range in the source's time (invalid or empty fields mean the whole clip).
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

    /// Builds the timeline for the current speed and music (when they changed) and loops the trim range on it.
    /// Returns false if the preview can't be built.
    @discardableResult
    private func rebuild(force: Bool) async -> Bool {
        guard let app, let playURL, let path else { return false }
        updateAudio()
        let speed = app.speed
        let music = app.activeMusic
        let source = trimRange(duration: duration)
        let loop = CMTimeRange(start: CMTimeMultiplyByFloat64(source.start, multiplier: 1 / speed),
                               end: CMTimeMultiplyByFloat64(source.end, multiplier: 1 / speed))
        // Music starts at the loop's start and fades at its end, so it depends on the loop too
        let key = "\(speed)|" + (music.map { "\($0)|\(loop.start.value)/\(loop.start.timescale)|\(loop.end.value)/\(loop.end.timescale)" } ?? "")
        if force || timeline?.key != key {
            do {
                let asset = try await PreviewTimeline.make(source: AVURLAsset(url: playURL), speed: speed,
                                                           music: music.map { URL(fileURLWithPath: $0) }, musicFrom: loop.start)
                let composition = try await PreviewComposition.make(asset: asset, look: look)
                let mix = await PreviewTimeline.audioMix(for: asset, gain: gain, fadeOutEnding: music == nil ? nil : loop)
                guard !Task.isCancelled, self.path == path else { return false }
                let previous = timeline?.speed
                timeline = Timeline(key: key, speed: speed, asset: asset, composition: composition, mix: mix)
                restartLoop(loop, source: source, previousSpeed: previous, force: force)
            } catch {
                app.appendLog("Preview failed: \(error.localizedDescription)")
                return false
            }
        } else if loop != loopRange {
            restartLoop(loop, source: source, previousSpeed: speed, force: false)
        }
        return true
    }

    private func restartLoop(_ range: CMTimeRange, source: CMTimeRange, previousSpeed: Double?, force: Bool) {
        guard let t = timeline else { return }
        let wasPlaying = force || player.rate != 0
        // Keep the position (in source time) if it is still inside the new range
        var current = player.currentTime()
        if let p = previousSpeed, current.isNumeric { current = CMTimeMultiplyByFloat64(current, multiplier: p / t.speed) }
        looper?.disableLooping()
        player.removeAllItems()
        let template = AVPlayerItem(asset: t.asset)
        template.videoComposition = t.composition
        template.audioMix = t.mix
        template.audioTimePitchAlgorithm = .spectral   // slowed or sped-up clip audio keeps its pitch, like atempo
        looper = AVPlayerLooper(player: player, templateItem: template, timeRange: range)
        if !force || source.duration != duration || !SpeedAudio.isNormal(t.speed) {
            app?.appendLog(String(format: "Preview loops %.2f-%.2f s", source.start.seconds, source.end.seconds)
                           + (SpeedAudio.isNormal(t.speed) ? "" : " at \(Fmt.upTo3(t.speed))x"))
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
        item.videoComposition = timeline?.composition.mutableCopy() as? AVVideoComposition
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
                        Text("Live preview").appFont(.title3, weight: .semibold).foregroundStyle(.white.opacity(0.9))
                        Text("Select a clip and press Preview. Exposure, LUT, trim, speed and audio changes apply instantly.")
                            .appFont(.callout).foregroundStyle(.white.opacity(0.6)).multilineTextAlignment(.center)
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
                    Text(preview.timeText).appFont(.callout, monospacedDigit: true).foregroundStyle(.secondary)
                        .accessibilityLabel("Playback position")
                        .accessibilityValue(preview.timeText)
                }
                Text(preview.nowPlaying.map { $0 + (preview.isProxy ? "  (proxy)" : "") } ?? "")
                    .appFont(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .accessibilityLabel("Now previewing")
                    .accessibilityValue(preview.nowPlaying ?? "nothing")
                Spacer()
            }
        }
        .padding(8)
    }
}
