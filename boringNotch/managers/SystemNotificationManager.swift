//
//  SystemNotificationManager.swift
//  boringNotch
//
//  Shows the notification banners of other apps as a card under the notch. A banner only moves off
//  screen once its card is really up, and when in doubt it stays where it is. What a banner says stays
//  in memory on this Mac.
//

import AppKit
import Combine
import Defaults

struct SystemNotification: Identifiable, Equatable {
    var id = UUID().uuidString
    var appName: String?
    var bundleID: String?
    var title: String?
    var subtitle: String?
    var body: String?
    var receivedAt = Date()
}

@MainActor
final class SystemNotificationManager {
    static let shared = SystemNotificationManager()

    private let queueLimit = 5
    private let displayDuration: Duration = .seconds(8)
    // A check is two trips to the helper. While it's watching it looks after the permission itself and
    // says when it stops, so this is only a safety net.
    private let watchingCheckInterval: Duration = .seconds(30)
    // Waiting for the permission to be given
    private let waitingCheckInterval: Duration = .seconds(3)
    private var activeNotification: SystemNotification?
    private var queuedNotifications: [SystemNotification] = []
    private var isCardHovered = false
    private var didAskForPermission = false
    private var dismissTask: Task<Void, Never>?
    private var permissionTask: Task<Void, Never>?
    private var settingCancellable: AnyCancellable?
    private var fullscreenCancellable: AnyCancellable?
    private var helperLostObserver: NSObjectProtocol?

    private init() {}

    func start() {
        // Whatever the setting says: a banner may have been left off screen by a helper that died
        XPCHelperClient.shared.restoreStrandedNotifications()

        settingCancellable = Defaults.publisher(.showNotificationsInNotch)
            .map(\.newValue)
            .removeDuplicates()
            .sink { [weak self] enabled in
                Task { @MainActor in self?.setEnabled(enabled) }
            }

        fullscreenCancellable = FullscreenMediaDetector.shared.$fullscreenStatus
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in
                    if FullscreenMediaDetector.shared.hidesClosedNotch {
                        self?.dismissAll()
                    }
                }
            }

        helperLostObserver = NotificationCenter.default.addObserver(
            forName: .xpcHelperConnectionLost, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.helperLost() }
        }
    }

    // MARK: - Watching
    private func setEnabled(_ enabled: Bool) {
        guard enabled else {
            permissionTask?.cancel()
            permissionTask = nil
            XPCHelperClient.shared.stopNotificationWatching()
            dismissAll()
            return
        }
        checkWatchingNow()
    }

    /// Checks at once and starts over from there, slowly once the helper is watching.
    func checkWatchingNow() {
        permissionTask?.cancel()
        permissionTask = nil
        guard Defaults[.showNotificationsInNotch] else { return }

        permissionTask = Task { [weak self, watchingCheckInterval, waitingCheckInterval] in
            while !Task.isCancelled {
                let isWatching = await self?.syncWatching() ?? false
                try? await Task.sleep(for: isWatching ? watchingCheckInterval : waitingCheckInterval)
            }
        }
    }

    /// Runs all the time the feature is on, since the permission can come and go. Starting is harmless
    /// when the helper is already watching, and heals anything that made it stop. True if it's watching.
    private func syncWatching() async -> Bool {
        guard Defaults[.showNotificationsInNotch] else { return false }

        var authorized = await XPCHelperClient.shared.isAccessibilityAuthorized()
        if !authorized, !didAskForPermission {
            didAskForPermission = true
            authorized = await XPCHelperClient.shared.ensureAccessibilityAuthorization(promptIfNeeded: true)
        }
        guard Defaults[.showNotificationsInNotch] else { return false }

        // Without the permission cards stay and time out as usual. A helper that can't move windows any
        // more leaves a parked banner off screen, so its card may be all that's left of the notification.
        guard authorized else { return false }

        let isWatching = await XPCHelperClient.shared.startNotificationWatching()
        // Turned off while the helper was on its way
        if !Defaults[.showNotificationsInNotch] {
            XPCHelperClient.shared.stopNotificationWatching()
        }
        return isWatching
    }

    /// The helper is gone and with it whatever it had parked: a new one looks for such windows when
    /// it starts. The short pause keeps a helper that keeps crashing from relaunching in a tight loop.
    private func helperLost() async {
        try? await Task.sleep(for: .seconds(1))
        XPCHelperClient.shared.restoreStrandedNotifications()
        checkWatchingNow()
    }

    // MARK: - Cards
    func bannerDidAppear(_ payload: [String: String]) {
        guard let token = payload["token"], !token.isEmpty else { return }
        // The helper has already taken the banner away, and without a card it has to come back
        guard canShowCards else {
            XPCHelperClient.shared.restoreNotification(token)
            return
        }

        let notification = SystemNotification(
            id: token,
            appName: nonEmpty(payload["appName"]),
            bundleID: nonEmpty(payload["bundleID"]),
            title: nonEmpty(payload["title"]),
            subtitle: nonEmpty(payload["subtitle"]),
            body: nonEmpty(payload["body"])
        )

        guard activeNotification == nil || !isCardHovered else {
            // Its banner comes back until its card comes, so nothing is lost if this one gets dropped
            XPCHelperClient.shared.restoreNotification(token)
            queuedNotifications.append(notification)
            if queuedNotifications.count > queueLimit {
                queuedNotifications.removeFirst()
            }
            return
        }
        present(notification)
    }

    func dismissActive() {
        guard let notification = activeNotification else { return }
        dismissTask?.cancel()
        dismissTask = nil
        activeNotification = nil
        releaseBanner(of: notification)

        if queuedNotifications.isEmpty {
            isCardHovered = false
            NotificationCardController.shared.hide()
        } else {
            present(queuedNotifications.removeFirst())
        }
    }

    /// Everything goes, and every banner still up comes back.
    func dismissAll() {
        queuedNotifications.removeAll()
        dismissActive()
    }

    /// Only a card that's staying can be hovered. One on its way out reports it too, but it has no exit
    /// to come once it's gone.
    func cardHoverChanged(_ hovering: Bool) {
        isCardHovered = hovering && activeNotification != nil
        if isCardHovered {
            dismissTask?.cancel()
            dismissTask = nil
        } else {
            scheduleDismiss()
        }
    }

    /// Opens the right place through the banner if it's still there, the app itself otherwise. If
    /// nothing opened the card stays, since it may be all that's left of the notification.
    func openActive() {
        guard let notification = activeNotification else { return }
        Task {
            let pressed = await XPCHelperClient.shared.pressNotification(notification.id)
            let opened = if pressed { true } else { await activateApp(of: notification) }
            if opened, activeNotification?.id == notification.id {
                dismissActive()
            }
        }
    }

    private var canShowCards: Bool {
        Defaults[.showNotificationsInNotch] && !FullscreenMediaDetector.shared.hidesClosedNotch && !isScreenLocked
    }

    /// The card doesn't show on the lock screen, and the banner has its own rules for it.
    private var isScreenLocked: Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    private func present(_ notification: SystemNotification) {
        let previous = activeNotification
        guard NotificationCardController.shared.show(notification) else {
            if previous == nil {
                isCardHovered = false
                queuedNotifications.removeAll()
                // The card before it may still be up, and nothing could dismiss it any more
                NotificationCardController.shared.hide()
            }
            return
        }
        activeNotification = notification
        scheduleDismiss()

        if let previous {
            releaseBanner(of: previous)
        }
        Task { await parkBanner(of: notification) }
    }

    private func parkBanner(of notification: SystemNotification) async {
        guard await NotificationCardController.shared.waitUntilOnScreen(notification),
              activeNotification?.id == notification.id, canShowCards
        else { return }

        // The card may have gone while the helper was at it
        let parked = await XPCHelperClient.shared.parkNotification(notification.id)
        if parked, activeNotification?.id != notification.id {
            XPCHelperClient.shared.restoreNotification(notification.id)
        }
    }

    private func releaseBanner(of notification: SystemNotification) {
        XPCHelperClient.shared.restoreNotification(notification.id)
    }

    private func scheduleDismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        guard !isCardHovered, let id = activeNotification?.id else { return }
        dismissTask = Task { [weak self, displayDuration] in
            try? await Task.sleep(for: displayDuration)
            guard !Task.isCancelled, let self, self.activeNotification?.id == id else { return }
            self.dismissActive()
        }
    }

    private func activateApp(of notification: SystemNotification) async -> Bool {
        guard let bundleID = notification.bundleID else { return false }
        let workspace = NSWorkspace.shared
        guard let url = workspace.urlForApplication(withBundleIdentifier: bundleID) else {
            return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.activate() ?? false
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        return (try? await workspace.openApplication(at: url, configuration: configuration)) != nil
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
