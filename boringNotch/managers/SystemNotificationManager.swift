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

/// A key pressed this recently means someone is typing, and the keyboard mustn't move.
private let typingQuietTime: TimeInterval = 1

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
    /// Can be answered right from the card, by holding it.
    var canReply = false
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
    private let displayDuration: TimeInterval = 8
    /// What's left when the pointer leaves never runs out at once.
    private let minimumRemaining: TimeInterval = 1.5
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
    /// When the banners' cards go, while that clock runs, and how much it had left while it's stopped.
    private var dismissAt: Date?
    private var pausedRemaining: TimeInterval?
    /// The banners last asked to be kept while the pointer is on their cards.
    private var heldTokens: [String] = []
    /// Tried again once the keyboard has been quiet, if the pointer is still on the cards.
    private var heldRetry: Task<Void, Never>?
    private var permissionTask: Task<Void, Never>?
    private var settingCancellable: AnyCancellable?
    private var fullscreenCancellable: AnyCancellable?
    private var helperLostObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?

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

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.screenIsBack() }
        }
    }

    /// After sleep or the lock screen. Notification Center once stopped reporting banners after a night like
    /// that, and they all stayed on the right, so the helper listens anew.
    func screenIsBack() {
        guard Defaults[.showNotificationsInNotch] else { return }
        XPCHelperClient.shared.listenToNotificationsAgain()
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
            actions: (payload["actions"] ?? "").split(separator: "\u{1F}").map(String.init),
            canReply: payload["canReply"] == "1"
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
            // A card being replied from stays in front, where its field is
            let isReplyingInFront = replyingID != nil && notifications.first?.id == replyingID
            notifications.insert(notification, at: isReplyingInFront ? 1 : 0)
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
        syncHeldBanners()

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

    /// The alert behind this card is gone, or the helper put it back on screen. Or the banner that a reply
    /// was being typed for is gone before it was sent.
    func notificationDidEnd(_ token: String) {
        let cards = NotificationCardController.shared
        if let replyingID, let card = notifications.first(where: { $0.id == replyingID }), card.token == token {
            // While sending, the answer to that says how it went
            guard cards.replyState == .editing else { return }
            let kept = keepInClipboard(cards.replyText)
            cards.setReplyState(.failed(kept
                ? String(localized: "This notification is gone. Your text is in the clipboard.")
                : String(localized: "This notification is gone.")))
            return
        }
        remove { $0.isAlert && $0.token == token }
    }

    // MARK: - Replying
    /// The card being replied from.
    private var replyingID: String? { NotificationCardController.shared.replyingID }
    /// The helper unfolding the banner to its field, which takes a moment.
    private var replyReady: Task<Bool, Never>?

    /// Held like on the iPhone: the card opens up to all it says, and gets a field if it can be answered.
    func hold(_ notification: SystemNotification) {
        guard isShown(notification) else { return }
        if notification.canReply {
            startReply(notification)
        } else {
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            NotificationCardController.shared.openFully(notification.id)
        }
    }

    /// The card comes to the front with a field, and the keyboard goes to it.
    func startReply(_ notification: SystemNotification) {
        guard notification.canReply, replyingID == nil,
              let index = notifications.firstIndex(where: { $0.id == notification.id })
        else { return }
        pauseDismiss()
        if index != 0 {
            notifications.insert(notifications.remove(at: index), at: 0)
        }
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        NotificationCardController.shared.startReplying(notification.id, in: notifications)

        let token = notification.token
        let start = Task { await XPCHelperClient.shared.beginNotificationReply(token) }
        replyReady = Task { await start.value == 0 }
        Task {
            let answer = await start.value
            guard replyingID == notification.id, NotificationCardController.shared.replyState == .editing else { return }
            guard answer != 0 else {
                NotificationCardController.shared.replyBecameReady()
                return
            }
            NotificationCardController.shared.setReplyState(.failed(answer == 1
                ? String(localized: "macOS only keeps a message for 5 seconds. Answer in the app.")
                : String(localized: "This can't be answered from here.")))
        }
    }

    /// Sent through the banner's own field. What was typed is never kept, except in the clipboard if it
    /// couldn't be sent, so it isn't lost.
    func sendReply() {
        let cards = NotificationCardController.shared
        let text = cards.replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id = replyingID, cards.replyState == .editing, !text.isEmpty,
              let notification = notifications.first(where: { $0.id == id })
        else { return }
        cards.setReplyState(.sending)

        let ready = replyReady
        Task {
            let isReady = await ready?.value ?? false
            let sent = isReady ? await XPCHelperClient.shared.sendNotificationReply(notification.token, text: text) : false
            guard replyingID == id else { return }
            guard sent else {
                let kept = keepInClipboard(text)
                cards.setReplyState(.failed(kept
                    ? String(localized: "Not sent. Your text is in the clipboard.")
                    : String(localized: "Not sent.")))
                XPCHelperClient.shared.cancelNotificationReply(notification.token)
                return
            }
            cards.setReplyState(.sent)
            try? await Task.sleep(for: .milliseconds(900))
            guard replyingID == id else { return }
            // Answered: the conversation's other banners are done as well
            remove { $0.id == id || $0.isFromSameSender(as: notification) && !$0.isAlert }
            scheduleDismiss(resuming: true)
        }
    }

    /// Esc, or a click elsewhere before anything was typed. The banner folds back, as it was.
    func cancelReply() {
        guard let id = replyingID else { return }
        if let notification = notifications.first(where: { $0.id == id }) {
            XPCHelperClient.shared.cancelNotificationReply(notification.token)
        }
        endReply()
        scheduleDismiss(resuming: true)
    }

    /// After a reply that didn't go: the app, to answer there.
    func openAfterFailedReply() {
        guard let id = replyingID, let notification = notifications.first(where: { $0.id == id }) else { return }
        cancelReply()
        Task {
            if await activateApp(of: notification) {
                remove { $0.id == id }
            }
        }
    }

    private func endReply() {
        replyReady = nil
        NotificationCardController.shared.stopReplying()
    }

    private func keepInClipboard(_ text: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(text, forType: .string)
    }

    /// Alerts that went back on screen while no card could be shown get one again.
    func cardsMayShowAgain() {
        guard canShowCards else { return }
        XPCHelperClient.shared.reofferNotificationAlerts()
    }

    /// Everything goes, and every banner still up comes back.
    func dismissAll() {
        guard !notifications.isEmpty else { return }
        cancelReply()
        let dismissed = notifications
        remove { _ in true }
        dismissed.forEach(releaseBanner)
    }

    private func remove(where shouldRemove: (SystemNotification) -> Bool) {
        let replying = replyingID.flatMap { id in notifications.first { $0.id == id } }
        notifications.removeAll(where: shouldRemove)
        // An unfolded banner wouldn't go by itself, and would stay out of sight with nothing for it
        if let replying, !notifications.contains(where: { $0.id == replying.id }) {
            XPCHelperClient.shared.cancelNotificationReply(replying.token)
            endReply()
        }
        guard notifications.isEmpty else {
            if !NotificationCardController.shared.show(notifications) {
                dismissAll()
            }
            syncHeldBanners()
            return
        }
        dismissTask?.cancel()
        dismissTask = nil
        dismissAt = nil
        pausedRemaining = nil
        isCardHovered = false
        syncHeldBanners()
        NotificationCardController.shared.hide()
    }

    /// Only a card that's staying can be hovered. One on its way out reports it too, but it has no exit
    /// to come once it's gone.
    func cardHoverChanged(_ hovering: Bool) {
        isCardHovered = hovering && !notifications.isEmpty
        if isCardHovered {
            pauseDismiss()
        } else {
            NotificationCardController.shared.closeOpened()
            scheduleDismiss(resuming: true)
        }
        syncHeldBanners()
    }

    /// The pointer on the cards keeps their banners too, which would otherwise go after 5 s, and with
    /// them the way to the conversation and the reply. A message's banner is kept by unfolding it to its
    /// field, which takes the keyboard for a moment until it's given back. So not while typing, when a key
    /// could land in that field, nor during a reply, whose field has the keyboard.
    private func syncHeldBanners() {
        heldRetry?.cancel()
        heldRetry = nil
        let typedJustNow = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown) < typingQuietTime
        let mayTakeKeyboard = !typedJustNow && replyingID == nil
        let tokens = isCardHovered
            ? notifications.filter { !$0.isAlert && $0.id != replyingID && (mayTakeKeyboard || !$0.canReply) }.map(\.token)
            : []
        if isCardHovered, typedJustNow, notifications.contains(where: { $0.canReply && !$0.isAlert }) {
            heldRetry = Task { [weak self] in
                try? await Task.sleep(for: .seconds(typingQuietTime))
                guard !Task.isCancelled else { return }
                self?.syncHeldBanners()
            }
        }
        guard tokens != heldTokens else { return }
        heldTokens = tokens
        Task {
            guard await XPCHelperClient.shared.holdNotifications(tokens) else { return }
            // A reply that started meanwhile has taken the keyboard for its own field
            guard replyingID == nil else { return }
            NotificationCardController.giveKeyboardBack()
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

    /// The banners go as one, a while after the newest card came. The pointer on the cards, or a reply
    /// being typed, stops that clock, and it goes on from where it stood. Alerts stay until they're answered.
    private func scheduleDismiss(resuming: Bool = false) {
        let remaining = resuming ? pausedRemaining ?? displayDuration : displayDuration
        dismissTask?.cancel()
        dismissTask = nil
        dismissAt = nil
        guard notifications.contains(where: { !$0.isAlert }) else {
            pausedRemaining = nil
            return
        }
        guard !isCardHovered, replyingID == nil else {
            pausedRemaining = remaining
            return
        }
        pausedRemaining = nil
        dismissAt = Date().addingTimeInterval(remaining)
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(remaining))
            guard let self, !Task.isCancelled else { return }
            // Their whole time was shown. A banner kept under the pointer has a few seconds left when it
            // goes, and stays out of sight for them: back on screen it would only flash on the right.
            self.remove { !$0.isAlert }
        }
    }

    private func pauseDismiss() {
        if let dismissAt {
            pausedRemaining = max(minimumRemaining, dismissAt.timeIntervalSinceNow)
        }
        dismissTask?.cancel()
        dismissTask = nil
        dismissAt = nil
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
