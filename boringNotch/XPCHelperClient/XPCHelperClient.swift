import Foundation
import Cocoa
import AsyncXPCConnection

final class XPCHelperClient: NSObject {
    nonisolated static let shared = XPCHelperClient()
    
    private let serviceName = "com.nichtege.boringnotch.BoringNotchXPCHelper"
    
    private var remoteService: RemoteXPCService<BoringNotchXPCHelperProtocol>?
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
    private func ensureRemoteService() -> RemoteXPCService<BoringNotchXPCHelperProtocol> {
        if let existing = remoteService {
            return existing
        }
        
        let conn = NSXPCConnection(serviceName: serviceName)
        
        conn.exportedInterface = NSXPCInterface(with: (any BoringNotchXPCAppDelegate).self)
        conn.exportedObject = notificationDelegate
        
        // Late handlers of an old connection must not touch a newer one, and the helper's state is
        // only lost once per connection.
        conn.interruptionHandler = { [weak self, weak conn] in
            Task { @MainActor in
                guard let self, let conn, self.connection === conn else { return }
                self.connection = nil
                self.remoteService = nil
                NotificationCenter.default.post(name: .xpcHelperConnectionLost, object: nil)
            }
        }
        
        conn.invalidationHandler = { [weak self, weak conn] in
            Task { @MainActor in
                guard let self, let conn, self.connection === conn else { return }
                self.connection = nil
                self.remoteService = nil
                NotificationCenter.default.post(name: .xpcHelperConnectionLost, object: nil)
            }
        }
        
        conn.resume()
        
        let service = RemoteXPCService<BoringNotchXPCHelperProtocol>(
            connection: conn,
            remoteInterface: BoringNotchXPCHelperProtocol.self
        )
        
        connection = conn
        remoteService = service
        return service
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
        Task {
            let service = await MainActor.run {
                ensureRemoteService()
            }
            try? await service.withService { service in
                service.requestAccessibilityAuthorization()
            }
        }
    }
    
    nonisolated func isAccessibilityAuthorized() async -> Bool {
        do {
            let service = await MainActor.run {
                ensureRemoteService()
            }
            let result: Bool = try await service.withContinuation { service, continuation in
                service.isAccessibilityAuthorized { authorized in
                    continuation.resume(returning: authorized)
                }
            }
            await MainActor.run {
                notifyAuthorizationChange(result)
            }
            return result
        } catch {
            return false
        }
    }
    
    nonisolated func ensureAccessibilityAuthorization(promptIfNeeded: Bool) async -> Bool {
        do {
            let service = await MainActor.run {
                ensureRemoteService()
            }
            let result: Bool = try await service.withContinuation { service, continuation in
                service.ensureAccessibilityAuthorization(promptIfNeeded) { authorized in
                    continuation.resume(returning: authorized)
                }
            }
            await MainActor.run {
                notifyAuthorizationChange(result)
            }
            return result
        } catch {
            return false
        }
    }
    
    // MARK: - Keyboard Brightness

    nonisolated func currentKeyboardBrightness() async -> Float? {
        do {
            let service = await MainActor.run {
                ensureRemoteService()
            }
            let result: NSNumber? = try await service.withContinuation { service, continuation in
                service.currentKeyboardBrightness { value in
                    continuation.resume(returning: value)
                }
            }
            return result?.floatValue
        } catch {
            return nil
        }
    }
    
    nonisolated func setKeyboardBrightness(_ value: Float) async -> Bool {
        do {
            let service = await MainActor.run {
                ensureRemoteService()
            }
            return try await service.withContinuation { service, continuation in
                service.setKeyboardBrightness(value) { success in
                    continuation.resume(returning: success)
                }
            }
        } catch {
            return false
        }
    }
    
    // MARK: - Screen Brightness

    nonisolated func currentScreenBrightness() async -> Float? {
        do {
            let service = await MainActor.run {
                ensureRemoteService()
            }
            let result: NSNumber? = try await service.withContinuation { service, continuation in
                service.currentScreenBrightness { value in
                    continuation.resume(returning: value)
                }
            }
            return result?.floatValue
        } catch {
            return nil
        }
    }
    
    nonisolated func setScreenBrightness(_ value: Float) async -> Bool {
        do {
            let service = await MainActor.run {
                ensureRemoteService()
            }
            return try await service.withContinuation { service, continuation in
                service.setScreenBrightness(value) { success in
                    continuation.resume(returning: success)
                }
            }
        } catch {
            return false
        }
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
        do {
            let service = await MainActor.run {
                ensureRemoteService()
            }
            return try await service.withContinuation { service, continuation in
                service.startNotificationWatching { started in
                    continuation.resume(returning: started)
                }
            }
        } catch {
            return false
        }
    }
    
    nonisolated func stopNotificationWatching() {
        Task {
            let service = await MainActor.run {
                ensureRemoteService()
            }
            try? await service.withService { service in
                service.stopNotificationWatching()
            }
        }
    }
    
    nonisolated func parkNotification(_ token: String) async -> Bool {
        do {
            let service = await MainActor.run {
                ensureRemoteService()
            }
            return try await service.withContinuation { service, continuation in
                service.parkNotification(token) { parked in
                    continuation.resume(returning: parked)
                }
            }
        } catch {
            return false
        }
    }
    
    nonisolated func restoreNotification(_ token: String) {
        Task {
            let service = await MainActor.run {
                ensureRemoteService()
            }
            try? await service.withService { service in
                service.restoreNotification(token)
            }
        }
    }
    
    nonisolated func pressNotification(_ token: String) async -> Bool {
        do {
            let service = await MainActor.run {
                ensureRemoteService()
            }
            return try await service.withContinuation { service, continuation in
                service.pressNotification(token) { pressed in
                    continuation.resume(returning: pressed)
                }
            }
        } catch {
            return false
        }
    }
    
    nonisolated func restoreStrandedNotifications() {
        Task {
            let service = await MainActor.run {
                ensureRemoteService()
            }
            try? await service.withService { service in
                service.restoreStrandedNotifications()
            }
        }
    }
}

extension Notification.Name {
    static let accessibilityAuthorizationChanged = Notification.Name("accessibilityAuthorizationChanged")
    /// The helper crashed or was killed, and its state with it. The next call relaunches a fresh one.
    static let xpcHelperConnectionLost = Notification.Name("xpcHelperConnectionLost")
}


