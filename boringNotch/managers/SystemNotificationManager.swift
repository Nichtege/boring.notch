//
//  SystemNotificationManager.swift
//  boringNotch
//
//  Shows the notification banners of other apps as cards under the notch, stacked when they come quickly.
//  The helper takes a banner off screen as soon as it finds it, but it only stays away while a card is
//  really up for it, and when in doubt it comes back. What a banner says stays in memory on this Mac.
//

import AppKit
import Combine
import Defaults

struct SystemNotification: Identifiable, Equatable {
    var id = UUID().uuidString
    /// The helper's name for the banner behind this card.
    var token: String
    var appName: String?
    var bundleID: String?
    var title: String?
    var subtitle: String?
    var body: String?
    /// An alert stays until it's answered, with these buttons. A banner's card goes by itself.
    var isAlert = false
    var actions: [String] = []
    var receivedAt = Date()

    func isFromSameSender(as other: SystemNotification) -> Bool {
        appName == other.appName && title == other.title
    }

    /// A title that arrives before the body makes a banner look new to the helper.
    func isLongerReading(of other: SystemNotification) -> Bool {
        title != nil && isFromSameSender(as: other) && isAlert == other.isAlert
            && receivedAt.timeIntervalSince(other.receivedAt) < 1
            && body?.hasPrefix(other.body ?? "") ?? (other.body == nil)
    }
}

@MainActor
final class SystemNotificationManager {
    static let shared = SystemNotificationManager()

    /// The newest card and three behind it. An older banner leaves the stack for the Notification Center,
    /// which has it anyway, and an older alert goes back to where it can still be answered.
    private let stackLimit = 4
    private let displayDuration: Duration = .seconds(8)
    // A check is two trips to the helper. While it's watching it looks after the permission itself and
    // says when it stops, so this is only a safety net.
    private let watchingCheckInterval: Duration = .seconds(30)
    // Waiting for the permission to be given
    private let waitingCheckInterval: Duration = .seconds(3)
    /// Newest first.
    private var notifications: [SystemNotification] = []
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
                    } else {
                        self?.cardsMayShowAgain()
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
        // Its alerts are back on screen, or will be with the next helper
        remove { $0.isAlert }
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

        var notification = SystemNotification(
            token: token,
            appName: nonEmpty(payload["appName"]),
            bundleID: nonEmpty(payload["bundleID"]),
            title: nonEmpty(payload["title"]),
            subtitle: nonEmpty(payload["subtitle"]),
            body: nonEmpty(payload["body"]),
            isAlert: payload["kind"] == "alert",
            actions: (payload["actions"] ?? "").split(separator: "\u{1F}").map(String.init)
        )

        // The card it took the place of, whose banner may still be there too
        var replaced: SystemNotification?
        if let index = notifications.firstIndex(where: {
            $0.token == notification.token || notification.isLongerReading(of: $0)
        }) {
            replaced = notifications[index].token == notification.token ? nil : notifications[index]
            notification.id = notifications[index].id
            notification.receivedAt = notifications[index].receivedAt
            notifications[index] = notification
        } else {
            notifications.insert(notification, at: 0)
            if notifications.count > stackLimit {
                let oldest = notifications.dropFirst().lastIndex { !$0.isAlert } ?? notifications.count - 1
                let pushedOut = notifications.remove(at: oldest)
                if pushedOut.isAlert {
                    releaseBanner(of: pushedOut)
                } else {
                    replaced = pushedOut
                }
            }
        }

        guard NotificationCardController.shared.show(notifications) else {
            // There's no screen for any of them, and nothing could dismiss a card that's still up
            dismissAll()
            return
        }
        scheduleDismiss()

        Task { await parkBanner(notification.token, whileShowing: notification) }
        if let replaced {
            Task { await parkBanner(replaced.token, whileShowing: notification) }
        }
    }

    /// The user dealt with this card. Its banner stays away until it's gone by itself: there's nothing
    /// left to tell, and it would only flash back for a moment. An alert isn't dealt with by that, and
    /// goes back to where it can be answered.
    func dismiss(_ notification: SystemNotification) {
        remove { $0.id == notification.id }
        if notification.isAlert {
            releaseBanner(of: notification)
        }
    }

    /// The alert behind this card is gone, or the helper put it back on screen.
    func alertDidEnd(_ token: String) {
        remove { $0.isAlert && $0.token == token }
    }

    /// Alerts that went back on screen while no card could be shown get one again.
    func cardsMayShowAgain() {
        guard canShowCards else { return }
        XPCHelperClient.shared.reofferNotificationAlerts()
    }

    /// Everything goes, and every banner still up comes back.
    func dismissAll() {
        guard !notifications.isEmpty else { return }
        let dismissed = notifications
        remove { _ in true }
        dismissed.forEach(releaseBanner)
    }

    private func remove(where shouldRemove: (SystemNotification) -> Bool) {
        notifications.removeAll(where: shouldRemove)
        guard notifications.isEmpty else {
            if !NotificationCardController.shared.show(notifications) {
                dismissAll()
            }
            return
        }
        dismissTask?.cancel()
        dismissTask = nil
        isCardHovered = false
        NotificationCardController.shared.hide()
    }

    /// Only a card that's staying can be hovered. One on its way out reports it too, but it has no exit
    /// to come once it's gone.
    func cardHoverChanged(_ hovering: Bool) {
        isCardHovered = hovering && !notifications.isEmpty
        if isCardHovered {
            dismissTask?.cancel()
            dismissTask = nil
        } else {
            scheduleDismiss()
        }
    }

    /// Opens the right place through the banner if it's still there, the app itself otherwise. If
    /// nothing opened the card stays, since it may be all that's left of the notification. What opened
    /// is the whole conversation, so the sender's other banners are done as well. An alert is only done
    /// once it was pressed, and the helper brings it back if that didn't answer it.
    func open(_ notification: SystemNotification) {
        Task {
            let pressed = await XPCHelperClient.shared.pressNotification(notification.token)
            let opened = if pressed { true } else { await activateApp(of: notification) }
            if opened {
                remove { card in
                    card.id == notification.id
                        ? pressed || !card.isAlert
                        : card.isFromSameSender(as: notification) && !card.isAlert
                }
            }
        }
    }

    /// One of an alert's buttons. If it can't be pressed from here, the alert goes back to where it can.
    func answer(_ notification: SystemNotification, with action: String) {
        Task {
            let answered = await XPCHelperClient.shared.performNotificationAction(notification.token, label: action)
            remove { $0.id == notification.id }
            if !answered {
                releaseBanner(of: notification)
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

    /// Waits for the card, which stands in for this banner, and then lets the banner stay away.
    private func parkBanner(_ token: String, whileShowing notification: SystemNotification) async {
        guard await NotificationCardController.shared.waitUntilOnScreen(notification),
              isShown(notification), canShowCards
        else { return }

        // The card may have gone while the helper was at it
        let parked = await XPCHelperClient.shared.parkNotification(token)
        if parked, !isShown(notification) {
            XPCHelperClient.shared.restoreNotification(token)
        }
    }

    private func isShown(_ notification: SystemNotification) -> Bool {
        notifications.contains { $0.id == notification.id }
    }

    private func releaseBanner(of notification: SystemNotification) {
        XPCHelperClient.shared.restoreNotification(notification.token)
    }

    /// The banners go as one, a while after the newest card came. Alerts stay until they're answered.
    private func scheduleDismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        guard !isCardHovered, notifications.contains(where: { !$0.isAlert }) else { return }
        dismissTask = Task { [weak self, displayDuration] in
            try? await Task.sleep(for: displayDuration)
            guard let self, !Task.isCancelled else { return }
            let banners = self.notifications.filter { !$0.isAlert }
            self.remove { !$0.isAlert }
            banners.forEach(self.releaseBanner)
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
