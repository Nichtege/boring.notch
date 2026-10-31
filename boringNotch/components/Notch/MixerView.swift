//
//  MixerView.swift
//  boringNotch
//
//  The Mixer tab: the Mac, Music, and every other app making sound.
//

import AppKit
import SwiftUI

struct MixerView: View {
    @ObservedObject var mixer = AppVolumeMixer.shared
    @ObservedObject var musicManager = MusicManager.shared

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 2) {
                MixerRow(name: Text("Mac"), volume: mixer.macVolume, onChange: mixer.setMacVolume) {
                    Image(systemName: mixer.macIcon)
                        .foregroundStyle(.gray)
                }

                if let music = mixer.music {
                    MixerRow(name: Text(music.localizedName ?? ""), volume: musicManager.volume, onChange: musicManager.setVolume(to:)) {
                        appIcon(music.icon)
                    }
                }

                ForEach(mixer.rows) { row in
                    MixerRow(
                        name: Text(row.name),
                        isFailing: row.isFailing,
                        volume: row.volume,
                        onChange: { mixer.setVolume($0, for: row.id) },
                        onRelease: mixer.saveVolumes
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
                .frame(width: 120, alignment: .leading)
            if isFailing {
                Text("Can't adjust right now")
                    .font(.caption2)
                    .foregroundStyle(.gray)
                    .lineLimit(1)
                    .fixedSize()
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
                onDragChange: onChange
            )
            .frame(height: 10)
            Text(verbatim: "\(Int((value * 100).rounded())) %")
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.gray)
                .frame(width: 38, alignment: .trailing)
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
