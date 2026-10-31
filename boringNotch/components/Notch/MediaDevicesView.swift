//
//  MediaDevicesView.swift
//  boringNotch
//
//  The Devices tab: everything in reach and what plays on it, like the media list in Control Center on an iPhone.
//  What's picked here is what the notch shows, in the player and while closed.
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
        var isSelected = false
        var select: (() -> Void)?
        var toggle: (() -> Void)?
        var next: (() -> Void)?
        var previous: (() -> Void)?

        var id: String { name }
    }

    private var isMusicRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").isEmpty
    }

    private var macRow: Row {
        guard isMusicRunning, music.musicHasContent else { return Row(name: "Mac", icon: "laptopcomputer") }
        let speaker = music.musicIsPlaying ? media.musicSpeaker : nil
        return Row(
            name: speaker.map { "Mac → \($0)" } ?? "Mac",
            icon: "laptopcomputer",
            title: music.musicTitle,
            artist: music.musicArtist,
            cover: music.musicCover,
            isPlaying: music.musicIsPlaying,
            isSelected: media.selected == nil,
            select: { pick(nil) },
            toggle: { music.toggleMusicPlay() },
            next: { music.nextMusicTrack() },
            previous: { music.previousMusicTrack() }
        )
    }

    private var rows: [Row] {
        var rows = [macRow]
        let listed = media.listedDevices.filter { $0.deviceName != media.musicSpeaker }
        rows += listed.map { device in
            let speaker = media.speaker(of: device)
            return Row(
                name: speaker.map { "\(device.deviceName) → \($0.name)" } ?? device.deviceName,
                icon: speaker?.iconName ?? RemoteNowPlaying.iconName(for: device.deviceName),
                title: device.state.title,
                artist: device.state.artist,
                cover: device.cover,
                isPlaying: device.state.isPlaying,
                isSelected: media.selected == device.deviceName,
                select: { pick(device.deviceName) },
                toggle: { media.send(.toggle, to: device.deviceName) },
                next: { media.send(.next, to: device.deviceName) },
                previous: { media.send(.previous, to: device.deviceName) }
            )
        }
        // Speakers Music can reach, of which macOS hasn't told anything. Headphones play only what this Mac sends them
        let usedSpeakers = listed.compactMap { media.speaker(of: $0)?.name } + [music.musicIsPlaying ? media.musicSpeaker : nil].compactMap { $0 }
        rows += outputs.devices
            .filter { device in
                device.kind != "computer" && device.kind != "Bluetooth device"
                    && !usedSpeakers.contains(device.name) && !rows.contains { $0.name == device.name }
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

    /// The player is what it's picked for, so that comes up right away.
    private func pick(_ deviceName: String?) {
        media.select(deviceName)
        withAnimation(.smooth) {
            BoringViewCoordinator.shared.currentView = .home
        }
    }

    private func rowView(_ row: Row) -> some View {
        HStack(spacing: 4) {
            Button {
                row.select?()
            } label: {
                rowLabel(row)
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(row.select == nil)

            if let toggle = row.toggle, let next = row.next, let previous = row.previous {
                HStack(spacing: 2) {
                    HoverButton(icon: "backward.fill", scale: .small, action: previous)
                    HoverButton(icon: row.isPlaying ? "pause.fill" : "play.fill", scale: .small, action: toggle)
                    HoverButton(icon: "forward.fill", scale: .small, action: next)
                }
            }
        }
        .padding(.horizontal, 4)
        .frame(height: 40)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(row.isSelected ? 0.08 : 0))
        )
    }

    private func rowLabel(_ row: Row) -> some View {
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
        }
        .contentShape(Rectangle())
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
