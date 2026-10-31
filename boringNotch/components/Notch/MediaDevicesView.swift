//
//  MediaDevicesView.swift
//  boringNotch
//
//  All devices and what plays on them, like the media list in Control Center on an iPhone.
//

import SwiftUI

struct MediaDevicesView: View {
    @ObservedObject var musicManager = MusicManager.shared
    @ObservedObject var outputController = MusicOutputController.shared

    private let refreshInterval: Duration = .seconds(3)

    private struct Row: Identifiable {
        let name: String
        let icon: String
        let state: PlaybackState?
        let isShown: Bool
        /// nil for this Mac
        let remoteName: String?

        var id: String { name }
    }

    private var rows: [Row] {
        var rows = [Row(
            name: "Mac",
            icon: "laptopcomputer",
            state: musicManager.musicState,
            isShown: !musicManager.isRemoteSource,
            remoteName: nil
        )]
        rows += musicManager.remoteDevices.map { device in
            Row(
                name: device.deviceName,
                icon: RemoteNowPlaying.iconName(for: device.deviceName),
                state: device.state,
                isShown: musicManager.remoteName == device.deviceName,
                remoteName: device.deviceName
            )
        }
        // Speakers Music can reach, of which macOS hasn't told anything yet
        rows += outputController.devices
            .filter { device in device.kind != "computer" && !rows.contains { $0.name == device.name } }
            .map { Row(name: $0.name, icon: $0.iconName, state: nil, isShown: false, remoteName: $0.name) }
        return rows
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Media on your devices")
                    .font(.headline)
                    .foregroundColor(.white)
                Spacer()
                HoverButton(icon: "xmark", scale: .small) {
                    musicManager.isDeviceListShown = false
                }
            }
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(rows) { row in
                        rowView(row)
                    }
                }
            }
            .scrollIndicators(.never)
        }
        .padding(.horizontal, 5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task {
            // Asking Music for its speakers is also what makes macOS connect to them
            while !Task.isCancelled {
                await outputController.refresh()
                musicManager.refreshRemoteDevices()
                try? await Task.sleep(for: refreshInterval)
            }
        }
    }

    private func rowView(_ row: Row) -> some View {
        HStack(spacing: 4) {
            Button {
                musicManager.show(row.remoteName)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: row.icon)
                        .font(.system(size: 15))
                        .foregroundColor(row.state?.isPlaying == true ? .white : .gray)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(row.name)
                            .font(.subheadline.weight(.medium))
                            .foregroundColor(.white)
                            .lineLimit(1)
                        subtitle(of: row)
                            .font(.caption)
                            .foregroundColor(.gray)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .frame(height: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(row.state == nil)

            if let state = row.state {
                HoverButton(icon: state.isPlaying ? "pause.fill" : "play.fill", scale: .small) {
                    musicManager.togglePlay(on: row.remoteName)
                }
            }
        }
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(row.isShown ? 0.08 : 0))
        )
    }

    private func subtitle(of row: Row) -> Text {
        guard let state = row.state else { return Text("Nothing to show") }
        return Text(verbatim: state.artist.isEmpty ? state.title : "\(state.title) – \(state.artist)")
    }
}
