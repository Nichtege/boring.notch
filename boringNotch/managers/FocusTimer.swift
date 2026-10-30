//
//  FocusTimer.swift
//  boringNotch
//
//  A focus session that counts down in the notch. It ends silently with a banner, so it fits a library too.
//

import Combine
import Defaults
import Foundation

@MainActor
final class FocusTimer: ObservableObject {
    static let shared = FocusTimer()

    @Published private(set) var endDate: Date?
    @Published private(set) var duration: TimeInterval = 0

    private var task: Task<Void, Never>?

    var isRunning: Bool {
        endDate != nil
    }

    /// Whether Starlane's "needs you" banners wait until the session is over.
    var holdsBanners: Bool {
        isRunning && Defaults[.focusHoldsBanners]
    }

    private init() {}

    func start(seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        duration = seconds
        endDate = end

        task?.cancel()
        task = Task { [weak self] in
            // A date, not a countdown, so a sleeping Mac doesn't stretch the session. Short sleeps with
            // a tolerance, as a long one can wake many seconds late.
            while !Task.isCancelled, Date() < end {
                try? await Task.sleep(for: .seconds(min(end.timeIntervalSinceNow, 60)), tolerance: .seconds(1))
            }
            guard !Task.isCancelled else { return }
            self?.finish()
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        endDate = nil
    }

    private func finish() {
        task = nil
        endDate = nil
        BoringViewCoordinator.shared.toggleExpandingView(status: true, type: .focus)
    }

    func remaining(at date: Date) -> TimeInterval {
        max(0, (endDate ?? date).timeIntervalSince(date))
    }

    func progress(at date: Date) -> Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, 1 - remaining(at: date) / duration))
    }

    /// 24:13
    func clockText(at date: Date) -> String {
        let seconds = Int(remaining(at: date).rounded(.up))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// What fits beside the closed notch: 24m, then 45s in the last minute.
    func shortText(at date: Date) -> String {
        let seconds = Int(remaining(at: date).rounded(.up))
        return seconds > 60 ? "\(Int((Double(seconds) / 60).rounded(.up)))m" : "\(seconds)s"
    }
}
