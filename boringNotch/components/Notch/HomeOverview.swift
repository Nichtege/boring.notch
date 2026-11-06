//
//  HomeOverview.swift
//  boringNotch
//
//  Home while nothing plays: the last song to start again, a focus session, and who's waiting in Starlane.
//

import Defaults
import SwiftUI

struct HomeOverview: View {
    @ObservedObject var musicManager = MusicManager.shared
    @ObservedObject var timer = FocusTimer.shared
    @ObservedObject var starlane = StarlaneManager.shared
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @Default(.starlaneShowDeadline) private var showDeadline
    @State private var isHoveringStarlane = false

    var body: some View {
        HStack(spacing: 10) {
            musicTile
            focusTile
            if let summary = starlane.summary {
                starlaneTile(summary)
            }
        }
        .padding(.top, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Music

    /// Before anything has played, the player only knows a made-up song.
    private var hasSong: Bool {
        musicManager.songDuration > 0 || musicManager.isRemoteSource
    }

    private var musicTile: some View {
        HomeTile(title: hasSong ? "Last played" : "Music", systemImage: "music.note") {
            HStack(spacing: 8) {
                Button {
                    musicManager.openMusicApp()
                } label: {
                    Image(nsImage: musicManager.albumArt)
                        .resizable()
                        .aspectRatio(1, contentMode: .fill)
                        .frame(width: 40, height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: NotchStyle.coverRadius, style: .continuous))
                        .opacity(hasSong ? 1 : 0.4)
                }
                .buttonStyle(PlainButtonStyle())

                VStack(alignment: .leading, spacing: 1) {
                    if hasSong {
                        Text(verbatim: musicManager.songTitle)
                            .foregroundStyle(.white)
                        Text(verbatim: musicManager.artistName)
                            .foregroundStyle(.gray)
                    } else {
                        Text("Nothing played yet")
                            .foregroundStyle(.gray)
                    }
                }
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            // Once it plays, Home turns into the player
            HomeTileButton(label: Text("Play"), systemImage: "play.fill") {
                musicManager.togglePlay()
            }
        }
    }

    // MARK: - Focus

    private var focusTile: some View {
        HomeTile(title: "Focus", systemImage: "timer", tint: NotchStyle.focus) {
            if timer.isRunning {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(timer.clockText(at: context.date))
                        .font(.system(size: 26, weight: .semibold))
                        .notchNumber()
                        .foregroundStyle(.white)
                }
                Spacer(minLength: 0)
                HomeTileButton(label: Text("Stop"), systemImage: "stop.fill") {
                    timer.stop()
                }
            } else {
                Text("Start a session")
                    .font(.caption)
                    .foregroundStyle(.gray)
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    ForEach(FocusView.sessionLengths, id: \.self) { minutes in
                        HomeTileButton(label: Text(verbatim: "\(minutes)")) {
                            timer.start(seconds: TimeInterval(minutes) * 60)
                        }
                    }
                    Text("min")
                        .font(.caption)
                        .foregroundStyle(.gray)
                }
            }
        }
    }

    // MARK: - Starlane

    /// All of it leads to the Starlane tab, which has the rows to click.
    private func starlaneTile(_ summary: StarlaneSummary) -> some View {
        let waiting = summary.terminals.filter { ["needs", "failed", "limited"].contains($0.state) }
        let deadline = showDeadline ? summary.nextDeadline : nil

        return Button {
            withAnimation(.smooth) {
                coordinator.currentView = .starlane
            }
        } label: {
            HomeTile(title: "Needs you", systemImage: "sparkles", count: waiting.count, isHighlighted: isHoveringStarlane) {
                if waiting.isEmpty {
                    Text("Nothing is waiting")
                        .font(.caption)
                        .foregroundStyle(.gray)
                } else {
                    ForEach(Array(waiting.prefix(2).enumerated()), id: \.offset) { _, terminal in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(terminal.state == "failed" ? .red : terminal.state == "limited" ? .yellow : NotchStyle.attention)
                                .frame(width: 6, height: 6)
                            Text(terminal.name)
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .font(.caption)
                    }
                }
                Spacer(minLength: 0)
                if let deadline {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Text("Next deadline")
                                .foregroundStyle(.gray)
                            Spacer(minLength: 0)
                            if let relative = StarlaneView.relativeDay(deadline.date) {
                                Text(relative)
                                    .foregroundStyle(StarlaneView.deadlineColor(deadline.date))
                            }
                        }
                        .font(.caption2)
                        .lineLimit(1)
                        Text(deadline.title)
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(.white)
                            .lineLimit(1)
                    }
                }
            }
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { isHoveringStarlane = $0 }
    }
}

/// One of Home's boxes: a small heading, then what's in it.
private struct HomeTile<Content: View>: View {
    let title: LocalizedStringKey
    let systemImage: String
    var tint: Color = .gray
    var count = 0
    var isHighlighted = false
    @ViewBuilder let content: () -> Content

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: NotchStyle.boxRadius, style: .continuous)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
                Text(title)
                    .foregroundStyle(.gray)
                    .lineLimit(1)
                if count > 0 {
                    Text(verbatim: "\(count)")
                        .font(.caption2)
                        .fontWeight(.bold)
                        .notchNumber()
                        .foregroundStyle(.black)
                        .padding(.horizontal, 5)
                        .background(Capsule().fill(NotchStyle.attention))
                }
            }
            .font(.caption)
            .fontWeight(.semibold)

            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(shape.fill(isHighlighted ? NotchStyle.control : NotchStyle.surface))
        .contentShape(shape)
    }
}

/// A small capsule button, as in the Focus view.
private struct HomeTileButton: View {
    let label: Text
    var systemImage: String?
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let systemImage {
                    Image(systemName: systemImage)
                }
                label
            }
            .font(.caption)
            .fontWeight(.semibold)
            .notchNumber()
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Capsule().fill(isHovering ? NotchStyle.controlHovered : NotchStyle.control))
            .contentShape(Capsule())
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { isHovering = $0 }
    }
}
