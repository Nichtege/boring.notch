//
//  NotificationWatcher.swift
//  BoringNotchXPCHelper
//
//  Reads the banners Notification Center shows. A banner's window leaves the screen as soon as it's found
//  and comes back unless the app says in time that its card is up. Every way out of here puts the window
//  back, as far as Accessibility still allows that. What a banner says stays in memory: tokens are made up
//  here, so they hold none of it, and nothing logs it.
//

import AppKit
import ApplicationServices
import CoreServices
import Foundation

private let notificationCenterPath = "/System/Library/CoreServices/NotificationCenter.app/Contents/MacOS/NotificationCenter"
private let orderedChildrenAttribute = "AXOrderedChildren"
private let stackingIdentifierAttribute = "AXStackingIdentifier"
private let maxAccessibilityNodes = 1_024
private let maxTextNodes = 256
private let structuralIdentifiers: Set<String> = [
    "AXNotificationListItems",
    "widgets-overlay-view"
]
private let settleDelay: TimeInterval = 0.15
/// Children of windows that aren't watched for banners report events too, and a scan isn't cheap.
private let minScanInterval: TimeInterval = 0.25
/// But a new banner is on screen until a scan finds it. So after a new window or a quiet moment the first
/// scan runs at once, and the next ones follow closely for this long.
private let fastScanInterval: TimeInterval = 0.05
private let fastScanTime: TimeInterval = 1
private let healthCheckInterval: TimeInterval = 5
private let parkingPosition = CGPoint(x: -10000, y: -10000)
/// Notification Center slides a banner out before it orders the window out, and the window can only
/// be moved until then (about half a second). Moving it back at once would show the end of that slide.
private let restoreDelay: TimeInterval = 0.35
/// How long a banner stays out of sight without the app saying that its card is up.
private let cardConfirmationTime: TimeInterval = 1.5
/// How long a banner that became a stack has to show what's new. Its text can come a moment after its role.
private let stackTextDelay: TimeInterval = 0.5
/// How long an alert stays where it is before a card's banner may take it along out of sight. All of them
/// share one window on macOS 27, so an alert left standing would otherwise keep every banner on screen.
private let alertSettleTime: TimeInterval = 3
/// An answered alert leaves at once. One that's still there after this wanted more than a press.
private let answerCheckDelay: TimeInterval = 1
/// Every banner and alert has this button, and it only unfolds the notification where it is. A card
/// already shows what it says.
private let unfoldingActions: Set<String> = ["Details einblenden", "Details ausblenden", "Show Details", "Hide Details"]
/// A message banner's way to its reply field, the field's own button, and the way back. Compared without
/// case, dots and spaces. "Mehr anzeigen" is what Messages offers on 27.2: it unfolds a text area and "Senden".
private let replyOpeners: Set<String> = ["mehranzeigen", "showmore", "antworten", "antwort", "antwortgeben", "reply"]
private let replySenders: Set<String> = ["senden", "send"]
private let replyClosers: Set<String> = ["detailsausblenden", "hidedetails", "wenigeranzeigen", "showless"]
/// How long the reply field has to appear, and how long a sent reply has to leave the field.
private let replyWaitTime: TimeInterval = 1.5
private let replyPollInterval: TimeInterval = 0.1

private func plainLabel(_ label: String) -> String {
    label.lowercased().filter { !". …".contains($0) }
}

/// Notification Center's answer to a press can be a failure although the press went through, as with
/// "Mehr anzeigen". Only these mean that nothing happened.
private func pressDidNothing(_ result: AXError) -> Bool {
    [.invalidUIElement, .actionUnsupported, .illegalArgument, .apiDisabled, .notImplemented].contains(result)
}
/// A closing center has given up focus, but its old notifications are still there for a moment.
private let centerClosingDelay: TimeInterval = 1
/// For when no later scan will try again. Anywhere else one try will do, since waiting between tries
/// would hold up the main queue.
private let restoreAttempts = 3
private let maxRestoreRetries = 15
private let reattachAttempts = 30
/// How long an app name that can't be found isn't searched for again. The search reads every installed app.
private let bundleIDMissLifetime: TimeInterval = 60

private func isParked(_ position: CGPoint) -> Bool {
    abs(position.x - parkingPosition.x) < 1 && abs(position.y - parkingPosition.y) < 1
}

private func executablePath(of processIdentifier: pid_t) -> String? {
    var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
    guard proc_pidpath(processIdentifier, &path, UInt32(path.count)) > 0 else { return nil }
    return String(cString: path)
}

/// Asks the kernel. `NSRunningApplication` only updates on a turn of the main run loop, and this service
/// doesn't turn one: its Info.plist sets no RunLoopType, so the main thread sits in dispatch_main. A
/// Notification Center that has exited could look alive there for good, and its successor never appear.
private func notificationCenterProcess() -> pid_t? {
    let size = MemoryLayout<pid_t>.size
    let needed = proc_listpids(UInt32(PROC_UID_ONLY), getuid(), nil, 0)
    guard needed > 0 else { return nil }

    var processes = [pid_t](repeating: 0, count: Int(needed) / size + 16)
    let listed = proc_listpids(UInt32(PROC_UID_ONLY), getuid(), &processes, Int32(processes.count * size))
    guard listed > 0 else { return nil }
    return processes.prefix(Int(listed) / size).first { $0 > 0 && executablePath(of: $0) == notificationCenterPath }
}

private extension AXUIElement {
    subscript(attribute: String) -> Any? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    func string(_ attribute: String) -> String? {
        self[attribute] as? String
    }

    func children() -> [AXUIElement] {
        (self[kAXChildrenAttribute] as? [AXUIElement] ?? [])
            + (self[orderedChildrenAttribute] as? [AXUIElement] ?? [])
    }

    /// Nil when Notification Center couldn't be asked, which isn't the same as having no windows.
    func windows() -> [AXUIElement]? {
        var value: CFTypeRef?
        switch AXUIElementCopyAttributeValue(self, kAXWindowsAttribute as CFString, &value) {
        case .success:
            return value as? [AXUIElement] ?? []
        case .noValue, .attributeUnsupported:
            return []
        default:
            return nil
        }
    }

    func position() -> CGPoint? {
        guard let value = self[kAXPositionAttribute],
              CFGetTypeID(value as CFTypeRef) == AXValueGetTypeID(),
              AXValueGetType(value as! AXValue) == .cgPoint
        else { return nil }
        var point = CGPoint.zero
        AXValueGetValue(value as! AXValue, .cgPoint, &point)
        return point
    }

    func size() -> CGSize? {
        guard let value = self[kAXSizeAttribute],
              CFGetTypeID(value as CFTypeRef) == AXValueGetTypeID(),
              AXValueGetType(value as! AXValue) == .cgSize
        else { return nil }
        var size = CGSize.zero
        AXValueGetValue(value as! AXValue, .cgSize, &size)
        return size
    }

    func move(to point: CGPoint) -> AXError {
        var point = point
        guard let value = AXValueCreate(.cgPoint, &point) else { return .failure }
        return AXUIElementSetAttributeValue(self, kAXPositionAttribute as CFString, value)
    }
}

/// What AX callbacks get as their refcon, without a retain. `AXObserverRunLoop` keeps it alive.
private final class ObserverContext: @unchecked Sendable {
    weak var watcher: NotificationWatcher?
}

struct CapturedNotification {
    let token: String
    let appName: String?
    let bundleID: String?
    let title: String?
    let subtitle: String?
    let body: String?
    /// Stays until it's answered, with these buttons.
    let isAlert: Bool
    let actions: [String]
    /// Has a field for a reply.
    let canReply: Bool
}

final class NotificationWatcher {
    private struct Banner {
        let element: AXUIElement
        let subrole: String?
    }

    private struct BannerText: Hashable {
        var title: String?
        var subtitle: String?
        var body: String?

        var isEmpty: Bool {
            title == nil && subtitle == nil && body == nil
        }
    }

    private struct LiveBanner {
        let token: String
        var element: AXUIElement
        var window: AXUIElement
        var hasCard = false
        /// Just found, and the app still has time to say that its card is up. Messages come quicker than
        /// that, and a neighbour's card on its way is no reason to bring the window back.
        var awaitsCard = false
        var isStack: Bool
        let isAlert: Bool
        let foundAt = Date()
        /// Its own name, which stays when its text changes as it unfolds for a reply.
        let axIdentifier: String?
        var isReplying = false
    }

    private struct ParkedWindow {
        let window: AXUIElement
        let origin: CGPoint
        var tokens: Set<String>
    }

    var onBanner: ((CapturedNotification) -> Void)?
    /// An alert's card, or a card being replied from, has nothing left to stand in for: the alert or banner
    /// is gone, or back on screen. Any other banner's card goes by itself.
    var onEnded: ((String) -> Void)?
    /// The permission is gone and the watcher stopped by itself.
    var onStopped: (() -> Void)?

    private var appElement: AXUIElement?
    private var processIdentifier: pid_t?
    private var axObserver: AXObserver?
    private var observerRunLoop: AXObserverRunLoop?
    private var observerContext: ObserverContext?
    private var scanWorkItem: DispatchWorkItem?
    private var lastScan = Date.distantPast
    private var fastScansUntil = Date.distantPast
    private var settleWorkItem: DispatchWorkItem?
    private var observedWindows: [CFHashCode: AXUIElement] = [:]
    private var liveBanners: [Int: LiveBanner] = [:]
    private var parkedWindows: [Int: ParkedWindow] = [:]
    private var lastOrigin: CGPoint?
    private var restoreRetries = 0
    private var centerWasOpen = false
    private var centerClosedAt: Date?
    /// Finding an app can take long, and the main queue has windows to put back. Both caches are only
    /// used on this queue.
    private let bundleIDQueue = DispatchQueue(label: "com.nichtege.boringnotch.bundleID", qos: .userInitiated)
    private var bundleIDCache: [String: String] = [:]
    private var bundleIDMisses: [String: Date] = [:]
    /// The AX observer is bound to one Notification Center process. When it exits (crash, killall,
    /// an OS update) the observer goes silent, so the exit is watched and the watcher attaches to the
    /// relaunched instance.
    private var exitSource: DispatchSourceProcess?
    private var reattachWorkItem: DispatchWorkItem?
    private var healthTimer: DispatchSourceTimer?

    var isRunning: Bool { appElement != nil }

    init() {
        // A busy Notification Center shouldn't hold up putting a window back
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.5)
    }

    @discardableResult
    func start() -> Bool {
        guard AXIsProcessTrusted(), !isRunning, let processIdentifier = notificationCenterProcess() else {
            return false
        }

        appElement = AXUIElementCreateApplication(processIdentifier)
        guard installObserver(for: processIdentifier) else {
            appElement = nil
            return false
        }

        self.processIdentifier = processIdentifier
        watchForExit(of: processIdentifier)
        watchHealth()
        scan()
        return true
    }

    func stop() {
        reattachWorkItem?.cancel()
        reattachWorkItem = nil
        exitSource?.cancel()
        exitSource = nil
        detach()
    }

    private func watchForExit(of processIdentifier: pid_t) {
        exitSource?.cancel()
        let source = DispatchSource.makeProcessSource(
            identifier: processIdentifier, eventMask: .exit, queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.notificationCenterExited()
        }
        exitSource = source
        source.resume()
    }

    private func notificationCenterExited() {
        exitSource?.cancel()
        exitSource = nil
        detach()
        reattach(remainingAttempts: reattachAttempts)
    }

    /// launchd relaunches Notification Center within a moment; retry once a second until the new
    /// instance accepts the observer.
    private func reattach(remainingAttempts: Int) {
        reattachWorkItem = nil
        // The app's own check may have been faster
        if isRunning || start() { return }
        guard remainingAttempts > 1 else {
            NSLog("[boringNotch] Notification Center did not come back, banners are no longer watched")
            return
        }
        let workItem = DispatchWorkItem { [weak self] in
            self?.reattach(remainingAttempts: remainingAttempts - 1)
        }
        reattachWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: workItem)
    }

    private func detach() {
        // First of all, so nothing further down can get in the way of it
        restoreAllWindows(attempts: restoreAttempts)
        settleWorkItem?.cancel()
        settleWorkItem = nil
        healthTimer?.cancel()
        healthTimer = nil
        if let observer = axObserver {
            if let appElement {
                removeObserverNotifications(from: appElement, observer: observer)
            }
            for window in observedWindows.values {
                removeObserverNotifications(from: window, observer: observer)
            }
        }
        observedWindows.removeAll()
        observerRunLoop?.stop()
        axObserver = nil
        observerRunLoop = nil
        observerContext = nil
        scanWorkItem?.cancel()
        scanWorkItem = nil
        restoreRetries = 0
        // Back on screen with everything else, or found again by a new start with a card of its own
        for banner in liveBanners.values where banner.isAlert || banner.isReplying {
            ended(token: banner.token)
        }
        liveBanners.removeAll()
        appElement = nil
        processIdentifier = nil
    }

    private func addObserverNotifications(to element: AXUIElement) -> Bool {
        guard let observer = axObserver, let context = observerContext else { return false }
        let refcon = Unmanaged.passUnretained(context).toOpaque()
        var registered = false
        for notification in NotificationObservationPolicy.structuralNotifications {
            let result = AXObserverAddNotification(
                observer,
                element,
                notification as CFString,
                refcon
            )
            if result == .success {
                registered = true
            }
        }
        return registered
    }

    private func removeObserverNotifications(from element: AXUIElement, observer: AXObserver) {
        for notification in NotificationObservationPolicy.structuralNotifications {
            AXObserverRemoveNotification(observer, element, notification as CFString)
        }
    }

    private func refreshObservedWindows(_ windows: [AXUIElement]) {
        var current = Set<CFHashCode>()
        for window in windows {
            let subrole = window.string(kAXSubroleAttribute)
            let identifier = window.string(kAXIdentifierAttribute)
            guard NotificationObservationPolicy.shouldObserveElement(
                subrole: subrole,
                identifier: identifier
            ) else { continue }

            let key = CFHash(window)
            current.insert(key)
            guard observedWindows[key] == nil else { continue }
            _ = addObserverNotifications(to: window)
            observedWindows[key] = window
        }

        let stale = observedWindows.keys.filter { !current.contains($0) }
        for key in stale {
            if let window = observedWindows.removeValue(forKey: key) {
                if let observer = axObserver {
                    removeObserverNotifications(from: window, observer: observer)
                }
            }
        }
    }

    private func installObserver(for processIdentifier: pid_t) -> Bool {
        var observer: AXObserver?
        let result = AXObserverCreate(processIdentifier, { _, element, notification, refcon in
            guard let refcon else { return }
            let context = Unmanaged<ObserverContext>.fromOpaque(refcon).takeUnretainedValue()
            let name = notification as String
            let subrole = name == "AXUIElementDestroyed"
                ? nil
                : element.string(kAXSubroleAttribute)
            let identifier = name == "AXUIElementDestroyed"
                ? nil
                : element.string(kAXIdentifierAttribute)
            DispatchQueue.main.async { [weak context] in
                context?.watcher?.handleObserverEvent(
                    notification: name,
                    subrole: subrole,
                    identifier: identifier
                )
            }
        }, &observer)
        guard result == .success, let observer, let appElement else { return false }

        let context = ObserverContext()
        context.watcher = self
        observerContext = context
        axObserver = observer
        guard addObserverNotifications(to: appElement) else {
            axObserver = nil
            observerContext = nil
            return false
        }

        let runLoop = AXObserverRunLoop(observer: observer, context: context)
        runLoop.start()
        observerRunLoop = runLoop
        return true
    }

    private func handleObserverEvent(
        notification: String,
        subrole: String?,
        identifier: String?
    ) {
        guard NotificationObservationPolicy.shouldScan(
            notification: notification,
            subrole: subrole,
            identifier: identifier
        ) else { return }

        let isQuiet = scanWorkItem == nil && Date().timeIntervalSince(lastScan) >= minScanInterval
        if notification == "AXWindowCreated" || isQuiet {
            fastScansUntil = Date().addingTimeInterval(fastScanTime)
            // A scan already waiting for its turn at the slow pace mustn't hold this one up
            scanWorkItem?.cancel()
            scanWorkItem = nil
        }
        scheduleScan()
        scheduleSettleScan()
    }

    private func scheduleSettleScan() {
        guard settleWorkItem == nil else { return }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.settleWorkItem = nil
            self.scheduleScan()
        }
        settleWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay, execute: workItem)
    }

    private func scheduleScan() {
        guard scanWorkItem == nil else { return }
        let interval = Date() < fastScansUntil ? fastScanInterval : minScanInterval
        let wait = max(0, interval - Date().timeIntervalSince(lastScan))
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.scanWorkItem = nil
            self.scan()
        }
        scanWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: workItem)
    }

    private func scan() {
        defer { lastScan = Date() }
        autoreleasepool {
            guard let appElement else { return }
            guard let windows = appElement.windows() else {
                // A failed restore mostly means a busy Notification Center, which this may well be
                if restoreRetries > 0 {
                    retryRestoreLater()
                }
                return
            }
            refreshObservedWindows(windows)
            restoreStrandedWindows(windows)

            // On macOS 27 the open center lays itself out in the window banners use. Nothing it
            // shows may stay off screen, and none of it is news.
            guard !centerMayBeOpen(appElement) else {
                centerWasOpen = true
                restoreAllWindows()
                return
            }
            // An open center can sit there without a single event, so its closing starts with this scan
            if centerWasOpen {
                centerWasOpen = false
                centerClosedAt = Date()
                // Nothing may happen after that to ask for the scan that sends the cards' banners away again
                DispatchQueue.main.asyncAfter(deadline: .now() + centerClosingDelay + fastScanInterval) { [weak self] in
                    self?.scheduleScan()
                }
            }
            let centerIsClosing = centerClosedAt.map { Date().timeIntervalSince($0) < centerClosingDelay } ?? false

            var seen = Set<Int>()
            for window in windows {
                guard case .banners(let banners) = inspect(window) else {
                    restoreWindow(forKey: key(for: window))
                    continue
                }

                let readings = banners.map { banner -> (banner: Banner, text: BannerText, identity: Int) in
                    let text = readText(in: banner.element)
                    return (banner, text, identity(of: banner.element, showing: text))
                }
                seen.formUnion(readings.map { $0.identity })

                // A new stack of alerts has to be seen where it is, and everything in the window goes with it
                if readings.contains(where: {
                    !NotificationPanelDetection.isMirrorable(subrole: $0.banner.subrole) && !isSettledAlert($0.identity)
                }) {
                    restoreWindow(forKey: key(for: window))
                }

                var fresh: [(banner: Banner, text: BannerText, identity: Int)] = []
                for reading in readings {
                    let isStack = reading.banner.subrole == NotificationPanelDetection.stackSubrole
                    if let live = liveBanners[reading.identity] {
                        liveBanners[reading.identity]?.element = reading.banner.element
                        liveBanners[reading.identity]?.window = window
                        if isStack, !live.isStack {
                            liveBanners[reading.identity]?.isStack = true
                            expectNewText(identity: reading.identity, token: live.token)
                        }
                    } else {
                        liveBanners[reading.identity] = LiveBanner(
                            token: UUID().uuidString,
                            element: reading.banner.element,
                            window: window,
                            isStack: isStack,
                            isAlert: reading.banner.subrole == NotificationPanelDetection.alertSubrole,
                            axIdentifier: reading.banner.element.string(kAXIdentifierAttribute)
                        )
                        fresh.append(reading)
                    }
                }
                guard !fresh.isEmpty else { continue }
                guard !centerIsClosing else {
                    restoreWindow(forKey: key(for: window))
                    continue
                }

                // All of them first, or the first to park would see the others as banners without a card
                for reading in fresh where NotificationPanelDetection.isMirrorable(subrole: reading.banner.subrole) {
                    liveBanners[reading.identity]?.awaitsCard = true
                }
                for reading in fresh {
                    guard NotificationPanelDetection.isMirrorable(subrole: reading.banner.subrole),
                          let token = liveBanners[reading.identity]?.token
                    else {
                        restoreWindow(forKey: key(for: window))
                        continue
                    }

                    // Out of sight before anything else, or the banner shows next to the card on its way
                    if !parkBeforeCard(window, banners: banners, identity: reading.identity, token: token) {
                        restoreWindow(forKey: key(for: window))
                    }
                    // Its text may only come a moment later, as a banner of its own to the next scan
                    if !reading.text.isEmpty {
                        report(reading.banner.element, text: reading.text, token: token)
                    }
                }
            }

            for identity in Array(liveBanners.keys) where !seen.contains(identity) {
                if let banner = liveBanners.removeValue(forKey: identity) {
                    releaseAfterSlideOut(token: banner.token)
                    if banner.isAlert || banner.isReplying {
                        ended(token: banner.token)
                    }
                }
            }

            if !centerIsClosing {
                parkAgainUnderCards()
            }
        }
    }

    /// The open center brings back everything. What still has a card up goes away again once it's closed,
    /// which matters for an alert: it would stay on screen next to its card until answered. The window
    /// stays away for every card in it, as it would have before.
    private func parkAgainUnderCards() {
        for (identity, live) in liveBanners where live.hasCard {
            let windowKey = key(for: live.window)
            if parkedWindows[windowKey] != nil {
                parkedWindows[windowKey]?.tokens.insert(live.token)
                continue
            }
            guard case .banners(let banners) = inspect(live.window), canPark(banners, for: identity) else { continue }
            _ = moveAway(live.window, token: live.token)
        }
    }

    private enum WindowContents {
        /// The center's panel, widgets, or more than can be looked through: not a surface for banners.
        case other
        case banners([Banner])
    }

    private func inspect(_ root: AXUIElement) -> WindowContents {
        var pending: [(element: AXUIElement, insideBanner: Bool, insideList: Bool)] = [
            (root, false, false)
        ]
        var visited = Set<CFHashCode>()
        var banners: [Banner] = []

        while let node = pending.popLast() {
            let element = node.element
            guard visited.insert(CFHash(element)).inserted else { continue }
            guard visited.count <= maxAccessibilityNodes else { return .other }

            let subrole = element.string(kAXSubroleAttribute)
            let identifier = element.string(kAXIdentifierAttribute)
            let stackingIdentifier = node.insideList && subrole == "AXButton"
                ? element.string(stackingIdentifierAttribute)
                : nil
            if NotificationPanelDetection.isPanel(
                subrole: subrole,
                identifier: identifier,
                stackingIdentifier: stackingIdentifier,
                insideNotificationList: node.insideList && !node.insideBanner
            ) || NotificationPanelDetection.isDesktopWidget(identifier: identifier) {
                return .other
            }

            if !node.insideBanner, NotificationPanelDetection.isBanner(subrole: subrole) {
                banners.append(Banner(element: element, subrole: subrole))
            }

            let childInsideBanner = node.insideBanner || NotificationPanelDetection.isBanner(subrole: subrole)
            let childInsideList = node.insideList
                || identifier == NotificationPanelDetection.panelListIdentifier
            pending.append(contentsOf: element.children().reversed().map {
                ($0, childInsideBanner, childInsideList)
            })
        }

        return .banners(banners)
    }

    /// A banner keeps its identifier and text across scans, while its element may not. A second
    /// notification can reuse the identifier, and it mustn't pass for the first in a parked window.
    private func identity(of banner: AXUIElement, showing text: BannerText) -> Int {
        // Unfolded for a reply it may show more of its text, and it's still the same banner
        if let identifier = banner.string(kAXIdentifierAttribute),
           let replying = liveBanners.first(where: { $0.value.isReplying && $0.value.axIdentifier == identifier }) {
            return replying.key
        }
        var hasher = Hasher()
        if let identifier = banner.string(kAXIdentifierAttribute), !structuralIdentifiers.contains(identifier) {
            hasher.combine(identifier)
        }
        hasher.combine(text)
        return hasher.finalize()
    }

    private func key(for window: AXUIElement) -> Int {
        Int(bitPattern: CFHash(window))
    }

    /// Only an answer of no focused window means closed. Anything else can't rule out the open center.
    private func centerMayBeOpen(_ appElement: AXUIElement) -> Bool {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &value) != .noValue
    }

    // MARK: - Parking

    /// A new banner leaves as soon as it's found. Nothing depends on the app for that: unless the app
    /// says in time that the card is up, the banner comes back by itself.
    private func parkBeforeCard(_ window: AXUIElement, banners: [Banner], identity: Int, token: String) -> Bool {
        restoreUnlessCardInTime(token: token)
        return canPark(banners, for: identity) && moveAway(window, token: token)
    }

    private func restoreUnlessCardInTime(token: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + cardConfirmationTime) { [weak self] in
            guard let self else { return }
            if let identity = self.liveBanners.first(where: { $0.value.token == token })?.key {
                self.liveBanners[identity]?.awaitsCard = false
                if self.liveBanners[identity]?.hasCard == true { return }
            }
            self.restore(token: token)
        }
    }

    /// Alerts that came back on screen without a card, as on the lock screen or in full screen, are offered
    /// to the app again. They stay where they are until a card is up for them.
    func reofferAlerts() {
        guard AXIsProcessTrusted(), let appElement, !centerMayBeOpen(appElement) else { return }
        for (identity, banner) in liveBanners where banner.isAlert && !banner.hasCard && !banner.awaitsCard {
            liveBanners[identity]?.awaitsCard = true
            restoreUnlessCardInTime(token: banner.token)
            report(banner.element, text: readText(in: banner.element), token: banner.token)
        }
    }

    /// Something new came, or it wouldn't be a stack now. New text makes a new identity and a new card. If
    /// it still says the same after a moment, no card can show what's new, so the stack itself has to.
    private func expectNewText(identity: Int, token: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + stackTextDelay) { [weak self] in
            guard let self, self.liveBanners[identity]?.token == token else { return }
            self.restore(token: token)
        }
    }

    /// Called by the app once the card for this banner is really on screen. Everything is looked at
    /// again here, since the banner was read a moment ago: anything unclear brings it back.
    func park(token: String) -> Bool {
        guard AXIsProcessTrusted(), let appElement,
              !centerMayBeOpen(appElement),
              let identity = liveBanners.first(where: { $0.value.token == token })?.key
        else {
            restore(token: token)
            return false
        }
        liveBanners[identity]?.hasCard = true

        guard let window = liveBanners[identity]?.window,
              case .banners(let banners) = inspect(window),
              canPark(banners, for: identity),
              moveAway(window, token: token)
        else {
            restore(token: token)
            return false
        }
        return true
    }

    private func moveAway(_ window: AXUIElement, token: String) -> Bool {
        guard let position = window.position() else { return false }

        let windowKey = key(for: window)
        let origin = isParked(position)
            ? parkedWindows[windowKey]?.origin ?? lastOrigin ?? restingOrigin(of: window)
            : position

        if !isParked(position) {
            guard window.move(to: parkingPosition) == .success,
                  window.position().map(isParked) == true
            else {
                _ = window.move(to: origin)
                // That can fail too, and then only a later scan finds it
                retryRestoreLater()
                return false
            }
        }

        let tokens = (parkedWindows[windowKey]?.tokens ?? []).union([token])
        parkedWindows[windowKey] = ParkedWindow(window: window, origin: origin, tokens: tokens)
        lastOrigin = origin
        return true
    }

    /// Everything in the window has to be this banner, one whose card is up or coming, or an alert that has
    /// been on screen a while. A repeat next to the original says the same, so the same card stands in for both.
    private func canPark(_ banners: [Banner], for identity: Int) -> Bool {
        var containsBanner = false
        for banner in banners {
            let other = self.identity(of: banner.element, showing: readText(in: banner.element))
            let isMirrorable = NotificationPanelDetection.isMirrorable(subrole: banner.subrole)
            if isMirrorable, other == identity {
                containsBanner = true
            } else if isMirrorable, liveBanners[other]?.hasCard == true || liveBanners[other]?.awaitsCard == true {
                continue
            } else if NotificationPanelDetection.waitsForAnswer(subrole: banner.subrole), isSettledAlert(other) {
                continue
            } else {
                return false
            }
        }
        return containsBanner
    }

    /// An alert without a card waits for an answer, so it can't stand in a card's way for good. Once it has
    /// been seen it may leave with a card's banner, and it's back as soon as that banner is: when the card
    /// goes or the banner would have. A new stack of alerts brings the window back at once.
    private func isSettledAlert(_ identity: Int) -> Bool {
        guard let live = liveBanners[identity] else { return false }
        return Date().timeIntervalSince(live.foundAt) >= alertSettleTime
    }

    /// The card for this banner is gone, or it never came. A banner that's still there has nothing standing
    /// in for it now, so its window comes back even if another card would like it away, and canPark keeps
    /// it here. This can't wait for the app's next call: a restore and a park can reach this in either order.
    /// A banner that's gone only lets go of the window.
    func restore(token: String) {
        let identity = liveBanners.first(where: { $0.value.token == token })?.key

        // A repeat with the same identity can have the token in a second window as well
        for key in Array(parkedWindows.keys) where parkedWindows[key]?.tokens.contains(token) == true {
            parkedWindows[key]?.tokens.remove(token)
            if identity != nil || parkedWindows[key]?.tokens.isEmpty == true {
                restoreWindow(forKey: key)
            }
        }

        if let identity, let window = liveBanners[identity]?.window {
            liveBanners[identity]?.hasCard = false
            liveBanners[identity]?.awaitsCard = false
            restoreWindow(forKey: key(for: window))
        }
    }

    /// Presses the banner if it's still there and can be pressed. The app handles a no. A press on a stack
    /// may only unfold it, out of sight, so that's a no too.
    func press(token: String) -> Bool {
        guard AXIsProcessTrusted(),
              let live = liveBanners.values.first(where: { $0.token == token }),
              [NotificationPanelDetection.plainBannerSubrole, NotificationPanelDetection.alertSubrole]
                .contains(live.element.string(kAXSubroleAttribute))
        else { return false }
        var actions: CFArray?
        guard AXUIElementCopyActionNames(live.element, &actions) == .success,
              (actions as? [String])?.contains(kAXPressAction) == true,
              AXUIElementPerformAction(live.element, kAXPressAction as CFString) == .success
        else { return false }
        if live.isAlert {
            handBackIfUnanswered(token: token)
        }
        return true
    }

    /// Presses one of an alert's buttons, found again by what it says.
    func perform(token: String, action label: String) -> Bool {
        guard AXIsProcessTrusted(),
              let live = liveBanners.values.first(where: { $0.token == token }), live.isAlert,
              let action = buttons(of: live.element).first(where: { $0.label == label }),
              AXUIElementPerformAction(live.element, action.name as CFString) == .success
        else { return false }
        handBackIfUnanswered(token: token)
        return true
    }

    /// An alert that's still there a moment after a press wanted more than that, like a reply to be typed
    /// or a menu. It comes back on screen to be finished there, and its card goes.
    private func handBackIfUnanswered(token: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + answerCheckDelay) { [weak self] in
            guard let self else { return }
            // Its leaving may not have been looked at yet
            self.scan()
            guard self.liveBanners.values.contains(where: { $0.token == token }) else { return }
            self.restore(token: token)
            self.ended(token: token)
        }
    }

    /// In the same order as the cards, which also come by the other queue.
    private func ended(token: String) {
        let onEnded = self.onEnded
        bundleIDQueue.async {
            onEnded?(token)
        }
    }

    /// The buttons Notification Center offers as an alert's own actions, as "Name:<label>\nTarget:…".
    private func buttons(of alert: AXUIElement) -> [(label: String, name: String)] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(alert, &names) == .success, let names = names as? [String] else {
            return []
        }
        return names.compactMap { name in
            guard name.hasPrefix("Name:") else { return nil }
            let label = name.dropFirst(5).components(separatedBy: "\nTarget:")[0]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return label.isEmpty ? nil : (label, name)
        }
    }

    // MARK: - Replying

    /// Unfolds the banner to its reply field, out of sight. Unfolded it also stays until it's answered or
    /// folded again. No if the field didn't come.
    func beginReply(token: String, completion: @escaping (Bool) -> Void) {
        guard AXIsProcessTrusted(),
              let identity = liveBanners.first(where: { $0.value.token == token })?.key,
              let banner = liveBanners[identity]
        else { return completion(false) }
        if banner.isReplying, replyField(in: banner.element) != nil { return completion(true) }

        guard let opener = buttons(of: banner.element).first(where: { replyOpeners.contains(plainLabel($0.label)) }) else {
            return completion(false)
        }
        // Before it changes, so the scans keep it for the same banner
        liveBanners[identity]?.isReplying = true
        guard !pressDidNothing(AXUIElementPerformAction(banner.element, opener.name as CFString)) else {
            liveBanners[identity]?.isReplying = false
            return completion(false)
        }
        waitForReplyField(token: token, until: Date().addingTimeInterval(replyWaitTime), completion: completion)
    }

    private func waitForReplyField(token: String, until deadline: Date, completion: @escaping (Bool) -> Void) {
        scan()
        guard let banner = liveBanners.values.first(where: { $0.token == token }) else { return completion(false) }
        if replyField(in: banner.element) != nil { return completion(true) }
        guard Date() < deadline else {
            endReply(token: token)
            return completion(false)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + replyPollInterval) { [weak self] in
            guard let self else { return completion(false) }
            self.waitForReplyField(token: token, until: deadline, completion: completion)
        }
    }

    /// Puts the text in the banner's own field and sends it with the banner's own button. The text is only
    /// sent if the field holds all of it, and only counted, never kept. Yes once the field let go of it.
    func sendReply(token: String, text: String, completion: @escaping (Bool) -> Void) {
        guard AXIsProcessTrusted(),
              let banner = liveBanners.values.first(where: { $0.token == token }), banner.isReplying,
              let field = replyField(in: banner.element),
              let sender = buttons(of: banner.element).first(where: { replySenders.contains(plainLabel($0.label)) }),
              AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, text as CFString) == .success,
              characterCount(of: field) == (text as NSString).length
        else {
            clearReplyField(token: token)
            return completion(false)
        }
        guard !pressDidNothing(AXUIElementPerformAction(banner.element, sender.name as CFString)) else {
            clearReplyField(token: token)
            return completion(false)
        }
        waitForSent(token: token, until: Date().addingTimeInterval(replyWaitTime), completion: completion)
    }

    private func waitForSent(token: String, until deadline: Date, completion: @escaping (Bool) -> Void) {
        scan()
        guard let banner = liveBanners.values.first(where: { $0.token == token }) else { return completion(true) }
        guard let field = replyField(in: banner.element), characterCount(of: field) != 0 else {
            endReply(token: token)
            return completion(true)
        }
        guard Date() < deadline else {
            clearReplyField(token: token)
            endReply(token: token)
            return completion(false)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + replyPollInterval) { [weak self] in
            guard let self else { return completion(false) }
            self.waitForSent(token: token, until: deadline, completion: completion)
        }
    }

    /// Nothing typed stays behind in the banner, which comes back on screen if its card goes.
    func cancelReply(token: String) {
        clearReplyField(token: token)
        endReply(token: token)
    }

    private func clearReplyField(token: String) {
        guard let banner = liveBanners.values.first(where: { $0.token == token }),
              let field = replyField(in: banner.element)
        else { return }
        AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, "" as CFString)
    }

    /// Folds the banner back if it's still unfolded. From then on it's an ordinary banner again.
    private func endReply(token: String) {
        guard let identity = liveBanners.first(where: { $0.value.token == token })?.key,
              let banner = liveBanners[identity]
        else { return }
        // Only an unfolded banner offers this, with or without a field in it
        if let closer = buttons(of: banner.element).first(where: { replyClosers.contains(plainLabel($0.label)) }) {
            AXUIElementPerformAction(banner.element, closer.name as CFString)
        }
        liveBanners[identity]?.isReplying = false
    }

    private func replyField(in banner: AXUIElement) -> AXUIElement? {
        var pending = [banner]
        var visited = 0
        while let element = pending.popLast(), visited < maxTextNodes {
            visited += 1
            let role = element.string(kAXRoleAttribute)
            if role == kAXTextAreaRole || role == kAXTextFieldRole {
                return element
            }
            pending.append(contentsOf: element.children())
        }
        return nil
    }

    private func characterCount(of field: AXUIElement) -> Int? {
        (field[kAXNumberOfCharactersAttribute] as? NSNumber)?.intValue
    }

    /// Windows left at the parking position by a helper that died can be put back without watching.
    func restoreStranded() {
        guard AXIsProcessTrusted() else { return }
        if let windows = appElement?.windows() {
            restoreStrandedWindows(windows)
        } else if !isRunning, let processIdentifier = notificationCenterProcess() {
            restoreStrandedWindows(AXUIElementCreateApplication(processIdentifier).windows() ?? [], attempts: restoreAttempts)
        }
    }

    private func restoreStrandedWindows(_ windows: [AXUIElement], attempts: Int = 1) {
        var couldNotRead = false
        let stranded = windows.filter { window in
            guard parkedWindows[key(for: window)] == nil else { return false }
            guard let position = window.position() else {
                couldNotRead = true
                return false
            }
            return isParked(position)
        }
        if stranded.isEmpty {
            // One that can't be read may well be the one a retry is for
            if couldNotRead, restoreRetries > 0 {
                retryRestoreLater()
            } else {
                restoreRetries = 0
            }
        }
        for window in stranded {
            moveOffParking(window, to: lastOrigin ?? restingOrigin(of: window), attempts: attempts)
        }
    }

    /// For when a window's own place was lost with the helper. This only has to be on screen, where
    /// banners belong. Reports differ on whether Notification Center places the window again itself
    /// before its next banner, so nothing relies on that.
    private func restingOrigin(of window: AXUIElement) -> CGPoint {
        let display = CGDisplayBounds(CGMainDisplayID())
        return CGPoint(x: display.maxX - (window.size()?.width ?? 0), y: display.minY)
    }

    private func hasDisplay(at point: CGPoint) -> Bool {
        var count: UInt32 = 0
        return CGGetDisplaysWithPoint(point, 0, nil, &count) != .success || count > 0
    }

    private func releaseAfterSlideOut(token: String) {
        for key in Array(parkedWindows.keys) where parkedWindows[key]?.tokens.contains(token) == true {
            parkedWindows[key]?.tokens.remove(token)
            guard parkedWindows[key]?.tokens.isEmpty == true else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay) { [weak self] in
                // A newer card may have taken the window in the meantime
                guard let self, self.parkedWindows[key]?.tokens.isEmpty == true else { return }
                self.restoreWindow(forKey: key)
            }
        }
    }

    private func restoreWindow(forKey key: Int, attempts: Int = 1) {
        guard let parked = parkedWindows.removeValue(forKey: key) else { return }
        moveOffParking(parked.window, to: parked.origin, attempts: attempts)
    }

    /// Immediate: on stop the helper may be about to exit.
    private func restoreAllWindows(attempts: Int = 1) {
        for key in Array(parkedWindows.keys) {
            restoreWindow(forKey: key, attempts: attempts)
        }
    }

    /// False if the window is still off screen. It's found again by its position in a later scan, and
    /// since scans otherwise only follow AX events, a failure asks for one, a limited number of times.
    @discardableResult
    private func moveOffParking(_ window: AXUIElement, to origin: CGPoint, attempts: Int = 1) -> Bool {
        // The display it came from may have been unplugged or moved since
        let origin = hasDisplay(at: origin) ? origin : restingOrigin(of: window)
        for attempt in 1...attempts {
            if tryMovingOffParking(window, to: origin) {
                restoreRetries = 0
                return true
            }
            if attempt < attempts {
                Thread.sleep(forTimeInterval: 0.1)
            }
        }

        retryRestoreLater()
        return false
    }

    private func retryRestoreLater() {
        guard restoreRetries < maxRestoreRetries else { return }
        restoreRetries += 1
        if restoreRetries == maxRestoreRetries {
            NSLog("[boringNotch] a notification window could not be moved back")
        }
        if isRunning {
            scheduleSettleScan()
        }
    }

    private func tryMovingOffParking(_ window: AXUIElement, to origin: CGPoint) -> Bool {
        // Notification Center may have placed it already, and its place beats the remembered one
        if let position = window.position(), !isParked(position) { return true }

        let result = window.move(to: origin)
        return result == .invalidUIElement || (result == .success && window.position().map(isParked) != true)
    }

    /// An observer may not survive the permission going away and coming back, and only a new start
    /// makes a new one. So it's checked here, and the app hears about it when the watcher stops. The exit
    /// of a process that was already gone when it was first watched may never be reported, so that too.
    private func watchHealth() {
        healthTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + healthCheckInterval, repeating: healthCheckInterval, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if !AXIsProcessTrusted() {
                self.accessibilityLost()
            } else if let processIdentifier = self.processIdentifier,
                      executablePath(of: processIdentifier) != notificationCenterPath {
                self.notificationCenterExited()
            }
        }
        healthTimer = timer
        timer.resume()
    }

    /// The permission reads as gone. If it is, windows can't be moved any more: what's parked stays off
    /// screen until its banner expires on its own, and the next banner comes in a new window, on screen.
    /// The system's own process is left alone. If the reading was false, stopping has just put everything back.
    private func accessibilityLost() {
        stop()
        onStopped?()
    }

    // MARK: - Reading

    /// The banner is read here and the rest happens on the other queue. If that takes too long, the banner
    /// comes back by itself in the meantime and the card follows when it's ready.
    private func report(_ banner: AXUIElement, text: BannerText, token: String) {
        let description = (banner["AXAttributedDescription"] as? NSAttributedString)?.string
            ?? banner["AXAttributedDescription"] as? String
        let appName = description.flatMap { value in
            value.split(separator: ",", maxSplits: 1)
                .first
                .map { Self.cleanedAppName(String($0)) }
        }
        let isAlert = banner.string(kAXSubroleAttribute) == NotificationPanelDetection.alertSubrole
        let labels = buttons(of: banner).map(\.label)
        let actions = isAlert ? labels.filter { !unfoldingActions.contains($0) } : []
        let canReply = labels.contains { replyOpeners.contains(plainLabel($0)) }

        // The helper sets this again on the main queue with every start
        let onBanner = self.onBanner
        bundleIDQueue.async { [weak self] in
            onBanner?(CapturedNotification(
                token: token,
                appName: appName,
                bundleID: appName.flatMap { self?.bundleID(forAppNamed: $0) },
                title: text.title,
                subtitle: text.subtitle,
                body: text.body,
                isAlert: isAlert,
                actions: actions,
                canReply: canReply
            ))
        }
    }

    /// Only what the banner displays: with previews hidden that's all there is to read.
    private func readText(in root: AXUIElement) -> BannerText {
        var text = BannerText()
        var pending = [root]
        var visited = Set<CFHashCode>()

        while let element = pending.popLast() {
            guard visited.insert(CFHash(element)).inserted else { continue }
            guard visited.count <= maxTextNodes else { break }
            if element["AXHidden"] as? Bool == true { continue }

            if let identifier = element.string(kAXIdentifierAttribute),
               let value = element[kAXValueAttribute] as? String {
                let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty {
                    switch identifier {
                    case "title":
                        text.title = value
                    case "header" where text.title == nil:
                        text.title = value
                    case "subtitle":
                        text.subtitle = value
                    case "body":
                        text.body = value
                    default:
                        break
                    }
                }
            }

            pending.append(contentsOf: element.children().reversed())
        }

        return text
    }

    private func bundleID(forAppNamed name: String) -> String? {
        let target = Self.normalizedAppName(name)
        guard !target.isEmpty else { return nil }
        if let cached = bundleIDCache[target] { return cached }

        // May be out of date in this service, see notificationCenterProcess. The search below covers for it.
        let running = NSWorkspace.shared.runningApplications
            .filter {
                guard let localizedName = $0.localizedName else { return false }
                return Self.normalizedAppName(localizedName) == target
            }
            .sorted(by: Self.preferRegularApplication)
            .compactMap { $0.bundleIdentifier }
            .first

        // A miss is only kept for a moment: the app may be installed by a later banner
        if running == nil, let missed = bundleIDMisses[target],
           Date().timeIntervalSince(missed) < bundleIDMissLifetime {
            return nil
        }
        let resolved = resolveBundleID(
            forRunningBundleID: running,
            appName: name,
            target: target
        )
        if let resolved {
            bundleIDCache[target] = resolved
        } else {
            bundleIDMisses[target] = Date()
        }
        return resolved
    }

    private func resolveBundleID(
        forRunningBundleID runningBundleID: String?,
        appName: String,
        target: String
    ) -> String? {
        if let runningBundleID {
            return normalizedBundleIdentifier(runningBundleID)
        }

        let displayName = Self.cleanedAppName(appName)
        let withoutSpaces = displayName.replacingOccurrences(of: " ", with: "")
        let filenameCandidates = withoutSpaces == displayName
            ? [displayName]
            : [displayName, withoutSpaces]
        let directories = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications"),
            URL(fileURLWithPath: "/Applications/Utilities"),
            URL(fileURLWithPath: "/System/Applications/Utilities"),
            URL(fileURLWithPath: "/System/Library/CoreServices")
        ]

        for directory in directories {
            for candidate in filenameCandidates where !candidate.isEmpty {
                let appURL = directory.appendingPathComponent(candidate).appendingPathExtension("app")
                if let bundleID = bundleIdentifier(at: appURL) {
                    return normalizedBundleIdentifier(bundleID)
                }
            }
        }

        for directory in directories {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles]
            ) else { continue }

            for entry in entries where entry.pathExtension == "app" {
                guard let bundle = Bundle(url: entry), let bundleID = bundle.bundleIdentifier else { continue }
                let names = [
                    entry.deletingPathExtension().lastPathComponent,
                    Self.shownName(of: entry),
                    bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
                    bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                ]
                if names.contains(where: { name in
                    guard let name else { return false }
                    return Self.normalizedAppName(name) == target
                }) {
                    return normalizedBundleIdentifier(bundleID)
                }
            }
        }
        return nil
    }

    /// The name in the language of this Mac, which is what banners say: Calendar.app is "Kalender" on a German one.
    private static func shownName(of appURL: URL) -> String? {
        guard let item = MDItemCreateWithURL(kCFAllocatorDefault, appURL as CFURL),
              let name = MDItemCopyAttribute(item, kMDItemDisplayName) as? String else { return nil }
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    private func bundleIdentifier(at appURL: URL) -> String? {
        guard FileManager.default.fileExists(atPath: appURL.path) else { return nil }
        return Bundle(url: appURL)?.bundleIdentifier
    }

    private func normalizedBundleIdentifier(_ bundleID: String) -> String {
        let lower = bundleID.lowercased()
        if lower.hasPrefix("com.apple.safaritechnologypreview.") {
            return "com.apple.SafariTechnologyPreview"
        }
        if lower.hasPrefix("com.apple.webkit.") || lower.hasPrefix("com.apple.safari.") {
            return "com.apple.Safari"
        }
        let components = bundleID.components(separatedBy: ".")
        if let helperIndex = components.firstIndex(where: { $0.lowercased() == "helper" }) {
            return components[0..<helperIndex].joined(separator: ".")
        }
        return bundleID
    }

    private static func normalizedAppName(_ name: String) -> String {
        cleanedAppName(name).lowercased()
    }

    private static func cleanedAppName(_ name: String) -> String {
        name.filter { !$0.unicodeScalars.allSatisfy(invisibleCharacters.contains) }
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Bidi controls, and the soft hyphen macOS puts into long names like "System\u{AD}einstellungen"
    private static let invisibleCharacters: CharacterSet = {
        var set = CharacterSet()
        set.insert(charactersIn: "\u{AD}\u{200E}\u{200F}")
        set.insert(charactersIn: "\u{2066}"..."\u{2069}")
        set.insert(charactersIn: "\u{202A}"..."\u{202E}")
        return set
    }()

    private static func preferRegularApplication(
        _ lhs: NSRunningApplication,
        _ rhs: NSRunningApplication
    ) -> Bool {
        if lhs.activationPolicy == .regular, rhs.activationPolicy != .regular {
            return true
        }
        if rhs.activationPolicy == .regular, lhs.activationPolicy != .regular {
            return false
        }
        return lhs.processIdentifier < rhs.processIdentifier
    }
}

private final class AXObserverRunLoop {
    private let observer: AXObserver
    /// A callback can still be running after `stop()`, which only asks the thread to end. The thread
    /// holds on to this object until it has exited, and so to the context the callback points at.
    private let context: ObserverContext
    private let ready = DispatchSemaphore(value: 0)
    private var runLoop: CFRunLoop?

    init(observer: AXObserver, context: ObserverContext) {
        self.observer = observer
        self.context = context
    }

    func start() {
        let thread = Thread { [self] in
            let runLoop = CFRunLoopGetCurrent()
            self.runLoop = runLoop
            CFRunLoopAddSource(
                runLoop,
                AXObserverGetRunLoopSource(self.observer),
                .defaultMode
            )
            self.ready.signal()
            CFRunLoopRun()
            CFRunLoopRemoveSource(
                runLoop,
                AXObserverGetRunLoopSource(self.observer),
                .defaultMode
            )
        }
        thread.start()
        ready.wait()
    }

    func stop() {
        guard let runLoop else { return }
        // CFRunLoopStop alone would be lost on a loop that's only about to run. A block waits for it.
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) {
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
        CFRunLoopWakeUp(runLoop)
        self.runLoop = nil
    }
}
