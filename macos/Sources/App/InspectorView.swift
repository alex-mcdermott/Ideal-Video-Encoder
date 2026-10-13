// Ideal Video Encoder for macOS
// https://github.com/alex-mcdermott/Ideal-Video-Encoder
// Copyright (C) 2026 the Ideal Video Encoder contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import IVECore
import SwiftUI

struct InspectorView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            LookSection()
            EncodingSection()
            TrimSection()
            OutputSection()
        }
        .formStyle(.grouped)
        .disabled(model.isLocked)
    }
}

/// A short validation message under a field.
struct FieldError: View {
    let text: String?
    var body: some View {
        if let text {
            Label(text, systemImage: "exclamationmark.circle.fill")
                .font(.callout)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Problem: \(text)")
        }
    }
}

struct Caption: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Look

struct LookSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Section("Look") {
            Toggle("Apply LUT", isOn: $model.settings.lutEnabled)
                .accessibilityLabel("Apply LUT")
                .help("Apply a 3D LUT (.cube) after the exposure adjustment")
            HStack {
                Text(model.settings.lutPath.isEmpty ? "No LUT selected" : (model.settings.lutPath as NSString).lastPathComponent)
                    .lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(model.settings.lutPath.isEmpty ? .secondary : .primary)
                    .help(model.settings.lutPath)
                    .accessibilityLabel("LUT file")
                    .accessibilityValue(model.settings.lutPath.isEmpty ? "None" : (model.settings.lutPath as NSString).lastPathComponent)
                Spacer()
                Button("Choose…") { model.chooseLut() }
                    .accessibilityLabel("Choose LUT file")
            }
            if model.settings.lutEnabled && model.currentLut == nil {
                FieldError(text: "Choose a LUT file, or turn off Apply LUT.")
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Exposure")
                    Spacer()
                    Text(Fmt.signed1(model.exposure) + " EV").monospacedDigit().foregroundStyle(.secondary)
                    Button { model.exposure = 0 } label: { Image(systemName: "arrow.counterclockwise") }
                        .buttonStyle(.borderless)
                        .help("Reset exposure to 0")
                        .accessibilityLabel("Reset exposure")
                        .disabled(model.exposure == 0)
                }
                Slider(value: Binding(get: { model.exposure }, set: { model.exposure = Fmt.round($0, 1) }), in: -2...2, step: 0.1) {
                    Text("Exposure")
                } minimumValueLabel: {
                    Text("−2").font(.caption).accessibilityLabel("Minus 2 stops")
                } maximumValueLabel: {
                    Text("+2").font(.caption).accessibilityLabel("Plus 2 stops")
                }
                    .labelsHidden()
                    .accessibilityValue(Fmt.signed1(model.exposure) + " stops")
                    .onChange(of: model.exposure) { _, _ in model.preview.requestUpdate() }
                Caption("Stops, applied before the LUT using the F‑Log2 curve.")
            }
        }
    }
}

// MARK: - Encoding

struct EncodingSection: View {
    @Environment(AppModel.self) private var model

    var crfError: String? {
        let s = model.settings
        if s.autoCrf { return nil }
        let t = model.crfText.trimmingCharacters(in: .whitespaces)
        if let c = Int(t), c >= 0, c <= s.codec.maxCrf { return nil }
        return "Whole number from 0 to \(s.codec.maxCrf)."
    }

    var rateError: String? {
        guard model.settings.vbrEnabled else { return nil }
        let t = model.settings.maxRate.trimmingCharacters(in: .whitespaces)
        if let v = Double(t), v > 0, t.range(of: #"^[+]?(\d+\.?\d*|\.\d+)$"#, options: .regularExpression) != nil { return nil }
        return "A positive number of Mbps."
    }

    var body: some View {
        @Bindable var model = model
        Section("Encoding") {
            VStack(alignment: .leading, spacing: 4) {
                Picker("Codec", selection: $model.settings.codec) {
                    ForEach(Codec.allCases) { Text($0.menuName).tag($0) }
                }
                .accessibilityLabel("Codec")
                Caption(model.settings.codec == .av1
                        ? "Smaller files; needs a newer device to play. Saves .MP4."
                        : "Plays almost everywhere, including all Apple devices. Saves .MOV.")
                    .help(model.settings.codec == .av1
                          ? "Hardware AV1 playback: iPhone 15 Pro / M3 Mac and later, NVIDIA RTX 30+, AMD RX 6000+, Intel 11th gen+. Other devices fall back to software decoding."
                          : "")
            }
            VStack(alignment: .leading, spacing: 4) {
                LabeledContent("Quality (CRF)") {
                    HStack(spacing: 12) {
                        TextField("Quality (CRF)", text: Binding(get: { model.crfText }, set: { model.crfText = $0 }))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 52)
                            .multilineTextAlignment(.center)
                            .labelsHidden()
                            .disabled(model.settings.autoCrf)
                        Toggle("Auto", isOn: $model.settings.autoCrf)
                            .toggleStyle(.checkbox)
                            .accessibilityLabel("Automatic CRF")
                    }
                }
                Caption(model.settings.codec == .av1
                        ? "Lower is better (0-63). Auto picks \(CodecArgs.av1Crf(fromHevc: 16))-\(CodecArgs.av1Crf(fromHevc: 24)) from noise, motion and ISO."
                        : "Lower is better (0-51). Auto picks 16-24 from noise, motion and ISO.")
                FieldError(text: crfError)
            }
            VStack(alignment: .leading, spacing: 4) {
                LabeledContent("Grain retention") {
                    HStack(spacing: 12) {
                        Picker("Grain retention", selection: $model.settings.grainLevel) {
                            ForEach(Grain.allCases) { Text($0.name).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .disabled(model.settings.autoGrain)
                        Toggle("Auto", isOn: $model.settings.autoGrain)
                            .toggleStyle(.checkbox)
                            .accessibilityLabel("Automatic grain retention")
                    }
                }
                Caption("Keeps grain instead of smoothing it; costs bitrate. Auto raises it for F‑Log2 and noisy clips.")
            }
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Bitrate cap (constrained VBR)", isOn: $model.settings.vbrEnabled)
                    .accessibilityLabel("Bitrate cap")
                HStack {
                    TextField("Maximum bitrate, Mbps", text: $model.settings.maxRate)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 64)
                        .multilineTextAlignment(.center)
                        .labelsHidden()
                    Text("Mbps max").foregroundStyle(.secondary)
                }
                .disabled(!model.settings.vbrEnabled)
                Caption("CRF quality with VBV peaks capped; buffer is 2x the cap.")
                FieldError(text: rateError)
            }
        }
    }
}

// MARK: - Trim

struct TrimSection: View {
    @Environment(AppModel.self) private var model

    var error: String? {
        let a = Trim.parse(model.trimStart), b = Trim.parse(model.trimEnd)
        if a == .invalid || b == .invalid { return "Use seconds (90), mm:ss (1:30) or hh:mm:ss.ms." }
        if case .seconds(let x) = a, case .seconds(let y) = b, y <= x { return "The end must be after the start." }
        return nil
    }

    var body: some View {
        @Bindable var model = model
        Section("Trim") {
            HStack {
                TextField("Trim start", text: $model.trimStart, prompt: Text("Start (s or mm:ss)"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .onSubmit { model.preview.requestUpdate() }
                Text("–").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("Trim end", text: $model.trimEnd, prompt: Text("End (s or mm:ss)"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .onSubmit { model.preview.requestUpdate() }
            }
            .onChange(of: model.trimStart) { _, _ in model.preview.requestUpdate() }
            .onChange(of: model.trimEnd) { _, _ in model.preview.requestUpdate() }
            Caption("Leave empty for the whole clip. The preview loops this range.")
            FieldError(text: error)
        }
    }
}

// MARK: - Output

struct OutputSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Section("Output") {
            Picker("Save to", selection: $model.settings.outputMode) {
                Text("Next to each source clip").tag(OutputMode.source)
                Text("Custom folder").tag(OutputMode.custom)
            }
            .pickerStyle(.radioGroup)
            if model.settings.outputMode == .custom {
                HStack {
                    TextField("Output folder", text: $model.settings.outputFolder, prompt: Text("Choose a folder"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                    Button("Choose…") { model.chooseOutputFolder() }
                        .accessibilityLabel("Choose output folder")
                }
                FieldError(text: OutputPaths.validateCustomFolder(model.settings.outputFolder))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Subfolder")
                TextField("Subfolder", text: $model.settings.subfolder, prompt: Text("None (save directly in the folder)"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                FieldError(text: OutputPaths.validateSubfolder(model.settings.subfolder))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Saves to").font(.callout).foregroundStyle(.secondary)
                Text(model.savesTo)
                    .font(.callout)
                    .textSelection(.enabled)
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isStaticText)
            .accessibilityLabel("Saves to")
            .accessibilityValue(model.savesTo)
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Write CSV log", isOn: $model.settings.csvEnabled)
                    .accessibilityLabel("Write CSV log")
                HStack {
                    Text(model.settings.csvPath)
                        .font(.callout).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                        .opacity(model.settings.csvEnabled ? 1 : 0.5)
                        .help(model.settings.csvPath)
                        .accessibilityLabel("CSV log file")
                        .accessibilityValue(model.settings.csvPath)
                    Spacer()
                    Button("Change…") { model.chooseCsv() }
                        .accessibilityLabel("Change CSV log file")
                }
            }
        }
    }
}
