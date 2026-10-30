//
//  StarlaneView.swift
//  boringNotch
//
//  The Starlane tab: who needs you, what is finished, what comes next.
//

import Defaults
import KeyboardShortcuts
import SwiftUI

struct StarlaneView: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject var starlane = StarlaneManager.shared
    @Default(.starlaneShowDeadline) private var showDeadline
    @State private var isHoveringAtlasBar = false

    private let maxRows = 3
    private let infoWidth: CGFloat = 176

    var body: some View {
        if let summary = starlane.summary {
            let attention = summary.terminals.filter { ["needs", "failed", "limited"].contains($0.state) }
            let done = summary.terminals.filter { $0.state == "done" }
            let deadline = showDeadline ? summary.nextDeadline : nil
            let limit = summary.limit ?? []

            VStack(spacing: 8) {
                HStack(alignment: .top, spacing: 14) {
                    section(title: "Needs you", accent: .orange, count: attention.count, rows: attention, emptyText: "Nothing is waiting")
                    section(title: "Done", accent: .green, count: done.count, rows: done, emptyText: "Nothing new")
                    if deadline != nil || !limit.isEmpty {
                        infoCard(deadline: deadline, limit: limit)
                            .frame(width: infoWidth)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                HStack(spacing: 10) {
                    atlasBar
                    counts(summary)
                    openButton
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    // MARK: - Terminals
    private func section(
        title: LocalizedStringKey,
        accent: Color,
        count: Int,
        rows: [StarlaneSummary.Terminal],
        emptyText: LocalizedStringKey
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.gray)
                if count > 0 {
                    Text("\(count)")
                        .font(.caption2)
                        .fontWeight(.bold)
                        .monospacedDigit()
                        .foregroundStyle(.black)
                        .padding(.horizontal, 5)
                        .background(Capsule().fill(accent))
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 2)

            if rows.isEmpty {
                Text(emptyText)
                    .font(.caption)
                    .foregroundStyle(.gray.opacity(0.7))
                    .padding(.horizontal, 6)
            } else {
                ForEach(Array(rows.prefix(maxRows).enumerated()), id: \.offset) { _, row in
                    StarlaneTerminalRow(terminal: row) {
                        starlane.openDashboard(terminal: row.id)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Deadline and limit
    private func infoCard(deadline: StarlaneSummary.Deadline?, limit: [StarlaneSummary.LimitWindow]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let deadline {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text("Next deadline")
                            .foregroundStyle(.gray)
                        Spacer(minLength: 0)
                        if let relative = relativeDay(deadline.date) {
                            Text(relative)
                                .foregroundStyle(.orange)
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
            if !limit.isEmpty {
                VStack(spacing: 4) {
                    ForEach(limit, id: \.window) { window in
                        StarlaneLimitBar(window: window)
                    }
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(.white.opacity(0.07)))
    }

    // MARK: - Bottom row
    private var atlasBar: some View {
        Button {
            vm.close()
            // Closing takes the focus along, so the line opens once the notch is out of the way
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(250))
                AtlasPromptController.shared.open()
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.white)
                Text("Ask Atlas…")
                    .foregroundStyle(.gray)
                Spacer(minLength: 8)
                if let shortcut = KeyboardShortcuts.getShortcut(for: .askAtlas) {
                    Text(shortcut.description)
                        .font(.caption2)
                        .foregroundStyle(.gray.opacity(0.8))
                }
            }
            .font(.caption)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(.white.opacity(isHoveringAtlasBar ? 0.16 : 0.09))
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { isHoveringAtlasBar = $0 }
    }

    private func counts(_ summary: StarlaneSummary) -> some View {
        HStack(spacing: 9) {
            Label("\(summary.busy)", systemImage: "play.circle")
                .help(Text("Running"))
            if summary.paused > 0 {
                Label("\(summary.paused)", systemImage: "pause.circle")
                    .help(Text("Paused"))
            }
            if summary.limited > 0 {
                Label("\(summary.limited)", systemImage: "hourglass")
                    .foregroundStyle(.yellow)
                    .help(Text("At usage limit"))
            }
        }
        .labelStyle(.titleAndIcon)
        .font(.caption)
        .monospacedDigit()
        .foregroundStyle(.gray)
        .fixedSize()
    }

    private var openButton: some View {
        Button {
            starlane.openDashboard()
        } label: {
            Image(systemName: "arrow.up.forward.app")
                .font(.body)
                .foregroundStyle(.gray)
                .frame(width: 24, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .help(Text("Open Starlane"))
    }

    private func relativeDay(_ date: String) -> String? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        guard let day = formatter.date(from: date) else { return nil }

        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: Date()), to: calendar.startOfDay(for: day)).day ?? 0
        let relative = RelativeDateTimeFormatter()
        relative.dateTimeStyle = .named
        relative.unitsStyle = .full
        return relative.localizedString(from: DateComponents(day: days))
    }
}

private struct StarlaneTerminalRow: View {
    let terminal: StarlaneSummary.Terminal
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                stateIcon
                    .frame(width: 12)
                Text(terminal.name)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 2)
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.gray)
                    .opacity(isHovering ? 1 : 0)
            }
            .font(.caption)
            .padding(.horizontal, 6)
            .frame(height: 19)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.white.opacity(isHovering ? 0.1 : 0))
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { isHovering = $0 }
    }

    @ViewBuilder
    private var stateIcon: some View {
        switch terminal.state {
        case "failed":
            Image(systemName: "xmark.octagon.fill")
                .font(.caption2)
                .foregroundStyle(.red)
        case "limited":
            Image(systemName: "hourglass")
                .font(.caption2)
                .foregroundStyle(.yellow)
        case "done":
            Image(systemName: "checkmark")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.green)
        default:
            Circle()
                .fill(.orange)
                .frame(width: 6, height: 6)
        }
    }
}

private struct StarlaneLimitBar: View {
    let window: StarlaneSummary.LimitWindow

    private var color: Color {
        window.usedPercent >= 95 ? .red : window.usedPercent >= 80 ? .orange : .white
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(window.shortName)
                .foregroundStyle(.gray)
                .frame(width: 22, alignment: .leading)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.14))
                    Capsule()
                        .fill(color)
                        .frame(width: geometry.size.width * min(1, max(0, window.usedPercent / 100)))
                }
            }
            .frame(height: 4)
            Text("\(Int(window.usedPercent.rounded())) %")
                .foregroundStyle(color == .white ? .gray : color)
                .frame(width: 32, alignment: .trailing)
        }
        .font(.caption2)
        .monospacedDigit()
        .help(Text("Usage limit, resets \(Date(timeIntervalSince1970: window.resetsAt).formatted(date: .omitted, time: .shortened))"))
    }
}

/// Shown in the closed notch while a terminal waits and no music is taking the space.
struct StarlaneLiveActivity: View {
    @EnvironmentObject var vm: BoringViewModel
    let needs: Int

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: "exclamationmark.bubble.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .frame(width: max(0, vm.effectiveClosedNotchHeight - 12) + 10)

            Rectangle()
                .fill(.black)
                .frame(width: vm.closedNotchSize.width)

            Text("\(needs)")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.orange)
                .frame(width: max(0, vm.effectiveClosedNotchHeight - 12) + 10)
        }
        .frame(height: vm.effectiveClosedNotchHeight, alignment: .center)
    }
}
