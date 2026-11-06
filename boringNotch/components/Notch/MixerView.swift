//
//  MixerView.swift
//  boringNotch
//
//  The right half of the Sound tab: the Mac, Music, and every other app making sound.
//

import AppKit
import SwiftUI

struct MixerView: View {
    @ObservedObject var mixer = AppVolumeMixer.shared
    @ObservedObject var musicManager = MusicManager.shared
    /// Open, it takes the whole tab, as its bands need the width
    @Binding var equalizedApp: EqualizerView.App?

    var body: some View {
        Group {
            if let equalizedApp {
                EqualizerView(app: equalizedApp) {
                    self.equalizedApp = nil
                }
            } else {
                list
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 2)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            mixer.tabAppeared()
            Task { await musicManager.syncVolumeFromActiveApp() }
        }
        .onDisappear(perform: mixer.tabDisappeared)
    }

    private var list: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 2) {
                if mixer.macHasVolume {
                    MixerRow(name: Text("Mac"), volume: mixer.macVolume, onChange: mixer.setMacVolume) {
                        Image(systemName: mixer.macIcon)
                            .foregroundStyle(.gray)
                    }
                }

                if let music = mixer.music {
                    let app = EqualizerView.App(id: music.bundleIdentifier ?? "", name: music.localizedName ?? "", icon: music.icon)
                    MixerRow(
                        name: Text(app.name),
                        isFailing: mixer.musicIsFailing,
                        volume: musicManager.volume,
                        onChange: musicManager.setVolume(to:),
                        equalizerIsActive: mixer.equalizer(for: app.id).isActive,
                        onEqualizer: { equalizedApp = app }
                    ) {
                        appIcon(music.icon)
                    }
                }

                ForEach(mixer.rows) { row in
                    MixerRow(
                        name: Text(row.name),
                        isFailing: row.isFailing,
                        volume: row.volume,
                        onChange: { mixer.setVolume($0, for: row.id) },
                        onRelease: mixer.saveVolumes,
                        equalizerIsActive: mixer.equalizer(for: row.id).isActive,
                        onEqualizer: { equalizedApp = EqualizerView.App(id: row.id, name: row.name, icon: row.icon) }
                    ) {
                        appIcon(row.icon)
                    }
                }

                if mixer.rows.isEmpty {
                    Text("Nothing else is playing")
                        .font(.caption)
                        .foregroundStyle(.gray.opacity(0.7))
                        .padding(.horizontal, 6)
                        .padding(.top, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private func appIcon(_ icon: NSImage?) -> some View {
        Image(nsImage: icon ?? NSImage())
            .resizable()
            .aspectRatio(contentMode: .fit)
    }
}

private struct MixerRow<Icon: View>: View {
    let name: Text
    var isFailing = false
    let volume: Double
    let onChange: (Double) -> Void
    var onRelease: () -> Void = {}
    var equalizerIsActive = false
    var onEqualizer: (() -> Void)?
    @ViewBuilder let icon: () -> Icon

    @State private var value: Double = 0
    @State private var dragging = false

    var body: some View {
        HStack(spacing: 8) {
            icon()
                .frame(width: 16, height: 16)
            name
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 84, alignment: .leading)
            if isFailing {
                // Half the tab has no room for the sentence, so it's what the sign says on hover
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.gray)
                    .help(Text("Can't adjust right now"))
                    .accessibilityLabel(Text("Can't adjust right now"))
            }
            CustomSlider(
                value: $value,
                range: 0...1,
                dragging: $dragging,
                lastDragged: .constant(.distantPast),
                onValueChange: { newValue in
                    onChange(newValue)
                    onRelease()
                },
                onDragChange: onChange,
                detentCount: SliderDetents.volumeCount
            )
            .frame(height: 10)
            Text(verbatim: "\(Int((value * 100).rounded())) %")
                .font(.caption2)
                .notchNumber()
                .foregroundStyle(.gray)
                .frame(width: 38, alignment: .trailing)
            Group {
                if let onEqualizer {
                    Button(action: onEqualizer) {
                        Image(systemName: "slider.vertical.3")
                            .foregroundStyle(equalizerIsActive ? .white : .gray)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PlainButtonStyle())
                    .accessibilityLabel("Equalizer")
                } else {
                    Color.clear
                }
            }
            .frame(width: 20)
        }
        .font(.caption)
        .padding(.horizontal, 6)
        .frame(height: 20)
        .onAppear { value = volume }
        .onChange(of: volume) { _, newVolume in
            if !dragging {
                value = newVolume
            }
        }
    }
}
