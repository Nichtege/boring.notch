//
//  StarlaneView.swift
//  boringNotch
//
//  The Starlane tab: who needs you, what is finished, what comes next.
//

import Defaults
import SwiftUI

struct StarlaneView: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject var starlane = StarlaneManager.shared
    @Default(.starlaneShowDeadline) private var showDeadline

    private let maxRows = 4

    var body: some View {
        if let summary = starlane.summary {
            HStack(alignment: .top, spacing: 20) {
                let attention = summary.terminals.filter { ["needs", "failed", "limited"].contains($0.state) }
                column(
                    title: "Needs you",
                    icon: "exclamationmark.bubble.fill",
                    color: .orange,
                    count: attention.count,
                    rows: attention,
                    emptyText: "Nothing is waiting"
                )
                column(
                    title: "Done",
                    icon: "checkmark.circle.fill",
                    color: .green,
                    count: summary.done,
                    rows: summary.terminals.filter { $0.state == "done" },
                    emptyText: "Nothing new"
                )
                sidebar(summary)
                    .frame(width: 170, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func column(
        title: LocalizedStringKey,
        icon: String,
        color: Color,
        count: Int,
        rows: [StarlaneSummary.Terminal],
        emptyText: LocalizedStringKey
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundStyle(color)
                Text(title)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                Text("\(count)")
                    .foregroundStyle(.gray)
            }
            .font(.subheadline)

            if rows.isEmpty {
                Text(emptyText)
                    .font(.caption)
                    .foregroundStyle(.gray)
            } else {
                ForEach(Array(rows.prefix(maxRows).enumerated()), id: \.offset) { _, row in
                    terminalRow(row)
                }
                if rows.count > maxRows {
                    Text("+\(rows.count - maxRows)")
                        .font(.caption)
                        .foregroundStyle(.gray)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func terminalRow(_ row: StarlaneSummary.Terminal) -> some View {
        Button {
            starlane.openDashboard(terminal: row.id)
        } label: {
            HStack(spacing: 5) {
                if row.state == "failed" || row.state == "limited" {
                    Image(systemName: row.state == "failed" ? "xmark.octagon.fill" : "hourglass")
                        .foregroundStyle(row.state == "failed" ? .red : .yellow)
                }
                Text(row.name)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .font(.caption)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
    }

    private func sidebar(_ summary: StarlaneSummary) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 10) {
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
            .font(.caption)
            .foregroundStyle(.gray)

            if let limit = summary.limit, !limit.isEmpty {
                HStack(spacing: 10) {
                    ForEach(limit, id: \.window) { window in
                        limitLabel(window)
                    }
                }
            }

            if showDeadline, let deadline = summary.nextDeadline {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Next deadline")
                        .font(.caption2)
                        .foregroundStyle(.gray)
                    Text(deadline.title)
                        .font(.caption)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    if let relative = relativeDay(deadline.date) {
                        Text(relative)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }

            Spacer(minLength: 0)

            Button {
                vm.close()
                // Closing takes the focus along, so the line opens once the notch is out of the way
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(250))
                    AtlasPromptController.shared.open()
                }
            } label: {
                Label("Atlas", systemImage: "sparkles")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(.white.opacity(0.15)))
                    .contentShape(Capsule())
            }
            .buttonStyle(PlainButtonStyle())

            Button {
                starlane.openDashboard()
            } label: {
                Label("Open Starlane", systemImage: "arrow.up.forward.app")
                    .font(.caption)
                    .foregroundStyle(.white)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(.bottom, 2)
    }

    private func limitLabel(_ window: StarlaneSummary.LimitWindow) -> some View {
        HStack(spacing: 3) {
            Text(window.shortName)
                .foregroundStyle(.gray)
            Text("\(Int(window.usedPercent.rounded())) %")
                .foregroundStyle(window.usedPercent >= 80 ? .orange : .white)
        }
        .font(.caption)
        .monospacedDigit()
        .help(Text("Usage limit, resets \(Date(timeIntervalSince1970: window.resetsAt).formatted(date: .omitted, time: .shortened))"))
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
