import StreameroCore
import SwiftUI

/// 10-band equaliser: on/off, presets, preamp and vertical band sliders, with a live response curve.
/// Reachable from Now Playing (sheet) and Settings (pushed). Changes apply to the audio while dragging;
/// they are saved (and synced with the account preferences) when a gesture ends.
struct EqualizerView: View {
    var showsDone = false
    @Environment(SettingsStore.self) private var settings
    @Environment(AudioPlayer.self) private var player
    @Environment(AppearanceStore.self) private var appearance
    @Environment(\.dismiss) private var dismiss
    @State private var draft = EqualizerSettings()
    @State private var editing = false
    @State private var loaded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                if !appearance.features.equalizer {
                    EmptyStateView(symbol: "slider.vertical.3", title: "Equalizer unavailable", message: "The equalizer is switched off for this service.")
                } else {
                    header
                    ResponseCurve(settings: draft)
                        .frame(height: 96)
                        .padding(.horizontal, Theme.Spacing.screen)
                        .opacity(draft.enabled ? 1 : 0.35)
                    presets
                    bands
                    preamp
                    Text("Applies to music, including downloads. The audio of music videos and AirPlay playback are not equalised.")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .padding(.horizontal, Theme.Spacing.screen)
                }
            }
            .padding(.vertical, Theme.Spacing.l)
        }
        .streameroScreen()
        .navigationTitle("Equalizer")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsDone {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Reset") { change { $0.apply(.flat) } }
                    .disabled(draft.preset == .flat && draft.preamp == 0)
            }
        }
        .onAppear {
            if !loaded { draft = settings.values.equalizer; loaded = true }
        }
        .onChange(of: settings.values.equalizer) { _, new in
            if !editing && new != draft { draft = new } // e.g. adopted from another device
        }
    }

    private var header: some View {
        Toggle(isOn: Binding(get: { draft.enabled }, set: { on in change { $0.enabled = on } })) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Equalizer").font(Theme.Typography.media(20)).foregroundStyle(Theme.Palette.textPrimary)
                Text(draft.enabled ? draft.preset.title : "Off").font(.system(size: 14)).foregroundStyle(Theme.Palette.textSecondary)
            }
        }
        .tint(Theme.Palette.accent)
        .padding(.horizontal, Theme.Spacing.screen)
        .accessibilityIdentifier("equalizerToggle")
    }

    private var presets: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.s) {
                ForEach(EqualizerPreset.allCases.filter { $0 != .custom || draft.preset == .custom }) { p in
                    Chip(title: p.title, selected: draft.preset == p) {
                        change { s in
                            s.enabled = true
                            s.apply(p)
                        }
                    }
                    .overlay(Capsule().strokeBorder(draft.preset == p ? Color.clear : Theme.Palette.border, lineWidth: 1))
                }
            }
            .padding(.horizontal, Theme.Spacing.screen)
        }
    }

    private var bands: some View {
        HStack(alignment: .bottom, spacing: 0) {
            ForEach(0..<EqualizerDesign.bandCount, id: \.self) { i in
                VStack(spacing: Theme.Spacing.s) {
                    Text(gainText(draft.gains[i]))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .lineLimit(1)
                        .fixedSize()
                    VerticalGainSlider(value: draft.gains[i], range: EqualizerDesign.gainRange, enabled: draft.enabled,
                                       label: "\(EqualizerDesign.label(i)) hertz") { v, ended in
                        editing = !ended
                        live { $0.setGain(v, forBand: i) }
                        if ended { commit() }
                    }
                    .frame(height: 200)
                    Text(EqualizerDesign.label(i))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.Palette.textPrimary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, Theme.Spacing.s)
    }

    private var preamp: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            HStack {
                Text("Preamp").font(Theme.Typography.media(16)).foregroundStyle(Theme.Palette.textPrimary)
                Spacer()
                Text(gainText(draft.preamp)).font(.system(size: 14, design: .monospaced)).foregroundStyle(Theme.Palette.textSecondary)
            }
            Slider(value: Binding(get: { draft.preamp }, set: { v in live { $0.preamp = v } }), in: EqualizerDesign.preampRange, step: 0.5) { isEditing in
                editing = isEditing
                if !isEditing { commit() }
            }
            .tint(Theme.Palette.accent)
            .disabled(!draft.enabled)
            Text("Lower the preamp when boosting bands to avoid distortion.")
                .font(Theme.Typography.caption).foregroundStyle(Theme.Palette.textTertiary)
        }
        .padding(.horizontal, Theme.Spacing.screen)
    }

    private func gainText(_ db: Double) -> String {
        let rounded = (db * 2).rounded() / 2
        if rounded == 0 { return "0 dB" }
        return String(format: rounded == rounded.rounded() ? "%+.0f dB" : "%+.1f dB", rounded)
    }

    /// Applies a change to the audio immediately without saving (while dragging).
    private func live(_ edit: (inout EqualizerSettings) -> Void) {
        edit(&draft)
        player.equalizer.update(draft)
    }

    /// Discrete change: apply and save.
    private func change(_ edit: (inout EqualizerSettings) -> Void) {
        live(edit)
        commit()
        Haptics.selection()
    }

    private func commit() {
        if settings.values.equalizer != draft { settings.values.equalizer = draft }
    }
}

/// Custom vertical slider: capsule track, fill from 0 dB to the value, round thumb. VoiceOver adjustable.
struct VerticalGainSlider: View {
    let value: Double
    let range: ClosedRange<Double>
    var enabled = true
    var label: String
    /// (new value, gesture ended)
    let onChange: (Double, Bool) -> Void

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let thumb: CGFloat = 22
            let usable = max(1, h - thumb)
            let span = range.upperBound - range.lowerBound
            let fraction = CGFloat((value - range.lowerBound) / span)
            let zeroFraction = CGFloat((0 - range.lowerBound) / span)
            let y = thumb / 2 + usable * (1 - fraction)
            let zeroY = thumb / 2 + usable * (1 - zeroFraction)
            ZStack(alignment: .top) {
                Capsule().fill(Theme.Palette.surfaceHighlight).frame(width: 4)
                Rectangle().fill(Theme.Palette.border).frame(width: 14, height: 1).offset(y: zeroY)
                Capsule()
                    .fill(enabled ? Theme.Palette.accent : Theme.Palette.textTertiary)
                    .frame(width: 4, height: abs(zeroY - y))
                    .offset(y: min(y, zeroY))
                Circle()
                    .fill(Color.white)
                    .frame(width: thumb, height: thumb)
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                    .offset(y: y - thumb / 2)
            }
            .frame(width: geo.size.width, height: h, alignment: .top)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                guard enabled else { return }
                onChange(valueAt(g.location.y, thumb: thumb, usable: usable), false)
            }.onEnded { g in
                guard enabled else { return }
                onChange(valueAt(g.location.y, thumb: thumb, usable: usable), true)
            })
        }
        .opacity(enabled ? 1 : 0.5)
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(String(format: "%+.1f decibels", value))
        .accessibilityAdjustableAction { direction in
            guard enabled else { return }
            switch direction {
            case .increment: onChange(min(range.upperBound, value + 1), true)
            case .decrement: onChange(max(range.lowerBound, value - 1), true)
            @unknown default: break
            }
        }
    }

    private func valueAt(_ y: CGFloat, thumb: CGFloat, usable: CGFloat) -> Double {
        let f = 1 - Double(min(max(0, (y - thumb / 2) / usable), 1))
        let raw = range.lowerBound + f * (range.upperBound - range.lowerBound)
        return (raw * 2).rounded() / 2 // 0.5 dB steps
    }
}

/// The combined EQ response from 20 Hz to 20 kHz on a log axis.
struct ResponseCurve: View {
    let settings: EqualizerSettings

    var body: some View {
        Canvas { context, size in
            let maxDB = 15.0
            let points: [CGPoint] = (0...96).map { i in
                let t = Double(i) / 96
                let f = 20 * pow(1000, t) // 20 Hz … 20 kHz
                let db = max(-maxDB, min(maxDB, EqualizerDesign.responseDB(for: settings, at: f)))
                return CGPoint(x: CGFloat(t) * size.width, y: size.height / 2 - CGFloat(db / maxDB) * size.height / 2)
            }
            var mid = Path()
            mid.move(to: CGPoint(x: 0, y: size.height / 2))
            mid.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            context.stroke(mid, with: .color(Theme.Palette.border), lineWidth: 1)
            var curve = Path()
            curve.addLines(points)
            var fill = curve
            fill.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            fill.addLine(to: CGPoint(x: 0, y: size.height / 2))
            fill.closeSubpath()
            context.fill(fill, with: .color(Theme.Palette.accent.opacity(0.18)))
            context.stroke(curve, with: .color(Theme.Palette.accent), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}
