//
//  NotchSideBall.swift
//  boringNotch
//
//  The second thing going on, as a small ball beside the notch, the way the Dynamic Island does it: what
//  plays keeps the notch, and the ball squeezes out of its edge and back in.
//

import SwiftUI

enum NotchSideActivity: Equatable {
    case focus
    case starlane
}

struct NotchSideBall: View {
    static let animation = Animation.spring(response: 0.5, dampingFraction: 0.68)
    static let gapToNotch: CGFloat = 6

    let activity: NotchSideActivity
    let diameter: CGFloat
    let onTap: () -> Void

    @ObservedObject private var timer = FocusTimer.shared
    @ObservedObject private var starlane = StarlaneManager.shared
    @State private var isHovering = false

    var body: some View {
        Button(action: onTap) {
            ZStack {
                Circle()
                    .fill(.black)
                content
                    .id(activity)
                    .transition(.opacity)
            }
            .animation(.smooth(duration: 0.25), value: activity)
            .frame(width: diameter, height: diameter)
            .scaleEffect(isHovering ? 1.08 : 1)
            .contentShape(Circle())
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { hovering in
            withAnimation(.smooth(duration: 0.2)) {
                isHovering = hovering
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch activity {
        case .focus:
            TimelineView(.periodic(from: .now, by: 1)) { context in
                ZStack {
                    Circle()
                        .stroke(.orange.opacity(0.25), lineWidth: 2)
                    Circle()
                        .trim(from: 0, to: max(0, 1 - timer.progress(at: context.date)))
                        .stroke(.orange, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text(timer.shortText(at: context.date))
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.orange)
                        .minimumScaleFactor(0.7)
                        .lineLimit(1)
                }
                .padding(2)
            }
        case .starlane:
            HStack(spacing: 1) {
                Image(systemName: "exclamationmark.bubble.fill")
                    .font(.system(size: 10))
                Text("\(starlane.summary?.needs ?? 0)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }
            .foregroundStyle(.orange)
            .minimumScaleFactor(0.7)
            .lineLimit(1)
        }
    }
}

/// How far a ball has come out of the notch: 0 behind its edge, 1 in its place, and past 1 when the spring overshoots.
/// On the way it stretches and stays joined to the notch by a neck that thins until it snaps.
struct NotchSideBallEmergence: ViewModifier, Animatable {
    var progress: CGFloat
    let diameter: CGFloat

    private var travel: CGFloat {
        diameter + NotchSideBall.gapToNotch
    }

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let clamped = min(max(progress, 0), 1)
        let stretch = sin(clamped * .pi)
        let size = 0.55 + 0.45 * progress
        let neckWidth = diameter / 2 + NotchSideBall.gapToNotch
        let neckHeight = diameter * 0.55 * (1 - clamped)

        content
            .scaleEffect(x: size * (1 + 0.3 * stretch), y: size * (1 - 0.18 * stretch))
            .background(alignment: .leading) {
                Capsule()
                    .fill(.black)
                    .frame(width: neckWidth, height: neckHeight)
                    .offset(x: -NotchSideBall.gapToNotch)
            }
            .offset(x: -travel * (1 - progress))
    }
}
