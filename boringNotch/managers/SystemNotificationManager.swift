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
    /// Previews have no banner behind them.
    var hasBanner = false
}

@MainActor
final class SystemNotificationManager {
    static let shared = SystemNotificationManager()

    private let queueLimit = 5
    private let displayDuration: Duration = .seconds(8)
    private let permissionCheckInterval: Duration = .seconds(3)
    private var activeNotification: SystemNotification?
    private var queuedNotifications: [SystemNotification] = []
    private var isCardHovered = false
    private var didAskForPermission = false
    private var wasAuthorized = false
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
        permissionTask?.cancel()
        permissionTask = nil
        guard enabled else {
            XPCHelperClient.shared.stopNotificationWatching()
            dismissAll()
            return
        }

        permissionTask = Task { [weak self, permissionCheckInterval] in
            while !Task.isCancelled {
                await self?.syncWatching()
                try? await Task.sleep(for: permissionCheckInterval)
            }
        }
    }

    /// Runs all the time the feature is on, since the permission can come and go. Starting is harmless
    /// when the helper is already watching, and heals anything that made it stop.
    private func syncWatching() async {
        guard Defaults[.showNotificationsInNotch] else { return }

        var authorized = await XPCHelperClient.shared.isAccessibilityAuthorized()
        if !authorized, !didAskForPermission {
            didAskForPermission = true
            authorized = await XPCHelperClient.shared.ensureAccessibilityAuthorization(promptIfNeeded: true)
        }
        guard Defaults[.showNotificationsInNotch] else { return }

        if authorized {
            _ = await XPCHelperClient.shared.startNotificationWatching()
            // Turned off while the helper was on its way
            if !Defaults[.showNotificationsInNotch] {
                XPCHelperClient.shared.stopNotificationWatching()
            }
        } else if wasAuthorized {
            // The helper has put back what it could by now
            dismissAll()
        }
        wasAuthorized = authorized
    }

    /// The helper is gone and with it whatever it had parked: a new one looks for such windows when
    /// it starts. The short pause keeps a helper that keeps crashing from relaunching in a tight loop.
    private func helperLost() async {
        try? await Task.sleep(for: .seconds(1))
        XPCHelperClient.shared.restoreStrandedNotifications()
        await syncWatching()
    }

    // MARK: - Cards
    func bannerDidAppear(_ payload: [String: String]) {
        guard let token = payload["token"], !token.isEmpty, canShowCards else { return }

        let notification = SystemNotification(
            id: token,
            appName: nonEmpty(payload["appName"]),
            bundleID: nonEmpty(payload["bundleID"]),
            title: nonEmpty(payload["title"]),
            subtitle: nonEmpty(payload["subtitle"]),
            body: nonEmpty(payload["body"]),
            hasBanner: true
        )

        guard activeNotification == nil || !isCardHovered else {
            // Its banner stays up until its card comes, so nothing is lost if this one gets dropped
            queuedNotifications.append(notification)
            if queuedNotifications.count > queueLimit {
                queuedNotifications.removeFirst()
            }
            return
        }
        present(notification)
    }

    /// Shows a card from given data, with no banner behind it. For trying out how the card looks.
    func show(preview: SystemNotification) {
        var notification = preview
        notification.hasBanner = false
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

    /// Opens the right place through the banner if it's still there, the app itself otherwise.
    func openActive() {
        guard let notification = activeNotification else { return }
        Task {
            let pressed = notification.hasBanner ? await XPCHelperClient.shared.pressNotification(notification.id) : false
            if !pressed {
                activateApp(of: notification)
            }
            if activeNotification?.id == notification.id {
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
            }
            return
        }
        activeNotification = notification
        scheduleDismiss()

        if let previous {
            releaseBanner(of: previous)
        }
        if notification.hasBanner {
            Task { await parkBanner(of: notification) }
        }
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
        if notification.hasBanner {
            XPCHelperClient.shared.restoreNotification(notification.id)
        }
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

    private func activateApp(of notification: SystemNotification) {
        guard let bundleID = notification.bundleID else { return }
        let workspace = NSWorkspace.shared
        if let url = workspace.urlForApplication(withBundleIdentifier: bundleID) {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.addsToRecentItems = false
            workspace.openApplication(at: url, configuration: configuration)
        } else {
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.activate()
        }
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
