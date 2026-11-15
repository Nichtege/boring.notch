//
//  LockWidgetChrome.swift
//  boringNotch
//
//  What every lock screen widget shares: its glass, its type and its clock tick.
//

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

extension EnvironmentValues {
    var lockStyle: LockWidgetStyle {
        get { self[LockWidgetStyleKey.self] }
        set { self[LockWidgetStyleKey.self] = newValue }
    }

    var lockSize: LockWidgetSize {
        get { self[LockWidgetSizeKey.self] }
        set { self[LockWidgetSizeKey.self] = newValue }
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

    private var seesThrough: Bool {
        style.glass != .clear && !isPreview && LockLiquidGlass.isAvailable
    }

    /// How much black sits in the glass, so white type holds up on a bright picture
    private var smoke: Double {
        switch style.glass {
        case .liquid: 0.05
        case .liquidDark: 0.3
        case .frosted: seesThrough ? 0.14 : 0.4
        case .clear: 0
        }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            if seesThrough {
                LockLiquidGlass(
                    cornerRadius: cornerRadius,
                    refraction: style.glass == .frosted ? 14 : 40,
                    blur: style.glass == .frosted ? 16 : style.glass == .liquidDark ? 3 : 2,
                    saturation: 1.5
                )
            }
            shape.fill(.black.opacity(min(smoke * style.opacity, 0.85)))
            shape.fill(.white.opacity(0.05 * style.opacity))
            if style.accent != .white {
                shape.fill(style.accent.color.opacity(0.12 * style.opacity))
            }
            // The edge of a thick pane catches more light than its middle
            shape
                .strokeBorder(.white.opacity(0.22), lineWidth: 8)
                .blur(radius: 8)
                .clipShape(shape)
            // Light enters at the top left and leaves at the bottom right
            shape.strokeBorder(
                AngularGradient(
                    stops: [
                        .init(color: .white.opacity(0.1), location: 0),
                        .init(color: .white.opacity(0.55), location: 0.12),
                        .init(color: .white.opacity(0.08), location: 0.3),
                        .init(color: .white.opacity(0.05), location: 0.5),
                        .init(color: .white.opacity(0.95), location: 0.63),
                        .init(color: .white.opacity(0.85), location: 0.7),
                        .init(color: .white.opacity(0.06), location: 0.86),
                        .init(color: .white.opacity(0.1), location: 1),
                    ],
                    center: .center
                ),
                lineWidth: 1.2
            )
        }
        .shadow(color: .black.opacity(0.22), radius: 14, y: 6)
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
