//
//  BoringNotchXPCHelper.swift
//  BoringNotchXPCHelper
//
//  Created by Alexander on 2025-11-16.
//

import Foundation
import ApplicationServices
import IOKit
import CoreAudio
import CoreGraphics
import XPC

class BoringNotchXPCHelper: NSObject, BoringNotchXPCHelperProtocol {
    
    @objc func isAccessibilityAuthorized(with reply: @escaping (Bool) -> Void) {
        reply(AXIsProcessTrusted())
    }

    @objc func requestAccessibilityAuthorization() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    @objc func ensureAccessibilityAuthorization(_ promptIfNeeded: Bool, with reply: @escaping (Bool) -> Void) {
        if AXIsProcessTrusted() {
            reply(true)
            return
        }

        if promptIfNeeded {
            requestAccessibilityAuthorization()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            reply(AXIsProcessTrusted())
        }
    }
    
    // MARK: - Notification Center banners

    private static let watcher = NotificationWatcher()
    /// Held while banners are watched. Between XPC messages launchd treats the helper as idle and may
    /// kill it under memory pressure, which would leave a parked banner off screen. Main queue only.
    nonisolated(unsafe) private static var holdsWatchingTransaction = false

    @objc func startNotificationWatching(with reply: @escaping (Bool) -> Void) {
        // Capture the delegate for this connection before hopping queues:
        // NSXPCConnection.current() is only valid inside the incoming call.
        let proxy = NSXPCConnection.current()?.remoteObjectProxyWithErrorHandler { error in
            NSLog("[boringNotch] notification callback failed: \((error as NSError).code)")
        }
        let delegate = proxy as? BoringNotchXPCAppDelegate
        if delegate == nil {
            NSLog("[boringNotch] could not obtain notification delegate proxy")
        }

        DispatchQueue.main.async {
            let watcher = Self.watcher
            watcher.onBanner = { notification in
                delegate?.notificationDidAppear([
                    "token": notification.token,
                    "appName": notification.appName ?? "",
                    "bundleID": notification.bundleID ?? "",
                    "title": notification.title ?? "",
                    "subtitle": notification.subtitle ?? "",
                    "body": notification.body ?? "",
                    "kind": notification.isAlert ? "alert" : "banner",
                    // A string, like everything else in here: what the interface lets through without a list of classes
                    "actions": notification.actions.joined(separator: "\u{1F}")
                ])
            }
            watcher.onAlertEnded = { token in
                delegate?.notificationAlertDidEnd(token)
            }
            watcher.onStopped = {
                Self.stopWatching()
                delegate?.notificationWatchingDidStop()
            }
            let started = watcher.isRunning || watcher.start()
            if started && !Self.holdsWatchingTransaction {
                xpc_transaction_begin()
                Self.holdsWatchingTransaction = true
            }
            reply(started)
        }
    }

    @objc func stopNotificationWatching() {
        DispatchQueue.main.async { Self.stopWatching() }
    }

    @objc func parkNotification(_ token: String, with reply: @escaping (Bool) -> Void) {
        DispatchQueue.main.async { reply(Self.watcher.park(token: token)) }
    }

    @objc func restoreNotification(_ token: String) {
        DispatchQueue.main.async { Self.watcher.restore(token: token) }
    }

    @objc func pressNotification(_ token: String, with reply: @escaping (Bool) -> Void) {
        DispatchQueue.main.async { reply(Self.watcher.press(token: token)) }
    }

    @objc func performNotificationAction(_ token: String, label: String, with reply: @escaping (Bool) -> Void) {
        DispatchQueue.main.async { reply(Self.watcher.perform(token: token, action: label)) }
    }

    @objc func reofferNotificationAlerts() {
        DispatchQueue.main.async { Self.watcher.reofferAlerts() }
    }

    @objc func restoreStrandedNotifications() {
        DispatchQueue.main.async { Self.watcher.restoreStranded() }
    }

    /// The app quit or crashed. Stop at once: the open transaction keeps the helper alive just long
    /// enough to put back whatever is parked.
    static func appConnectionDidInvalidate() {
        DispatchQueue.main.async { stopWatching() }
    }

    private static func stopWatching() {
        watcher.stop()
        if holdsWatchingTransaction {
            xpc_transaction_end()
            holdsWatchingTransaction = false
        }
    }

    // MARK: - Microphone

    /// Puts the default input back on the MacBook's own microphone if it's somewhere else. A Mac without one has nothing to keep.
    @objc func keepMicOnMacBook() {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var uid = "BuiltInMicrophoneDevice" as CFString
        var builtIn = kAudioObjectUnknown
        var current = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var translate = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var defaultInput = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let translated = withUnsafePointer(to: &uid) {
            AudioObjectGetPropertyData(system, &translate, UInt32(MemoryLayout<CFString>.size), $0, &size, &builtIn)
        }
        guard translated == noErr, builtIn != kAudioObjectUnknown,
              AudioObjectGetPropertyData(system, &defaultInput, 0, nil, &size, &current) == noErr,
              current != builtIn
        else { return }
        AudioObjectSetPropertyData(system, &defaultInput, 0, nil, size, &builtIn)
    }

    // MARK: - Output

    /// Sends the Mac's sound to the output device with this name, or without one to the MacBook's own speakers.
    @objc func setDefaultOutput(named name: String?) {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyDataSize(system, &devicesAddress, 0, nil, &size) == noErr else { return }
        var devices = [AudioObjectID](repeating: kAudioObjectUnknown, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &devicesAddress, 0, nil, &size, &devices) == noErr else { return }

        let target = devices.first { device in
            // AirPods can also be a microphone by the same name, which isn't the one to pick
            var streams = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            var streamsSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(device, &streams, 0, nil, &streamsSize) == noErr, streamsSize > 0 else { return false }

            if let name {
                var nameAddress = AudioObjectPropertyAddress(
                    mSelector: kAudioObjectPropertyName,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                var deviceName: Unmanaged<CFString>?
                var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
                guard AudioObjectGetPropertyData(device, &nameAddress, 0, nil, &nameSize, &deviceName) == noErr else { return false }
                return deviceName?.takeRetainedValue() as String? == name
            }
            var transportAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyTransportType,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var transport: UInt32 = 0
            var transportSize = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(device, &transportAddress, 0, nil, &transportSize, &transport) == noErr else { return false }
            return transport == kAudioDeviceTransportTypeBuiltIn
        }
        guard var target else { return }

        var defaultOutput = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectSetPropertyData(system, &defaultOutput, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &target)
        announceManualOutput(target)
    }

    /// With AirPods in the ears, macOS takes the sound back to them as soon as any app starts playing, and sound
    /// restarts on every change of output. It only leaves a choice alone that it has heard of, which is what Control
    /// Center tells it with this. On a macOS that doesn't know this any more, AirPods just win as they would anyway.
    private func announceManualOutput(_ device: AudioObjectID) {
        func string(_ selector: AudioObjectPropertySelector) -> String? {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var value: Unmanaged<CFString>?
            var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
            return value?.takeRetainedValue() as String?
        }
        guard let uid = string(kAudioDevicePropertyDeviceUID), let name = string(kAudioObjectPropertyName) else { return }
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("com.apple.controlcenter.systemAudioDeviceSelected"),
            object: nil,
            userInfo: ["uid": uid, "name": name, "audioDevice": "output", "source": "ControlCenter"],
            deliverImmediately: true
        )
    }

    // MARK: - Keyboard Brightness

    private class KeyboardBrightnessClient {
        private static let keyboardID: UInt64 = 1
        private var clientInstance: NSObject?
        private let getSelector = NSSelectorFromString("brightnessForKeyboard:")
        private let setSelector = NSSelectorFromString("setBrightness:forKeyboard:")

        init() {
            var loaded = false
            let bundlePaths = [
                "/System/Library/PrivateFrameworks/CoreBrightness.framework",
                "/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness"
            ]
            for path in bundlePaths where !loaded {
                if let bundle = Bundle(path: path) {
                    loaded = bundle.load()
                }
            }
            if loaded, let cls = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type {
                clientInstance = cls.init()
            }
        }

        func currentBrightness() -> Float? {
            guard let clientInstance,
                  let fn: BrightnessGetter = methodIMP(on: clientInstance, selector: getSelector, as: BrightnessGetter.self)
            else { return nil }
            return fn(clientInstance, getSelector, Self.keyboardID)
        }

        func setBrightness(_ value: Float) -> Bool {
            guard let clientInstance,
                  let fn: BrightnessSetter = methodIMP(on: clientInstance, selector: setSelector, as: BrightnessSetter.self)
            else { return false }
            return fn(clientInstance, setSelector, value, Self.keyboardID).boolValue
        }

        private typealias BrightnessGetter = @convention(c) (NSObject, Selector, UInt64) -> Float
        private typealias BrightnessSetter = @convention(c) (NSObject, Selector, Float, UInt64) -> ObjCBool

        private func methodIMP<T>(on object: NSObject, selector: Selector, as type: T.Type) -> T? {
            guard let cls = object_getClass(object),
                  let method = class_getInstanceMethod(cls, selector)
            else { return nil }
            let imp = method_getImplementation(method)
            return unsafeBitCast(imp, to: type)
        }
    }

    private static let keyboardClient = KeyboardBrightnessClient()

    @objc func currentKeyboardBrightness(with reply: @escaping (NSNumber?) -> Void) {
        reply(Self.keyboardClient.currentBrightness().map { NSNumber(value: $0) })
    }

    @objc func setKeyboardBrightness(_ value: Float, with reply: @escaping (Bool) -> Void) {
        reply(Self.keyboardClient.setBrightness(value))
    }
    // MARK: - Screen Brightness (moved from client app into helper)

    @objc func currentScreenBrightness(with reply: @escaping (NSNumber?) -> Void) {
        var b: Float = 0
        if displayServicesGetBrightness(displayID: CGMainDisplayID(), out: &b) {
            reply(NSNumber(value: b))
            return
        }
        if let io = ioServiceFor(displayID: CGMainDisplayID()) {
            var level: Float = 0
            if IODisplayGetFloatParameter(io, 0, kIODisplayBrightnessKey as CFString, &level) == kIOReturnSuccess {
                IOObjectRelease(io)
                reply(NSNumber(value: level))
                return
            }
            IOObjectRelease(io)
        }
        reply(nil)
    }

    @objc func setScreenBrightness(_ value: Float, with reply: @escaping (Bool) -> Void) {
        let clamped = max(0, min(1, value))
        if displayServicesSetBrightness(displayID: CGMainDisplayID(), value: clamped) {
            reply(true)
            return
        }
        if let io = ioServiceFor(displayID: CGMainDisplayID()) {
            let ok = IODisplaySetFloatParameter(io, 0, kIODisplayBrightnessKey as CFString, clamped) == kIOReturnSuccess
            IOObjectRelease(io)
            reply(ok)
            return
        }
        reply(false)
    }

    // MARK: - Private helpers for DisplayServices / IOKit access
    private func displayServicesGetBrightness(displayID: CGDirectDisplayID, out: inout Float) -> Bool {
        guard let sym = dlsym(DisplayServicesHandle.handle, "DisplayServicesGetBrightness") else { return false }
        typealias Fn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
        let fn = unsafeBitCast(sym, to: Fn.self)
        var tmp: Float = 0
        let r = fn(displayID, &tmp)
        if r == 0 { out = tmp; return true }
        return false
    }

    private func displayServicesSetBrightness(displayID: CGDirectDisplayID, value: Float) -> Bool {
        guard let sym = dlsym(DisplayServicesHandle.handle, "DisplayServicesSetBrightness") else { return false }
        typealias Fn = @convention(c) (CGDirectDisplayID, Float) -> Int32
        let fn = unsafeBitCast(sym, to: Fn.self)
        return fn(displayID, value) == 0
    }

    private func ioServiceFor(displayID: CGDirectDisplayID) -> io_service_t? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IODisplayConnect"), &iterator) == kIOReturnSuccess else { return nil }
        defer { IOObjectRelease(iterator) }

        while case let service = IOIteratorNext(iterator), service != 0 {
            let info = IODisplayCreateInfoDictionary(service, 0).takeRetainedValue() as NSDictionary
            if let vendorID = info[kDisplayVendorID] as? UInt32,
               let productID = info[kDisplayProductID] as? UInt32,
               vendorID == CGDisplayVendorNumber(displayID),
               productID == CGDisplayModelNumber(displayID) {
                return service
            }
            IOObjectRelease(service)
        }
        return nil
    }

    // MARK: - Helper handle for private framework
    private enum DisplayServicesHandle {
        static let handle: UnsafeMutableRawPointer? = {
            let paths = [
                "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
                "/System/Library/PrivateFrameworks/DisplayServices.framework/Versions/Current/DisplayServices"
            ]
            for p in paths {
                if let h = dlopen(p, RTLD_LAZY) { return h }
            }
            return nil
        }()
    }
}
