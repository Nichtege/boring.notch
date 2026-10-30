//
//  FocusView.swift
//  boringNotch
//
//  The Focus tab, and what a running session shows in the closed notch.
//

import Defaults
import SwiftUI

struct FocusView: View {
    @ObservedObject var timer = FocusTimer.shared

    private let sessionLengths = [25, 45, 60]

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
                        .tint(.orange)
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
                        ForEach(sessionLengths, id: \.self) { minutes in
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
                .background(Capsule().fill(.white.opacity(0.15)))
                .contentShape(Capsule())
        }
        .buttonStyle(PlainButtonStyle())
    }
}

/// Beside the closed notch while a session runs and no music takes the space.
struct FocusLiveActivity: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject var timer = FocusTimer.shared

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: "timer")
                .font(.caption)
                .foregroundStyle(.orange)
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
                .monospacedDigit()
                .foregroundStyle(.orange)
                .lineLimit(1)
                .fixedSize()
        }
    }
}
