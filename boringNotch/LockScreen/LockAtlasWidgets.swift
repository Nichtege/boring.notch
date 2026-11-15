//
//  LockAtlasWidgets.swift
//  boringNotch
//
//  Atlas on the lock screen: its latest answer with a button for one ready-made question,
//  and what Starlane knows about the usage limits and the next deadline.
//

import Defaults
import SwiftUI

struct LockAtlasWidget: View {
    let widget: LockWidget
    @ObservedObject private var chat = AtlasChat.shared
    @Environment(\.lockStyle) private var style
    @Environment(\.lockSize) private var size

    private var preset: String {
        widget.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var answerLines: Int {
        switch size {
        case .small: 4
        case .medium, .wide: 5
        case .large: 15
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                LockCaption(text: Text(verbatim: "Atlas"), symbol: "sparkle")
                Spacer(minLength: 0)
                if !preset.isEmpty {
                    LockMusicButton(symbol: "arrow.up.circle.fill", size: 17) {
                        chat.ask(preset)
                    }
                    .opacity(chat.isBusy ? 0.35 : 1)
                    // The caption's row keeps its height, button or not
                    .padding(.vertical, -6)
                    .padding(.trailing, -8)
                }
            }
            content
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var content: some View {
        if chat.isBusy {
            asked
            Text(chat.step.isEmpty ? String(localized: "Atlas is working…") : chat.step)
                .font(style.font(14, .medium))
                .opacity(0.75)
                .lineLimit(2)
        } else if case .failed(let message) = chat.phase {
            asked
            Text(verbatim: message)
                .font(style.font(14, .medium))
                .foregroundStyle(Color(red: 1, green: 0.66, blue: 0.3))
                .lineLimit(answerLines)
        } else if !chat.answer.isEmpty {
            if size != .small {
                asked
            }
            Text(chat.renderedAnswer)
                .font(style.font(size == .small ? 13 : 14, .medium))
                .lineLimit(answerLines)
                .truncationMode(.tail)
        } else if preset.isEmpty {
            Text("Ask Atlas from the notch, and the answer shows here.")
                .font(style.font(13, .medium))
                .opacity(0.7)
        } else {
            Text(verbatim: preset)
                .font(style.font(size == .small ? 14 : 16, .semibold))
                .lineLimit(size == .large ? 8 : 3)
                .opacity(0.85)
        }
    }

    private var asked: some View {
        Text(verbatim: chat.question)
            .font(style.font(12, .medium))
            .opacity(0.6)
            .lineLimit(1)
    }
}

// MARK: - Usage limits

struct LockLimitsWidget: View {
    @ObservedObject private var starlane = StarlaneManager.shared
    @Environment(\.lockStyle) private var style
    @Environment(\.lockSize) private var size

    var body: some View {
        if let limit = starlane.summary?.limit, !limit.isEmpty, starlane.status == .connected {
            VStack(alignment: .leading, spacing: 6) {
                LockCaption(text: Text("Usage limits"), symbol: "gauge.with.needle")
                Spacer(minLength: 0)
                HStack(spacing: size == .small ? 12 : 22) {
                    ForEach(limit.prefix(size == .small ? 2 : 3), id: \.window) { window in
                        ring(window)
                    }
                    Spacer(minLength: 0)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            LockWidgetHint(symbol: "gauge.with.needle", text: Text("No limits from Starlane"))
        }
    }

    private func ring(_ window: StarlaneSummary.LimitWindow) -> some View {
        let used = min(max(window.usedPercent, 0), 1000)
        let color: Color = used >= 95 ? Color(red: 1, green: 0.4, blue: 0.4)
            : used >= 80 ? Color(red: 1, green: 0.66, blue: 0.3)
            : style.accent.color
        let side: CGFloat = size == .small ? 54 : size == .large ? 92 : 64
        return VStack(spacing: 5) {
            ZStack {
                LockRing(value: used / 100, color: color, lineWidth: size == .large ? 8 : 6)
                Text(verbatim: "\(Int(used.rounded()))")
                    .font(style.font(side * 0.32, .semibold))
                    .monospacedDigit()
            }
            .frame(width: side, height: side)
            Text(verbatim: window.shortName)
                .font(style.font(12, .medium))
                .opacity(0.7)
            if size != .small {
                Text(Date(timeIntervalSince1970: window.resetsAt), format: .dateTime.weekday(.abbreviated).hour().minute())
                    .font(style.font(11, .medium))
                    .opacity(0.5)
            }
        }
        .lineLimit(1)
    }
}

// MARK: - Deadline

struct LockDeadlineWidget: View {
    @ObservedObject private var starlane = StarlaneManager.shared
    @Environment(\.lockStyle) private var style
    @Environment(\.lockSize) private var size

    var body: some View {
        if let deadline = starlane.summary?.nextDeadline, starlane.status == .connected {
            // The day turns over at midnight, also on a screen that stays locked
            LockTick(every: 60) { _ in
                let isSoon = (StarlaneView.daysUntil(deadline.date) ?? .max) <= 1
                VStack(alignment: .leading, spacing: 4) {
                    LockCaption(text: Text("Next deadline"), symbol: "flag")
                    Spacer(minLength: 0)
                    Text(verbatim: StarlaneView.relativeDay(deadline.date) ?? deadline.date)
                        .font(style.font(size == .small ? 26 : size == .large ? 44 : 32, .semibold))
                        .foregroundStyle(isSoon ? Color(red: 1, green: 0.66, blue: 0.3) : .white)
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                    Text(verbatim: deadline.title)
                        .font(style.font(size == .small ? 13 : 15, .medium))
                        .opacity(0.8)
                        .lineLimit(size == .large ? 5 : 2)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            LockWidgetHint(symbol: "flag", text: Text("No deadline from Starlane"))
        }
    }
}
