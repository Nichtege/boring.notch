//
//  NotificationWatcher.swift
//  BoringNotchXPCHelper
//
//  Reads the banners Notification Center shows. A banner's window only leaves the screen when the app
//  says its card is up, and every way out of here puts the window back, as far as Accessibility still
//  allows that. What a banner says stays in memory: tokens are made up here, so they hold none of it,
//  and nothing logs it.
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
/// Children of windows that aren't watched for banners report events too, and a scan isn't cheap. The
/// first scan after a quiet moment still runs at once.
private let minScanInterval: TimeInterval = 0.25
private let healthCheckInterval: TimeInterval = 5
private let parkingPosition = CGPoint(x: -10000, y: -10000)
/// Notification Center slides a banner out before it orders the window out, and the window can only
/// be moved until then (about half a second). Moving it back at once would show the end of that slide.
private let restoreDelay: TimeInterval = 0.35
/// A closing center has given up focus, but its old notifications are still there for a moment.
private let centerClosingDelay: TimeInterval = 1
private let restoreAttempts = 3
private let maxRestoreRetries = 10
private let reattachAttempts = 30

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
    }

    private struct ParkedWindow {
        let window: AXUIElement
        let origin: CGPoint
        var tokens: Set<String>
    }

    var onBanner: ((CapturedNotification) -> Void)?
    /// The permission is gone and the watcher stopped by itself.
    var onStopped: (() -> Void)?

    private var appElement: AXUIElement?
    private var processIdentifier: pid_t?
    private var axObserver: AXObserver?
    private var observerRunLoop: AXObserverRunLoop?
    private var observerContext: ObserverContext?
    private var scanScheduled = false
    private var lastScan = Date.distantPast
    private var settleWorkItem: DispatchWorkItem?
    private var observedWindows: [CFHashCode: AXUIElement] = [:]
    private var liveBanners: [Int: LiveBanner] = [:]
    private var parkedWindows: [Int: ParkedWindow] = [:]
    private var lastOrigin: CGPoint?
    private var restoreRetries = 0
    private var centerLastOpen: Date?
    private var bundleIDCache: [String: String] = [:]
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
        restoreAllWindows()
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
        scanScheduled = false
        restoreRetries = 0
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
        guard !scanScheduled else { return }
        scanScheduled = true
        let wait = max(0, minScanInterval - Date().timeIntervalSince(lastScan))
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self else { return }
            self.scanScheduled = false
            self.scan()
        }
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
                centerLastOpen = Date()
                restoreAllWindows()
                return
            }
            let centerIsClosing = centerLastOpen.map { Date().timeIntervalSince($0) < centerClosingDelay } ?? false

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

                // A banner that became a stack can keep its identifier and text, and so can a repeat
                // next to the original. Neither is what the card stands in for any more.
                let isStillMirrorable = readings.allSatisfy { NotificationPanelDetection.isMirrorable(subrole: $0.banner.subrole) }
                    && Set(readings.map { $0.identity }).count == readings.count
                if !isStillMirrorable {
                    restoreWindow(forKey: key(for: window))
                }

                let fresh = readings.filter { liveBanners[$0.identity] == nil }
                for reading in readings where liveBanners[reading.identity] != nil {
                    liveBanners[reading.identity]?.element = reading.banner.element
                    liveBanners[reading.identity]?.window = window
                }
                guard !fresh.isEmpty else { continue }
                for reading in fresh {
                    liveBanners[reading.identity] = LiveBanner(
                        token: UUID().uuidString,
                        element: reading.banner.element,
                        window: window
                    )
                }

                // Nothing new has a card yet, so it has to be in sight, also in a window that's
                // parked for an earlier banner. The app parks it again once the new card is up.
                restoreWindow(forKey: key(for: window))

                // Several new ones at once are a stack in all but name
                guard !centerIsClosing, fresh.count == 1, let reading = fresh.first,
                      NotificationPanelDetection.isMirrorable(subrole: reading.banner.subrole),
                      !reading.text.isEmpty,
                      let token = liveBanners[reading.identity]?.token
                else { continue }
                onBanner?(capture(reading.banner.element, text: reading.text, token: token))
            }

            for identity in Array(liveBanners.keys) where !seen.contains(identity) {
                if let banner = liveBanners.removeValue(forKey: identity) {
                    releaseAfterSlideOut(token: banner.token)
                }
            }
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

    /// Called by the app once the card for this banner is really on screen. Everything is looked at
    /// again here, since the banner was read a moment ago: anything unclear leaves it where it is.
    func park(token: String) -> Bool {
        guard AXIsProcessTrusted(), let appElement,
              !centerMayBeOpen(appElement),
              let identity = liveBanners.first(where: { $0.value.token == token })?.key
        else { return false }
        liveBanners[identity]?.hasCard = true

        guard let window = liveBanners[identity]?.window,
              case .banners(let banners) = inspect(window),
              canPark(banners, for: identity),
              let position = window.position()
        else { return false }

        let windowKey = key(for: window)
        let origin = isParked(position)
            ? parkedWindows[windowKey]?.origin ?? lastOrigin ?? restingOrigin(of: window)
            : position

        if !isParked(position) {
            guard window.move(to: parkingPosition) == .success,
                  window.position().map(isParked) == true
            else {
                _ = window.move(to: origin)
                return false
            }
        }

        let tokens = (parkedWindows[windowKey]?.tokens ?? []).union([token])
        parkedWindows[windowKey] = ParkedWindow(window: window, origin: origin, tokens: tokens)
        lastOrigin = origin
        return true
    }

    /// Everything in the window has to be a banner, and either this one or one whose card has been up.
    private func canPark(_ banners: [Banner], for identity: Int) -> Bool {
        var containsBanner = false
        for banner in banners {
            guard NotificationPanelDetection.isMirrorable(subrole: banner.subrole) else { return false }
            let other = self.identity(of: banner.element, showing: readText(in: banner.element))
            if other == identity {
                guard !containsBanner else { return false }
                containsBanner = true
            } else if liveBanners[other]?.hasCard != true {
                return false
            }
        }
        return containsBanner
    }

    /// The card for this banner is gone. The window comes back unless another card still needs it away.
    func restore(token: String) {
        guard let key = parkedWindows.first(where: { $0.value.tokens.contains(token) })?.key else { return }
        parkedWindows[key]?.tokens.remove(token)
        if parkedWindows[key]?.tokens.isEmpty == true {
            restoreWindow(forKey: key)
        }
    }

    /// Presses the banner if it's still there and can be pressed. The app handles a no.
    func press(token: String) -> Bool {
        guard AXIsProcessTrusted(),
              let banner = liveBanners.values.first(where: { $0.token == token })?.element
        else { return false }
        var actions: CFArray?
        guard AXUIElementCopyActionNames(banner, &actions) == .success,
              (actions as? [String])?.contains(kAXPressAction) == true
        else { return false }
        return AXUIElementPerformAction(banner, kAXPressAction as CFString) == .success
    }

    /// Windows left at the parking position by a helper that died can be put back without watching.
    func restoreStranded() {
        guard AXIsProcessTrusted() else { return }
        if let windows = appElement?.windows() {
            restoreStrandedWindows(windows)
        } else if !isRunning, let processIdentifier = notificationCenterProcess() {
            restoreStrandedWindows(AXUIElementCreateApplication(processIdentifier).windows() ?? [])
        }
    }

    private func restoreStrandedWindows(_ windows: [AXUIElement]) {
        let stranded = windows.filter { parkedWindows[key(for: $0)] == nil && $0.position().map(isParked) == true }
        if stranded.isEmpty {
            restoreRetries = 0
        }
        for window in stranded {
            moveOffParking(window, to: lastOrigin ?? restingOrigin(of: window))
        }
    }

    /// For when a window's own place was lost with the helper. This only has to be on screen, where
    /// banners belong. Reports differ on whether Notification Center places the window again itself
    /// before its next banner, so nothing relies on that.
    private func restingOrigin(of window: AXUIElement) -> CGPoint {
        let display = CGDisplayBounds(CGMainDisplayID())
        return CGPoint(x: display.maxX - (window.size()?.width ?? 0), y: display.minY)
    }

    private func releaseAfterSlideOut(token: String) {
        guard let key = parkedWindows.first(where: { $0.value.tokens.contains(token) })?.key else { return }
        parkedWindows[key]?.tokens.remove(token)
        guard parkedWindows[key]?.tokens.isEmpty == true else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay) { [weak self] in
            // A newer card may have taken the window in the meantime
            guard let self, self.parkedWindows[key]?.tokens.isEmpty == true else { return }
            self.restoreWindow(forKey: key)
        }
    }

    private func restoreWindow(forKey key: Int) {
        guard let parked = parkedWindows.removeValue(forKey: key) else { return }
        moveOffParking(parked.window, to: parked.origin)
    }

    /// Immediate: on stop the helper may be about to exit.
    private func restoreAllWindows() {
        Array(parkedWindows.keys).forEach(restoreWindow(forKey:))
    }

    /// False if the window is still off screen. It's found again by its position in a later scan, and
    /// since scans otherwise only follow AX events, a failure asks for one, a limited number of times.
    @discardableResult
    private func moveOffParking(_ window: AXUIElement, to origin: CGPoint) -> Bool {
        for attempt in 1...restoreAttempts {
            if tryMovingOffParking(window, to: origin) {
                restoreRetries = 0
                return true
            }
            if attempt < restoreAttempts {
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
        timer.schedule(deadline: .now() + healthCheckInterval, repeating: healthCheckInterval)
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
    /// screen, its banner expires on its own, and the window comes back with the next start that has the
    /// permission. A later banner could land off screen until then. The system's own process is left
    /// alone. If the reading was false, stopping has just put everything back.
    private func accessibilityLost() {
        stop()
        onStopped?()
    }

    // MARK: - Reading

    private func capture(_ banner: AXUIElement, text: BannerText, token: String) -> CapturedNotification {
        let description = (banner["AXAttributedDescription"] as? NSAttributedString)?.string
            ?? banner["AXAttributedDescription"] as? String
        let appName = description.flatMap { value in
            value.split(separator: ",", maxSplits: 1)
                .first
                .map { Self.cleanedAppName(String($0)) }
        }

        return CapturedNotification(
            token: token,
            appName: appName,
            bundleID: appName.flatMap(bundleID(forAppNamed:)),
            title: text.title,
            subtitle: text.subtitle,
            body: text.body
        )
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

        // A miss isn't kept: the app may be installed or start by the next banner
        let resolved = resolveBundleID(
            forRunningBundleID: running,
            appName: name,
            target: target
        )
        if let resolved {
            bundleIDCache[target] = resolved
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
