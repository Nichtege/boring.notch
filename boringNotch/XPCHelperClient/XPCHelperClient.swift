import Foundation
import Cocoa

final class XPCHelperClient: NSObject {
    nonisolated static let shared = XPCHelperClient()
    
    private let serviceName = "com.nichtege.boringnotch.BoringNotchXPCHelper"
    
    private var connection: NSXPCConnection?
    private var lastKnownAuthorization: Bool?
    private var monitoringTask: Task<Void, Never>?
    private let notificationDelegate = NotificationXPCDelegate()
    
    deinit {
        connection?.invalidate()
        stopMonitoringAccessibilityAuthorization()
    }
    
    // MARK: - Connection Management (Main Actor Isolated)
    
    @MainActor
    private func ensureConnection() -> NSXPCConnection {
        if let existing = connection {
            return existing
        }
        
        let conn = NSXPCConnection(serviceName: serviceName)
        
        conn.remoteObjectInterface = NSXPCInterface(with: (any BoringNotchXPCHelperProtocol).self)
        conn.exportedInterface = NSXPCInterface(with: (any BoringNotchXPCAppDelegate).self)
        conn.exportedObject = notificationDelegate
        
        // Late handlers of an old connection must not touch a newer one, and the helper's state is
        // only lost once per connection.
        conn.interruptionHandler = { [weak self, weak conn] in
            Task { @MainActor in
                guard let self, let conn, self.connection === conn else { return }
                self.connection = nil
                NotificationCenter.default.post(name: .xpcHelperConnectionLost, object: nil)
            }
        }
        
        conn.invalidationHandler = { [weak self, weak conn] in
            Task { @MainActor in
                guard let self, let conn, self.connection === conn else { return }
                self.connection = nil
                NotificationCenter.default.post(name: .xpcHelperConnectionLost, object: nil)
            }
        }
        
        conn.resume()
        
        connection = conn
        return conn
    }
    
    /// The helper's answer, nil if it can't be reached.
    private nonisolated func ask<Answer>(
        _ call: (any BoringNotchXPCHelperProtocol, @escaping (Answer) -> Void) -> Void
    ) async -> Answer? {
        let connection = await MainActor.run {
            ensureConnection()
        }
        return await withCheckedContinuation { continuation in
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
                continuation.resume(returning: nil)
            }
            guard let helper = proxy as? any BoringNotchXPCHelperProtocol else {
                continuation.resume(returning: nil)
                return
            }
            call(helper) { continuation.resume(returning: $0) }
        }
    }
    
    /// For calls without an answer. A helper that's gone shows up in the connection's handlers.
    private nonisolated func send(_ call: @escaping @Sendable (any BoringNotchXPCHelperProtocol) -> Void) {
        Task {
            let connection = await MainActor.run {
                ensureConnection()
            }
            if let helper = connection.remoteObjectProxyWithErrorHandler({ _ in }) as? any BoringNotchXPCHelperProtocol {
                call(helper)
            }
        }
    }
    
    @MainActor
    private func notifyAuthorizationChange(_ granted: Bool) {
        guard lastKnownAuthorization != granted else { return }
        lastKnownAuthorization = granted
        NotificationCenter.default.post(
            name: .accessibilityAuthorizationChanged,
            object: nil,
            userInfo: ["granted": granted]
        )
    }

    // MARK: - Monitoring
    nonisolated func startMonitoringAccessibilityAuthorization(every interval: TimeInterval = 3.0) {
        // Ensure only one monitor exists
        stopMonitoringAccessibilityAuthorization()
        monitoringTask = Task.detached { [weak self] in
            guard let self = self else { return }
            while !Task.isCancelled {
                // Call the helper method periodically which will notify on change
                _ = await self.isAccessibilityAuthorized()
                do {
                    try await Task.sleep(for: .seconds(interval))
                } catch { break }
            }
        }
    }

    nonisolated func stopMonitoringAccessibilityAuthorization() {
        monitoringTask?.cancel()
        monitoringTask = nil
    }

    // MARK: - Accessibility
    
    nonisolated func requestAccessibilityAuthorization() {
        send { $0.requestAccessibilityAuthorization() }
    }
    
    nonisolated func isAccessibilityAuthorized() async -> Bool {
        let answer: Bool? = await ask { $0.isAccessibilityAuthorized(with: $1) }
        guard let answer else { return false }
        await MainActor.run {
            notifyAuthorizationChange(answer)
        }
        return answer
    }
    
    nonisolated func ensureAccessibilityAuthorization(promptIfNeeded: Bool) async -> Bool {
        let answer: Bool? = await ask { $0.ensureAccessibilityAuthorization(promptIfNeeded, with: $1) }
        guard let answer else { return false }
        await MainActor.run {
            notifyAuthorizationChange(answer)
        }
        return answer
    }
    
    // MARK: - Keyboard Brightness
    
    nonisolated func currentKeyboardBrightness() async -> Float? {
        let value: NSNumber?? = await ask { $0.currentKeyboardBrightness(with: $1) }
        return value??.floatValue
    }
    
    nonisolated func setKeyboardBrightness(_ value: Float) async -> Bool {
        await ask { $0.setKeyboardBrightness(value, with: $1) } ?? false
    }
    
    // MARK: - Screen Brightness
    
    nonisolated func currentScreenBrightness() async -> Float? {
        let value: NSNumber?? = await ask { $0.currentScreenBrightness(with: $1) }
        return value??.floatValue
    }
    
    nonisolated func setScreenBrightness(_ value: Float) async -> Bool {
        await ask { $0.setScreenBrightness(value, with: $1) } ?? false
    }
}

// MARK: - Notification Center banners

/// The app's exported XPC object: banners the helper read come in here.
final class NotificationXPCDelegate: NSObject, BoringNotchXPCAppDelegate {
    func notificationDidAppear(_ payload: [String: String]) {
        Task { @MainActor in
            SystemNotificationManager.shared.bannerDidAppear(payload)
        }
    }

    func notificationWatchingDidStop() {
        Task { @MainActor in
            SystemNotificationManager.shared.checkWatchingNow()
        }
    }
}

extension XPCHelperClient {
    nonisolated func startNotificationWatching() async -> Bool {
        await ask { $0.startNotificationWatching(with: $1) } ?? false
    }
    
    nonisolated func stopNotificationWatching() {
        send { $0.stopNotificationWatching() }
    }
    
    nonisolated func parkNotification(_ token: String) async -> Bool {
        await ask { $0.parkNotification(token, with: $1) } ?? false
    }
    
    nonisolated func restoreNotification(_ token: String) {
        send { $0.restoreNotification(token) }
    }
    
    nonisolated func pressNotification(_ token: String) async -> Bool {
        await ask { $0.pressNotification(token, with: $1) } ?? false
    }
    
    nonisolated func restoreStrandedNotifications() {
        send { $0.restoreStrandedNotifications() }
    }
}

extension Notification.Name {
    static let accessibilityAuthorizationChanged = Notification.Name("accessibilityAuthorizationChanged")
    /// The helper crashed or was killed, and its state with it. The next call relaunches a fresh one.
    static let xpcHelperConnectionLost = Notification.Name("xpcHelperConnectionLost")
}


