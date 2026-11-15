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

/// Our own glass. The system's glass has nothing to look through on the lock screen and turns into a grey tile.
struct LockGlassBackground: View {
    let style: LockWidgetStyle
    var cornerRadius: CGFloat = 28

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            switch style.glass {
            case .clear:
                shape.fill(.white.opacity(0.10 * style.opacity))
            case .frosted:
                shape.fill(.black.opacity(0.42 * style.opacity))
                shape.fill(.white.opacity(0.07 * style.opacity))
            }
            // Light from the top left, as on real glass
            shape.fill(
                LinearGradient(
                    colors: [.white.opacity(0.16 * style.opacity), .clear, .white.opacity(0.04 * style.opacity)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            shape.strokeBorder(
                LinearGradient(
                    colors: [.white.opacity(0.5), .white.opacity(0.08), .white.opacity(0.22)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1
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
