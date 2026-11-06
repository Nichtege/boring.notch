//
//  FocusView.swift
//  boringNotch
//
//  The Focus view, the timer that leads there, and what a running session shows in the closed notch.
//

import Defaults
import SwiftUI

struct FocusView: View {
    @ObservedObject var timer = FocusTimer.shared

    /// In minutes, also for Home
    static let sessionLengths = [25, 45, 60]

    var body: some View {
        HStack(alignment: .center, spacing: 28) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(alignment: .leading, spacing: 8) {
                    Text(timer.isRunning ? timer.clockText(at: context.date) : "0:00")
                        .font(.system(size: 52, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(timer.isRunning ? .white : .gray)
                    ProgressView(value: timer.isRunning ? timer.progress(at: context.date) : 0)
                        .progressViewStyle(.linear)
                        .tint(NotchStyle.focus)
                }
                .frame(width: 190, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: 12) {
                if timer.isRunning {
                    button("Stop", systemImage: "stop.fill") {
                        timer.stop()
                    }
                } else {
                    HStack(spacing: 8) {
                        ForEach(Self.sessionLengths, id: \.self) { minutes in
                            button("\(minutes) min", systemImage: "timer") {
                                timer.start(seconds: TimeInterval(minutes) * 60)
                            }
                        }
                    }
                }

                Defaults.Toggle(key: .focusHoldsBanners) {
                    Text("Hold Starlane banners during a session")
                        .font(.caption)
                        .foregroundStyle(.gray)
                }
                .toggleStyle(.checkbox)
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func button(_ title: LocalizedStringKey, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(NotchStyle.control))
                .contentShape(Capsule())
        }
        .buttonStyle(PlainButtonStyle())
    }
}

/// At the right of the open notch's header, beside the battery. Focus has no tab, as it's more a state than a
/// place; while a session runs this shows the minutes left.
struct FocusHeaderButton: View {
    @ObservedObject var timer = FocusTimer.shared
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @State private var isHovering = false

    private var isSelected: Bool {
        coordinator.currentView == .focus
    }

    var body: some View {
        Button {
            withAnimation(.smooth) {
                coordinator.currentView = .focus
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "timer")
                    .font(.body)
                if timer.isRunning {
                    FocusShortTime()
                }
            }
            .foregroundStyle(timer.isRunning ? NotchStyle.focus : isSelected ? .white : .gray)
            .padding(.horizontal, timer.isRunning ? 10 : 8)
            .frame(height: 26)
            .background(Capsule().fill(isSelected ? NotchStyle.control : isHovering ? NotchStyle.surface : .clear))
            .contentShape(Capsule())
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { isHovering = $0 }
        .accessibilityLabel(Text("Focus"))
    }
}

/// Beside the closed notch while a session runs and no music takes the space.
struct FocusLiveActivity: View {
    @EnvironmentObject var vm: BoringViewModel

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: "timer")
                .font(.caption)
                .foregroundStyle(NotchStyle.focus)
                .frame(width: max(0, vm.effectiveClosedNotchHeight - 12) + 10)

            Rectangle()
                .fill(.black)
                .frame(width: vm.closedNotchSize.width)

            FocusShortTime()
                .frame(width: max(0, vm.effectiveClosedNotchHeight - 12) + 10)
        }
        .frame(height: vm.effectiveClosedNotchHeight, alignment: .center)
    }
}

/// 24m, for the little space beside the closed notch.
struct FocusShortTime: View {
    @ObservedObject var timer = FocusTimer.shared

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(timer.shortText(at: context.date))
                .font(.caption2)
                .fontWeight(.semibold)
                .notchNumber()
                .foregroundStyle(NotchStyle.focus)
                .lineLimit(1)
                .fixedSize()
        }
    }
}
