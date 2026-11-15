//
//  LockEvents.swift
//  boringNotch
//
//  The next calendar events and open reminders for the lock screen, through EventKit.
//

import EventKit
import SwiftUI

struct LockEvent: Identifiable, Equatable {
    let id: String
    let title: String
    let start: Date
    let isAllDay: Bool
    let color: Color
}

struct LockReminder: Identifiable, Equatable {
    let id: String
    let title: String
    let due: Date?
    let color: Color
}

@MainActor
final class LockEvents: ObservableObject {
    static let shared = LockEvents()

    @Published private(set) var events: [LockEvent] = []
    @Published private(set) var reminders: [LockReminder] = []
    @Published private(set) var canReadEvents = false
    @Published private(set) var canReadReminders = false

    private let store = EKEventStore()
    private var lastRefresh = Date.distantPast
    private static let maxAge: TimeInterval = 5 * 60

    private init() {
        readAccess()
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, LockScreenController.shared.isLive else { return }
                self.refresh()
            }
        }
    }

    private func readAccess() {
        canReadEvents = EKEventStore.authorizationStatus(for: .event) == .fullAccess
        canReadReminders = EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
    }

    /// Asks macOS for access. Only from the settings, as the lock screen can't show the question.
    func requestAccess(to type: EKEntityType) {
        Task {
            if type == .event {
                _ = try? await store.requestFullAccessToEvents()
            } else {
                _ = try? await store.requestFullAccessToReminders()
            }
            readAccess()
            refresh()
        }
    }

    func refreshIfStale() {
        guard Date().timeIntervalSince(lastRefresh) > Self.maxAge else { return }
        refresh()
    }

    func refresh() {
        lastRefresh = Date()
        readAccess()

        if canReadEvents {
            let now = Date()
            let end = Calendar.current.date(byAdding: .day, value: 14, to: now) ?? now
            let predicate = store.predicateForEvents(withStart: now, end: end, calendars: nil)
            events = store.events(matching: predicate)
                .sorted { $0.startDate < $1.startDate }
                .prefix(8)
                .map {
                    LockEvent(
                        id: "\($0.eventIdentifier ?? $0.title ?? "")-\($0.startDate.timeIntervalSince1970)",
                        title: $0.title ?? "",
                        start: $0.startDate,
                        isAllDay: $0.isAllDay,
                        color: Color(nsColor: $0.calendar.color)
                    )
                }
        } else {
            events = []
        }

        if canReadReminders {
            let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
            store.fetchReminders(matching: predicate) { found in
                let open = (found ?? [])
                    .map { reminder -> LockReminder in
                        LockReminder(
                            id: reminder.calendarItemIdentifier,
                            title: reminder.title ?? "",
                            due: reminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) },
                            color: Color(nsColor: reminder.calendar.color)
                        )
                    }
                    // Those with a day first, soonest at the top
                    .sorted { ($0.due ?? .distantFuture, $0.title) < ($1.due ?? .distantFuture, $1.title) }
                Task { @MainActor in
                    self.reminders = Array(open.prefix(8))
                }
            }
        } else {
            reminders = []
        }
    }
}
