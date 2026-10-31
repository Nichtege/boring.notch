//
//  MediaDevicesView.swift
//  boringNotch
//
//  The Devices tab: everything in reach and what plays on it, like the media list in Control Center on an iPhone.
//

import SwiftUI

struct MediaDevicesView: View {
    @ObservedObject var media = RemoteMediaManager.shared
    @ObservedObject var music = MusicManager.shared
    @ObservedObject var outputs = MusicOutputController.shared

    private let refreshInterval: Duration = .seconds(3)
    private let rowsThatFit = 3

    private struct Row: Identifiable {
        let name: String
        let icon: String
        var title: String?
        var artist = ""
        var cover: NSImage?
        var isPlaying = false
        var toggle: (() -> Void)?
        var next: (() -> Void)?
        var previous: (() -> Void)?

        var id: String { name }
    }

    private var isMusicRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").isEmpty
    }

    private var macRow: Row {
        guard isMusicRunning, music.songDuration > 0 else { return Row(name: "Mac", icon: "laptopcomputer") }
        return Row(
            name: "Mac",
            icon: "laptopcomputer",
            title: music.songTitle,
            artist: music.artistName,
            cover: music.albumArt,
            isPlaying: music.isPlaying,
            toggle: { music.togglePlay() },
            next: { music.nextTrack() },
            previous: { music.previousTrack() }
        )
    }

    private var rows: [Row] {
        var rows = [macRow]
        rows += media.devices.map { device in
            Row(
                name: device.deviceName,
                icon: RemoteNowPlaying.iconName(for: device.deviceName),
                title: device.state.title,
                artist: device.state.artist,
                cover: device.cover,
                isPlaying: device.state.isPlaying,
                toggle: { media.send(.toggle, to: device.deviceName) },
                next: { media.send(.next, to: device.deviceName) },
                previous: { media.send(.previous, to: device.deviceName) }
            )
        }
        // Speakers Music can reach, of which macOS hasn't told anything. Headphones play only what this Mac sends them
        rows += outputs.devices
            .filter { device in
                device.kind != "computer" && device.kind != "Bluetooth device" && !rows.contains { $0.name == device.name }
            }
            .map { Row(name: $0.name, icon: $0.iconName) }
        return rows
    }

    var body: some View {
        let rows = rows
        ScrollView {
            VStack(spacing: 4) {
                ForEach(rows) { row in
                    rowView(row)
                }
            }
        }
        .scrollDisabled(rows.count <= rowsThatFit)
        .scrollIndicators(.never)
        .padding(.horizontal, 8)
        .padding(.top, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: rows.count, initial: true) {
            media.scrolls = rows.count > rowsThatFit
        }
        .task {
            // Asking Music for its speakers is also what makes macOS connect to them
            while !Task.isCancelled {
                await outputs.refresh()
                media.refresh()
                try? await Task.sleep(for: refreshInterval)
            }
        }
    }

    private func rowView(_ row: Row) -> some View {
        HStack(spacing: 10) {
            coverView(row)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: row.name)
                    .font(.caption)
                    .foregroundColor(.gray)
                    .lineLimit(1)
                Group {
                    if let title = row.title {
                        Text(verbatim: row.artist.isEmpty ? title : "\(title) – \(row.artist)")
                            .foregroundColor(.white)
                    } else {
                        Text("Nothing to show")
                            .foregroundColor(.gray)
                    }
                }
                .font(.subheadline)
                .lineLimit(1)
                .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            if let toggle = row.toggle, let next = row.next, let previous = row.previous {
                HStack(spacing: 2) {
                    HoverButton(icon: "backward.fill", scale: .small, action: previous)
                    HoverButton(icon: row.isPlaying ? "pause.fill" : "play.fill", scale: .small, action: toggle)
                    HoverButton(icon: "forward.fill", scale: .small, action: next)
                }
            }
        }
        .frame(height: 40)
    }

    private func coverView(_ row: Row) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(0.08))
            if let cover = row.cover {
                Image(nsImage: cover)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                Image(systemName: row.icon)
                    .font(.system(size: 15))
                    .foregroundColor(.gray)
            }
        }
        .frame(width: 36, height: 36)
    }
}
