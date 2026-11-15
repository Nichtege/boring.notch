//
//  LockMusicWidget.swift
//  boringNotch
//
//  The song and its lyrics on the lock screen, fed by the notch's own now playing source.
//

import CoreImage
import CoreImage.CIFilterBuiltins
import Defaults
import SwiftUI

// MARK: - Music

struct LockMusicWidget: View {
    @ObservedObject private var music = MusicManager.shared
    @Environment(\.lockStyle) private var style
    @Environment(\.lockSize) private var size

    private var hasSong: Bool {
        (music.isPlaying || !music.isPlayerIdle) && !music.songTitle.isEmpty
    }

    var body: some View {
        ZStack {
            LockArtworkBackdrop(artwork: music.albumArt)
                .opacity(hasSong ? 0.92 * style.opacity : 0)
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .strokeBorder(.white.opacity(0.22), lineWidth: 1)
                }

            Group {
                if !hasSong {
                    LockWidgetHint(symbol: "music.note", text: Text("Nothing playing"))
                } else if size == .small {
                    small
                } else if size == .large {
                    large
                } else {
                    row
                }
            }
            .padding(16)
        }
        .animation(.smooth(duration: 0.5), value: hasSong)
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                cover.frame(width: 62, height: 62)
                Spacer()
                button(music.isPlaying ? "pause.fill" : "play.fill", size: 22, action: music.togglePlay)
            }
            Spacer(minLength: 0)
            titles(titleSize: 15, artistSize: 13)
        }
    }

    private var row: some View {
        HStack(spacing: 16) {
            cover
            VStack(alignment: .leading, spacing: 8) {
                titles(titleSize: 18, artistSize: 15)
                Spacer(minLength: 0)
                progress
                controls(size: 20)
            }
        }
    }

    private var large: some View {
        VStack(spacing: 12) {
            cover
            titles(titleSize: 19, artistSize: 15)
                .frame(maxWidth: .infinity, alignment: .leading)
            progress
            controls(size: 24)
        }
    }

    private var cover: some View {
        Image(nsImage: music.albumArt)
            .resizable()
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
            .scaleEffect(music.isPlaying ? 1 : 0.92)
            .animation(.spring(response: 0.4, dampingFraction: 0.7), value: music.isPlaying)
    }

    private func titles(titleSize: CGFloat, artistSize: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: music.songTitle)
                .font(style.font(titleSize, .semibold))
            Text(verbatim: music.artistName)
                .font(style.font(artistSize, .medium))
                .opacity(0.75)
        }
        .lineLimit(1)
    }

    private var progress: some View {
        LockTick(every: 1) { date in
            let position = music.estimatedPlaybackPosition(at: date)
            let fraction = music.songDuration > 0 ? position / music.songDuration : 0
            VStack(spacing: 3) {
                Capsule()
                    .fill(.white.opacity(0.22))
                    .frame(height: 5)
                    .overlay(alignment: .leading) {
                        GeometryReader { proxy in
                            Capsule()
                                .fill(style.accent.color)
                                .frame(width: proxy.size.width * min(max(fraction, 0), 1))
                        }
                    }
                HStack {
                    Text(verbatim: Self.clock(position))
                    Spacer()
                    Text(verbatim: Self.clock(music.songDuration))
                }
                .font(style.font(11, .medium))
                .monospacedDigit()
                .opacity(0.65)
            }
        }
    }

    private func controls(size: CGFloat) -> some View {
        HStack(spacing: 0) {
            Spacer()
            button("backward.fill", size: size, action: music.previousTrack)
            Spacer()
            button(music.isPlaying ? "pause.fill" : "play.fill", size: size * 1.25, action: music.togglePlay)
            Spacer()
            button("forward.fill", size: size, action: music.nextTrack)
            Spacer()
        }
    }

    private func button(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .frame(width: size * 1.8, height: size * 1.5)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// The cover's colours drifting slowly behind the widget, like the player on the iPhone's lock screen.
/// The cover is shrunk, saturated and blurred once per song. After that only cheap copies of it move.
struct LockArtworkBackdrop: View {
    let artwork: NSImage
    @State private var soft: NSImage?
    @Environment(\.lockWidgetsPaused) private var paused
    @Environment(\.lockMotion) private var motion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let side = max(proxy.size.width, proxy.size.height)
            TimelineView(.animation(minimumInterval: 1 / 24, paused: paused || reduceMotion || !motion || soft == nil)) { timeline in
                let time = timeline.date.timeIntervalSinceReferenceDate
                ZStack {
                    Color.black
                    if let soft {
                        layer(soft, side: side * 1.5, angle: time * 5, x: 0, y: 0)
                        layer(soft, side: side * 1.1, angle: -time * 8 + 90, x: cos(time / 7) * side * 0.28, y: sin(time / 9) * side * 0.22)
                            .opacity(0.7)
                        layer(soft, side: side * 0.9, angle: time * 11 + 200, x: sin(time / 6) * side * 0.3, y: cos(time / 8) * side * 0.25)
                            .opacity(0.55)
                        layer(soft, side: side * 0.7, angle: -time * 14 + 40, x: cos(time / 5 + 2) * side * 0.25, y: sin(time / 6 + 1) * side * 0.3)
                            .opacity(0.45)
                    }
                    // Keeps white text readable on a bright cover
                    Color.black.opacity(0.32)
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipped()
            }
        }
        .task(id: ObjectIdentifier(artwork)) {
            soft = await Self.soften(artwork)
        }
    }

    private func layer(_ image: NSImage, side: CGFloat, angle: Double, x: CGFloat, y: CGFloat) -> some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .frame(width: side, height: side)
            .rotationEffect(.degrees(angle))
            .offset(x: x, y: y)
    }

    private static func soften(_ artwork: NSImage) async -> NSImage? {
        guard let source = artwork.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let result = await Task.detached(priority: .utility) { () -> CGImage? in
            let side: CGFloat = 72
            let input = CIImage(cgImage: source)
            let scale = side / max(input.extent.width, input.extent.height, 1)
            let colors = CIFilter.colorControls()
            colors.inputImage = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            colors.saturation = 1.7
            guard let saturated = colors.outputImage else { return nil }
            let blur = CIFilter.gaussianBlur()
            blur.inputImage = saturated.clampedToExtent()
            blur.radius = 9
            guard let blurred = blur.outputImage else { return nil }
            return CIContext().createCGImage(blurred, from: saturated.extent)
        }.value
        return result.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
    }
}

private struct LockMotionKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// Off when the user doesn't want moving backgrounds and light.
    var lockMotion: Bool {
        get { self[LockMotionKey.self] }
        set { self[LockMotionKey.self] = newValue }
    }
}

// MARK: - Lyrics

struct LockLyricsWidget: View {
    @ObservedObject private var lyrics = LyricsManager.shared
    @ObservedObject private var music = MusicManager.shared
    @Environment(\.lockStyle) private var style
    @Environment(\.lockSize) private var size

    private var fontSize: CGFloat {
        switch size {
        case .small: 15
        case .medium, .wide: 20
        case .large: 24
        }
    }

    private var rowHeight: CGFloat {
        fontSize * 2.5
    }

    var body: some View {
        if lyrics.lines.isEmpty {
            LockWidgetHint(symbol: "quote.bubble", text: Text("Lyrics show here when the song has synced ones"))
        } else {
            LockTick(every: 0.25) { date in
                let current = lyrics.index(at: music.estimatedPlaybackPosition(at: date))
                GeometryReader { proxy in
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(lyrics.lines) { line in
                            Text(verbatim: line.text.isEmpty ? "♪" : line.text)
                                .font(style.font(fontSize, .bold))
                                .lineLimit(2)
                                .minimumScaleFactor(0.7)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, minHeight: rowHeight, maxHeight: rowHeight, alignment: .leading)
                                .foregroundStyle(line.id == current ? style.accent.color : .white)
                                .opacity(line.id == current ? 1 : 0.35)
                                .scaleEffect(line.id == current ? 1 : 0.94, anchor: .leading)
                        }
                    }
                    // The current line sits a little above the middle
                    .offset(y: proxy.size.height * 0.4 - rowHeight / 2 - CGFloat(current ?? 0) * rowHeight)
                    .animation(.smooth(duration: 0.55), value: current)
                }
                .mask {
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .black, location: 0.18),
                            .init(color: .black, location: 0.8),
                            .init(color: .clear, location: 1),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
            }
        }
    }
}

// MARK: - Cover over the whole screen

/// The cover and its colours over the whole lock screen while a song is on, as on the iPhone.
/// It hides the lock screen's own clock, so it brings one. Towards the bottom it thins out to nothing,
/// which leaves the login where macOS draws it.
struct LockFullCover: View {
    @ObservedObject private var music = MusicManager.shared
    @ObservedObject private var controller = LockScreenController.shared
    @Default(.lockScreenMotion) private var motion

    private var hasSong: Bool {
        (music.isPlaying || !music.isPlayerIdle) && !music.songTitle.isEmpty
    }

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.height * 0.4, proxy.size.width * 0.3)
            ZStack {
                LockArtworkBackdrop(artwork: music.albumArt)

                VStack(spacing: 0) {
                    LockTick(every: 60) { date in
                        VStack(spacing: -4) {
                            Text(date, format: .dateTime.weekday(.wide).day().month(.wide))
                                .font(.system(size: 22, weight: .semibold, design: .rounded))
                                .opacity(0.85)
                            Text(date, format: .dateTime.hour().minute())
                                .font(.system(size: 104, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                        }
                    }
                    .padding(.top, proxy.size.height * 0.05)

                    Spacer(minLength: 0)

                    Image(nsImage: music.albumArt)
                        .resizable()
                        .aspectRatio(1, contentMode: .fit)
                        .frame(width: side, height: side)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .shadow(color: .black.opacity(0.45), radius: 30, y: 16)
                        .scaleEffect(music.isPlaying ? 1 : 0.93)
                        .animation(.spring(response: 0.5, dampingFraction: 0.7), value: music.isPlaying)
                    VStack(spacing: 2) {
                        Text(verbatim: music.songTitle)
                            .font(.system(size: 20, weight: .semibold, design: .rounded))
                        Text(verbatim: music.artistName)
                            .font(.system(size: 16, weight: .medium, design: .rounded))
                            .opacity(0.75)
                    }
                    .lineLimit(1)
                    .padding(.top, 16)
                    .padding(.horizontal, 40)

                    Spacer(minLength: 0)
                        .frame(height: proxy.size.height * 0.3)
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.3), radius: 4, y: 1)
            }
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: 0.66),
                        .init(color: .clear, location: 0.82),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
        .opacity(hasSong ? 1 : 0)
        .animation(.smooth(duration: 0.8), value: hasSong)
        .environment(\.lockMotion, motion)
        .environment(\.lockWidgetsPaused, !controller.isScreenAwake)
    }
}
