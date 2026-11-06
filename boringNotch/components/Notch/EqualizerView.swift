//
//  EqualizerView.swift
//  boringNotch
//
//  One app's equalizer, in the place of the Sound tab's lists.
//

import AppKit
import SwiftUI

struct EqualizerView: View {
    struct App: Equatable {
        let id: String
        let name: String
        let icon: NSImage?
    }

    let app: App
    let onBack: () -> Void

    @ObservedObject private var mixer = AppVolumeMixer.shared

    private var equalizer: AppEqualizer {
        mixer.equalizer(for: app.id)
    }

    private var isFailing: Bool {
        app.id == mixer.music?.bundleIdentifier ? mixer.musicIsFailing : mixer.rows.first { $0.id == app.id }?.isFailing == true
    }

    var body: some View {
        VStack(spacing: 6) {
            header
            EqualizerBands(
                bands: equalizer.bands,
                isOn: equalizer.isOn,
                onChange: { index, gain in
                    var changed = equalizer
                    changed.bands[index] = gain
                    mixer.setEqualizer(changed, for: app.id)
                },
                onRelease: mixer.saveEqualizers
            )
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Back")
            Image(nsImage: app.icon ?? NSImage())
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 16, height: 16)
            Text(app.name)
                .foregroundStyle(.white)
                .lineLimit(1)
            if isFailing {
                Text("Can't adjust right now")
                    .font(.caption2)
                    .foregroundStyle(.gray)
                    .lineLimit(1)
                    .fixedSize()
            }
            Spacer(minLength: 8)
            EqualizerPresetButton(preset: equalizer.preset) { preset in
                var changed = equalizer
                changed.bands = preset.bands
                changed.isOn = true
                mixer.setEqualizer(changed, for: app.id)
                mixer.saveEqualizers()
            }
            Button {
                var changed = equalizer
                changed.isOn.toggle()
                mixer.setEqualizer(changed, for: app.id)
                mixer.saveEqualizers()
            } label: {
                Text(equalizer.isOn ? "On" : "Off")
                    .foregroundStyle(equalizer.isOn ? .black : .gray)
                    .frame(width: 34, height: 18)
                    .background(equalizer.isOn ? Color.white : Color.gray.opacity(0.3), in: Capsule())
                    .contentShape(Capsule())
            }
        }
        .font(.caption)
        .foregroundStyle(.gray)
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - Bands

private enum EqualizerMetrics {
    static let labelHeight: CGFloat = 12
    static let labelSpacing: CGFloat = 5
    static let capHeight: CGFloat = 6

    /// Where a level sits, with room for the cap at both ends.
    static func y(for gain: Float, in height: CGFloat) -> CGFloat {
        let middle = height / 2
        return middle - CGFloat(gain / AppEqualizer.maxGain) * (middle - capHeight / 2)
    }

    static func gain(at y: CGFloat, in height: CGFloat) -> Float {
        let middle = height / 2
        let gain = Float((middle - y) / (middle - capHeight / 2)) * AppEqualizer.maxGain
        // Without this, back to exactly nothing would take a steady hand
        return gain.magnitude < 0.4 ? 0 : min(max(gain, -AppEqualizer.maxGain), AppEqualizer.maxGain)
    }
}

private struct EqualizerBands: View {
    let bands: [Float]
    let isOn: Bool
    let onChange: (Int, Float) -> Void
    let onRelease: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            scale
            ZStack {
                curve
                    .padding(.bottom, EqualizerMetrics.labelHeight + EqualizerMetrics.labelSpacing)
                HStack(spacing: 0) {
                    ForEach(Array(equalizerFrequencies.enumerated()), id: \.offset) { index, frequency in
                        EqualizerBandSlider(
                            frequency: frequency,
                            gain: bands[index],
                            onChange: { onChange(index, $0) },
                            onRelease: onRelease
                        )
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .opacity(isOn ? 1 : 0.35)
        .animation(.easeOut(duration: 0.15), value: isOn)
    }

    private var scale: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            ForEach([Float(12), 0, -12], id: \.self) { gain in
                Text(verbatim: gain > 0 ? "+12" : gain < 0 ? "\u{2212}12" : "0")
                    .font(.system(size: 8, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(width: geometry.size.width, alignment: .trailing)
                    .position(x: geometry.size.width / 2, y: EqualizerMetrics.y(for: gain, in: height))
            }
        }
        .frame(width: 18)
        .padding(.bottom, EqualizerMetrics.labelHeight + EqualizerMetrics.labelSpacing)
    }

    private var curve: some View {
        ZStack {
            Rectangle()
                .fill(.white.opacity(0.14))
                .frame(height: 1)
            EqualizerCurve(bands: bands, isClosed: true)
                .fill(.white.opacity(0.07))
            EqualizerCurve(bands: bands, isClosed: false)
                .stroke(.white.opacity(0.28), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
    }
}

/// The sound as a line through the caps, and the area between it and the middle.
private struct EqualizerCurve: Shape {
    let bands: [Float]
    let isClosed: Bool

    func path(in rect: CGRect) -> Path {
        let step = rect.width / CGFloat(bands.count)
        let points = bands.enumerated().map { index, gain in
            CGPoint(x: step * (CGFloat(index) + 0.5), y: EqualizerMetrics.y(for: gain, in: rect.height))
        }
        guard let first = points.first, let last = points.last else { return Path() }

        var path = Path()
        path.move(to: first)
        for index in 0..<(points.count - 1) {
            // Catmull-Rom, so the line stays round and still goes through every cap
            let before = points[max(index - 1, 0)]
            let start = points[index]
            let end = points[index + 1]
            let after = points[min(index + 2, points.count - 1)]
            path.addCurve(
                to: end,
                control1: CGPoint(x: start.x + (end.x - before.x) / 6, y: start.y + (end.y - before.y) / 6),
                control2: CGPoint(x: end.x - (after.x - start.x) / 6, y: end.y - (after.y - start.y) / 6)
            )
        }
        if isClosed {
            path.addLine(to: CGPoint(x: last.x, y: rect.midY))
            path.addLine(to: CGPoint(x: first.x, y: rect.midY))
            path.closeSubpath()
        }
        return path
    }
}

private struct EqualizerBandSlider: View {
    let frequency: Double
    let gain: Float
    let onChange: (Float) -> Void
    let onRelease: () -> Void

    @State private var dragging = false
    @State private var hovering = false
    @State private var detents = SliderDetents()

    private var label: String {
        frequency < 1_000 ? "\(Int(frequency))" : "\(Int(frequency / 1_000))k"
    }

    var body: some View {
        VStack(spacing: EqualizerMetrics.labelSpacing) {
            GeometryReader { geometry in
                let height = geometry.size.height
                let middle = height / 2
                let level = EqualizerMetrics.y(for: gain, in: height)
                let isActive = dragging || hovering

                ZStack(alignment: .top) {
                    Capsule()
                        .fill(.white.opacity(isActive ? 0.2 : 0.11))
                        .frame(width: 4, height: height)
                    Rectangle()
                        .fill(.white.opacity(0.7))
                        .frame(width: 4, height: abs(level - middle))
                        .offset(y: min(level, middle))
                    Capsule()
                        .fill(.white)
                        .frame(width: dragging ? 24 : isActive ? 20 : 16, height: EqualizerMetrics.capHeight)
                        .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
                        .offset(y: level - EqualizerMetrics.capHeight / 2)
                }
                .frame(width: geometry.size.width, height: height)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            dragging = true
                            let newGain = EqualizerMetrics.gain(at: drag.location.y, in: height)
                            // One click per dB, and the middle is what a hand wants to find without looking
                            detents.update(
                                progress: Double((newGain + AppEqualizer.maxGain) / (2 * AppEqualizer.maxGain)),
                                count: Int(2 * AppEqualizer.maxGain),
                                hasMiddle: true
                            )
                            onChange(newGain)
                        }
                        .onEnded { _ in
                            dragging = false
                            detents.end()
                            onRelease()
                        }
                )
                .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isActive)
                .animation(.spring(response: 0.3, dampingFraction: 0.75), value: dragging)
            }

            Group {
                if dragging {
                    Text(gain, format: .number.precision(.fractionLength(1)).sign(strategy: .always(includingZero: false)))
                        .foregroundStyle(.white)
                } else {
                    Text(verbatim: label)
                        .foregroundStyle(hovering ? .white : .gray)
                }
            }
            .font(.system(size: 9, weight: .medium))
            .monospacedDigit()
            .lineLimit(1)
            .frame(height: EqualizerMetrics.labelHeight)
        }
    }
}

// MARK: - Presets

private struct EqualizerPresetButton: View {
    let preset: AppEqualizer.Preset?
    let onSelect: (AppEqualizer.Preset) -> Void

    @EnvironmentObject private var vm: BoringViewModel
    @State private var showPopover = false
    @State private var isHoveringButton = false
    @State private var isHoveringPopover = false
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        Button {
            showPopover.toggle()
        } label: {
            HStack(spacing: 3) {
                Text(LocalizedStringKey(preset?.name ?? "Custom"))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .frame(height: 20)
            .contentShape(Rectangle())
        }
        .onHover { hovering in
            isHoveringButton = hovering
            updateHideTask()
        }
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            list
                .onHover { hovering in
                    isHoveringPopover = hovering
                    updateHideTask()
                }
                // What's really on screen, also if this view goes away first: the notch can't close before
                .onAppear { vm.isBatteryPopoverActive = true }
                .onDisappear {
                    vm.isBatteryPopoverActive = false
                    showPopover = false
                }
        }
        .onDisappear {
            hideTask?.cancel()
            hideTask = nil
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Headphones")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(AppEqualizer.headphonePresets) { row(for: $0) }
            }
            Divider()
            LazyVGrid(columns: [GridItem(.fixed(130), spacing: 2), GridItem(.fixed(130), spacing: 2)], alignment: .leading, spacing: 0) {
                ForEach(AppEqualizer.presets) { row(for: $0) }
            }
        }
        .padding(6)
    }

    private func row(for item: AppEqualizer.Preset) -> some View {
        Button {
            showPopover = false
            onSelect(item)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.caption2)
                    .opacity(item.id == preset?.id ? 1 : 0)
                Text(LocalizedStringKey(item.name))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .frame(height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
    }

    private func updateHideTask() {
        hideTask?.cancel()
        hideTask = nil
        guard showPopover, !isHoveringButton, !isHoveringPopover else { return }
        hideTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await MainActor.run { showPopover = false }
        }
    }
}
