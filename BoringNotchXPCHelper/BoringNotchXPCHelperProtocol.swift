//
//  BoringNotchXPCHelperProtocol.swift
//  BoringNotchXPCHelper
//
//  Created by Alexander on 2025-11-16.
//

import Foundation

/// The protocol that this service will vend as its API. This protocol will also need to be visible to the process hosting the service.
@objc protocol BoringNotchXPCHelperProtocol {
    func isAccessibilityAuthorized(with reply: @escaping (Bool) -> Void)
    func requestAccessibilityAuthorization()
    func ensureAccessibilityAuthorization(_ promptIfNeeded: Bool, with reply: @escaping (Bool) -> Void)
    // Keyboard backlight / CoreBrightness access (performed by the helper)
    func currentKeyboardBrightness(with reply: @escaping (NSNumber?) -> Void)
    func setKeyboardBrightness(_ value: Float, with reply: @escaping (Bool) -> Void)
    // Screen brightness access (performed by the helper)
    func currentScreenBrightness(with reply: @escaping (NSNumber?) -> Void)
    func setScreenBrightness(_ value: Float, with reply: @escaping (Bool) -> Void)
    // Notification Center banners (read and moved by the helper)
    func startNotificationWatching(with reply: @escaping (Bool) -> Void)
    func stopNotificationWatching()
    func parkNotification(_ token: String, with reply: @escaping (Bool) -> Void)
    func restoreNotification(_ token: String)
    func pressNotification(_ token: String, with reply: @escaping (Bool) -> Void)
    func restoreStrandedNotifications()
    // The microphone (set by the helper, which isn't sandboxed)
    func keepMicOnMacBook()
}

/// Calls from the helper back to the app.
@objc protocol BoringNotchXPCAppDelegate {
    func notificationDidAppear(_ payload: [String: String])
    func notificationWatchingDidStop()
}
