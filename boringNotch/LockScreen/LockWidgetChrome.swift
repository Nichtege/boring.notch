//
//  LockWidgetChrome.swift
//  boringNotch
//
//  What every lock screen widget shares: its glass, its type and its clock tick.
//

import Defaults
import SwiftUI

private struct LockWidgetStyleKey: EnvironmentKey {
    static let defaultValue = LockWidgetStyle()
}

private struct LockWidgetSizeKey: EnvironmentKey {
    static let defaultValue = LockWidgetSize.medium
}

private struct LockWidgetsPausedKey: EnvironmentKey {
    static let defaultValue = false
}

private struct LockWidgetScreenFrameKey: EnvironmentKey {
    static let defaultValue: CGRect? = nil
}

extension EnvironmentValues {
    var lockStyle: LockWidgetStyle {
        get { self[LockWidgetStyleKey.self] }
        set { self[LockWidgetStyleKey.self] = newValue }
    }

    var lockSize: LockWidgetSize {
        get { self[LockWidgetSizeKey.self] }
        set { self[LockWidgetSizeKey.self] = newValue }
    }

    /// Where the widget is on screen, in AppKit's coordinates. Missing in the settings preview.
    var lockWidgetScreenFrame: CGRect? {
        get { self[LockWidgetScreenFrameKey.self] }
        set { self[LockWidgetScreenFrameKey.self] = newValue }
    }

    /// True while nobody can see the widgets, so nothing redraws on a timer.
    var lockWidgetsPaused: Bool {
        get { self[LockWidgetsPausedKey.self] }
        set { self[LockWidgetsPausedKey.self] = newValue }
    }
}

extension LockWidgetStyle {
    func font(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: font.design)
    }
}

/// The glass behind a widget. It looks through to what's behind the panel where macOS allows that,
/// and is otherwise drawn to look the part.
struct LockGlassBackground: View {
    let style: LockWidgetStyle
    /// In the settings there is a stand-in wallpaper inside the window, which the real glass would look past
    var isPreview = false
    var cornerRadius: CGFloat = 28

    @Default(.lockScreenGlassBlur) private var blur

    private var seesThrough: Bool {
        style.glass != .simple && !isPreview && LockLiquidGlass.isAvailable
    }

    /// How much black sits in the glass, so white type holds up on a bright picture
    private var smoke: Double {
        switch style.glass {
        case .liquid: 0.1
        case .liquidDark: 0.34
        case .frosted: seesThrough ? 0.14 : 0.4
        case .simple, .bare: 0
        }
    }

    var body: some View {
        if style.glass != .bare {
            pane
        }
    }

    private var pane: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return ZStack {
            // The pane's shadow, kept off the pane itself, which would only get murkier from it
            shape
                .fill(.black.opacity(0.32))
                .blur(radius: 12)
                .offset(y: 6)
                .mask {
                    Rectangle()
                        .padding(-40)
                        .overlay { shape.blendMode(.destinationOut) }
                        .compositingGroup()
                }
            if seesThrough {
                LockLiquidGlass(
                    cornerRadius: cornerRadius,
                    blur: style.glass == .frosted ? max(blur * 2, 9) : blur,
                    saturation: 1.25
                )
            }
            shape.fill(.black.opacity(min(smoke * style.opacity, 0.85)))
            shape.fill(.white.opacity(0.05 * style.opacity))
            if style.accent != .white {
                shape.fill(style.accent.color.opacity(0.12 * style.opacity))
            }
            LockGlassLight(shape: shape)
        }
    }
}

/// The light on the glass: a faint glow along the rim and two thin bright arcs where light enters and leaves.
/// The arcs turn towards the pointer and the pane brightens a little near it, the way a real pane answers a lamp.
struct LockGlassLight: View {
    let shape: RoundedRectangle
    @Environment(\.lockWidgetScreenFrame) private var frame
    @Environment(\.lockWidgetsPaused) private var paused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Default(.lockScreenGlassAlive) private var alive

    /// Where the brighter arc sits in the gradient below, as an angle: up and to the left
    private static let restAngle = 238.0

    var body: some View {
        if alive, !reduceMotion, let frame {
            TimelineView(.animation(minimumInterval: 1 / 20, paused: paused)) { _ in
                let pointer = NSEvent.mouseLocation
                // AppKit counts up from the bottom, the gradient turns clockwise from the right
                let towards = atan2(-(pointer.y - frame.midY), pointer.x - frame.midX) * 180 / .pi
                let local = UnitPoint(
                    x: (pointer.x - frame.minX) / max(frame.width, 1),
                    y: (frame.maxY - pointer.y) / max(frame.height, 1)
                )
                let distance = hypot(
                    max(frame.minX - pointer.x, 0, pointer.x - frame.maxX),
                    max(frame.minY - pointer.y, 0, pointer.y - frame.maxY)
                )
                light(turn: towards - Self.restAngle, glowAt: local, glow: max(0, 1 - distance / 260))
            }
        } else {
            light(turn: 0, glowAt: .topLeading, glow: 0)
        }
    }

    private func light(turn: Double, glowAt: UnitPoint, glow: Double) -> some View {
        ZStack {
            // The edge of a thick pane catches more light than its middle
            shape
                .strokeBorder(.white.opacity(0.1), lineWidth: 6)
                .blur(radius: 6)
                .clipShape(shape)
            if glow > 0 {
                shape
                    .fill(
                        RadialGradient(
                            colors: [.white.opacity(0.1 * glow), .clear],
                            center: glowAt,
                            startRadius: 0,
                            endRadius: 180
                        )
                    )
                    .blendMode(.plusLighter)
            }
            shape.strokeBorder(
                AngularGradient(
                    stops: [
                        .init(color: .white.opacity(0.08), location: 0),
                        .init(color: .white.opacity(0.32), location: 0.12),
                        .init(color: .white.opacity(0.08), location: 0.3),
                        .init(color: .white.opacity(0.06), location: 0.5),
                        .init(color: .white.opacity(0.6), location: 0.63),
                        .init(color: .white.opacity(0.5), location: 0.7),
                        .init(color: .white.opacity(0.06), location: 0.86),
                        .init(color: .white.opacity(0.08), location: 1),
                    ],
                    center: .center,
                    angle: .degrees(turn)
                ),
                lineWidth: 1
            )
        }
        .allowsHitTesting(false)
    }
}

/// A soft band of light that crosses the glass now and then. Widgets further right get it later,
/// so it reads as one light moving over the whole screen.
struct LockLightSweep: View {
    let column: Int
    @Environment(\.lockWidgetsPaused) private var paused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let period: TimeInterval = 14

    var body: some View {
        if !reduceMotion {
            TimelineView(.animation(minimumInterval: 1 / 20, paused: paused)) { timeline in
                let time = timeline.date.timeIntervalSinceReferenceDate - Double(column) * 0.12
                let turn = time.truncatingRemainder(dividingBy: Self.period) / Self.period
                GeometryReader { proxy in
                    // Crosses in the first third of the period and is away for the rest
                    let travel = min(turn * 3, 1)
                    let band = proxy.size.width * 0.6
                    LinearGradient(colors: [.clear, .white.opacity(0.16), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: band)
                        .rotationEffect(.degrees(18))
                        .scaleEffect(y: 1.6)
                        .offset(x: -band + (proxy.size.width + band * 2) * travel - band / 2)
                        .opacity(travel < 1 ? 1 : 0)
                }
                .blendMode(.plusLighter)
            }
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .allowsHitTesting(false)
        }
    }
}

/// Redraws its content on the clock, and not at all while the widgets are paused.
struct LockTick<Content: View>: View {
    let every: TimeInterval
    @ViewBuilder let content: (Date) -> Content
    @Environment(\.lockWidgetsPaused) private var paused

    var body: some View {
        if paused {
            content(Date())
        } else if every >= 60 {
            TimelineView(.everyMinute) { content($0.date) }
        } else {
            TimelineView(.periodic(from: Self.wholeSecond, by: every)) { content($0.date) }
        }
    }

    private static var wholeSecond: Date {
        Date(timeIntervalSinceReferenceDate: Date().timeIntervalSinceReferenceDate.rounded(.down))
    }
}

/// A thin ring that fills clockwise.
struct LockRing: View {
    let value: Double
    let color: Color
    var lineWidth: CGFloat = 7

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.16), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(max(value, 0), 1))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

/// The small caption above a widget's content.
struct LockCaption: View {
    let text: Text
    var symbol: String?
    @Environment(\.lockStyle) private var style

    var body: some View {
        HStack(spacing: 5) {
            if let symbol {
                Image(systemName: symbol)
            }
            text
        }
        .font(style.font(12, .semibold))
        .foregroundStyle(style.accent.color.opacity(style.accent == .white ? 0.7 : 1))
        .lineLimit(1)
    }
}
