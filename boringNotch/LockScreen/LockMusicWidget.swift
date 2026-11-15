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
        LockMusicProgress()
    }

    private func controls(size: CGFloat) -> some View {
        LockMusicButtons(size: size)
    }

    private func button(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        LockMusicButton(symbol: symbol, size: size, action: action)
    }
}

/// How far the song is, as a bar with both times.
struct LockMusicProgress: View {
    @ObservedObject private var music = MusicManager.shared
    @Environment(\.lockStyle) private var style

    var body: some View {
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

    private static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Back, play or pause, and forward.
struct LockMusicButtons: View {
    let size: CGFloat
    @ObservedObject private var music = MusicManager.shared

    var body: some View {
        HStack(spacing: 0) {
            Spacer()
            LockMusicButton(symbol: "backward.fill", size: size, action: music.previousTrack)
            Spacer()
            LockMusicButton(symbol: music.isPlaying ? "pause.fill" : "play.fill", size: size * 1.25, action: music.togglePlay)
            Spacer()
            LockMusicButton(symbol: "forward.fill", size: size, action: music.nextTrack)
            Spacer()
        }
    }
}

struct LockMusicButton: View {
    let symbol: String
    let size: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .frame(width: size * 1.8, height: size * 1.5)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
            soft = await Self.soften(artwork, side: 72, blur: 9, saturation: 1.7)
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

    /// The cover shrunk to that size, with its colours lifted and its detail blurred away.
    static func soften(_ artwork: NSImage, side: CGFloat, blur radius: Double, saturation: Float) async -> NSImage? {
        guard let source = artwork.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let result = await Task.detached(priority: .utility) { () -> CGImage? in
            let input = CIImage(cgImage: source)
            let scale = side / max(input.extent.width, input.extent.height, 1)
            let colors = CIFilter.colorControls()
            colors.inputImage = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            colors.saturation = saturation
            guard let saturated = colors.outputImage else { return nil }
            let blur = CIFilter.gaussianBlur()
            blur.inputImage = saturated.clampedToExtent()
            blur.radius = Float(radius)
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
    @Environment(\.lockSize) private var size

    var body: some View {
        if lyrics.lines.isEmpty {
            LockWidgetHint(symbol: "quote.bubble", text: Text("Lyrics show here when the song has synced ones"))
        } else {
            LockLyricsList(fontSize: size == .small ? 15 : size == .large ? 24 : 20)
        }
    }
}

/// All lines in one column that slides, so the one being sung stays a little above the middle.
struct LockLyricsList: View {
    let fontSize: CGFloat
    @ObservedObject private var lyrics = LyricsManager.shared
    @ObservedObject private var music = MusicManager.shared
    @Environment(\.lockStyle) private var style

    private var rowHeight: CGFloat {
        fontSize * 2.5
    }

    var body: some View {
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

// MARK: - The cover takes over the screen

/// What decides whether and how the cover takes over the lock screen.
enum LockStage {
    @MainActor
    static var hasSong: Bool {
        let music = MusicManager.shared
        return (music.isPlaying || !music.isPlayerIdle) && !music.songTitle.isEmpty
    }

    /// The lyrics only get their side of the screen for a song that has synced ones.
    @MainActor
    static var showsLyrics: Bool {
        Defaults[.lockScreenCoverLayout] == .side && !LyricsManager.shared.lines.isEmpty
    }

    static func coverSide(on screen: CGSize) -> CGFloat {
        min(screen.height * 0.34, screen.width * 0.26)
    }

    /// Room around the cover in its panel: for its shadow at the sides, for the song and the buttons below.
    /// The same room is left above, which keeps the cover in the panel's exact middle.
    static let coverMargin = CGSize(width: 70, height: 150)

    /// Where the cover's middle is, as a share of the screen's width
    static func coverCenterX(showsLyrics: Bool) -> CGFloat {
        showsLyrics ? 0.27 : 0.5
    }
}

/// The cover, large and soft, over the whole lock screen, and the lyrics when they have their side of it.
struct LockStageBackground: View {
    @ObservedObject private var music = MusicManager.shared
    @ObservedObject private var lyrics = LyricsManager.shared
    @ObservedObject private var controller = LockScreenController.shared
    @Default(.lockScreenMotion) private var motion
    @Default(.lockScreenCoverLayout) private var layout

    var body: some View {
        GeometryReader { proxy in
            let showsLyrics = layout == .side && !lyrics.lines.isEmpty
            ZStack {
                LockBigCover(artwork: music.albumArt)

                if showsLyrics {
                    LockLyricsList(fontSize: 34)
                        .frame(width: proxy.size.width * 0.4, height: proxy.size.height * 0.5)
                        .position(x: proxy.size.width * 0.72, y: proxy.size.height * 0.5)
                        .transition(.opacity)
                }
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.3), radius: 4, y: 1)
            .animation(.smooth(duration: 0.6), value: showsLyrics)
        }
        .opacity(LockStage.hasSong ? 1 : 0)
        .animation(.smooth(duration: 0.8), value: LockStage.hasSong)
        .environment(\.lockMotion, motion)
        .environment(\.lockWidgetsPaused, !controller.isScreenAwake)
    }
}

/// The cover itself filling the screen: softened so it reads as a backdrop, and slowly breathing in and out.
struct LockBigCover: View {
    let artwork: NSImage
    @State private var soft: NSImage?
    @Environment(\.lockWidgetsPaused) private var paused
    @Environment(\.lockMotion) private var motion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            TimelineView(.animation(minimumInterval: 1 / 24, paused: paused || reduceMotion || !motion || soft == nil)) { timeline in
                let time = timeline.date.timeIntervalSinceReferenceDate
                ZStack {
                    Color.black
                    if let soft {
                        Image(nsImage: soft)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fill)
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .scaleEffect(1.16 + sin(time / 11) * 0.06)
                            .offset(x: cos(time / 13) * proxy.size.width * 0.02, y: sin(time / 9) * proxy.size.height * 0.03)
                            .transition(.opacity)
                    }
                    // Darker towards the edges, so the cover in the middle and the type on top stand out
                    RadialGradient(colors: [.black.opacity(0.18), .black.opacity(0.5)], center: .center, startRadius: 0, endRadius: proxy.size.width * 0.6)
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipped()
            }
        }
        .task(id: ObjectIdentifier(artwork)) {
            let next = await LockArtworkBackdrop.soften(artwork, side: 360, blur: 7, saturation: 1.25)
            withAnimation(.smooth(duration: 0.8)) {
                soft = next
            }
        }
    }
}

/// The sharp cover in the middle of its panel, with the song and the buttons below. Its own small panel,
/// so clicks only land here and everything else on the lock screen stays reachable.
struct LockStageCover: View {
    let side: CGFloat
    @ObservedObject private var music = MusicManager.shared
    @ObservedObject private var controller = LockScreenController.shared

    var body: some View {
        ZStack {
            Image(nsImage: music.albumArt)
                .resizable()
                .aspectRatio(1, contentMode: .fill)
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(.white.opacity(0.18), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.5), radius: 34, y: 18)
                .scaleEffect(music.isPlaying ? 1 : 0.93)
                .animation(.spring(response: 0.5, dampingFraction: 0.7), value: music.isPlaying)

            VStack(spacing: 8) {
                VStack(spacing: 1) {
                    Text(verbatim: music.songTitle)
                        .font(.system(size: 19, weight: .semibold, design: .rounded))
                    Text(verbatim: music.artistName)
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .opacity(0.75)
                }
                .lineLimit(1)
                LockMusicProgress()
                LockMusicButtons(size: 21)
            }
            .frame(width: side, height: LockStage.coverMargin.height - 24, alignment: .top)
            .offset(y: side / 2 + LockStage.coverMargin.height / 2 + 4)
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.3), radius: 4, y: 1)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .opacity(LockStage.hasSong ? 1 : 0)
        .animation(.smooth(duration: 0.8), value: LockStage.hasSong)
        .environment(\.lockWidgetsPaused, !controller.isScreenAwake)
    }
}
