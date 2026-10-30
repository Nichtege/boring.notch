//
//  MusicOutputController.swift
//  boringNotch
//
//  Shows and changes the AirPlay output of the Music app.
//

import AppKit
import Combine
import CoreAudio
import Defaults

/// Where sound on this Mac really goes. The Music app only knows "this Mac", and a per-app audio router
/// such as FineTune moves its sound to another device without Music noticing.
enum LocalAudioRoute {
    struct Route: Equatable {
        let name: String
        let transport: UInt32

        var isBuiltIn: Bool {
            transport == kAudioDeviceTransportTypeBuiltIn
        }

        var iconName: String {
            switch transport {
            case kAudioDeviceTransportTypeBuiltIn:
                return "macbook"
            case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
                return LocalAudioRoute.bluetoothIcon(for: name)
            case kAudioDeviceTransportTypeAirPlay:
                return "airplayaudio"
            case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort:
                return "tv.fill"
            default:
                return "hifispeaker.fill"
            }
        }
    }

    private static let routerBundleIDs: Set<String> = ["com.finetuneapp.FineTune"]

    static func bluetoothIcon(for name: String) -> String {
        if name.localizedCaseInsensitiveContains("AirPods Pro") { return "airpodspro" }
        if name.localizedCaseInsensitiveContains("AirPods Max") { return "airpodsmax" }
        if name.localizedCaseInsensitiveContains("AirPods") { return "airpods" }
        return "headphones"
    }

    /// Where an app's sound comes out right now. nil while it isn't playing anything.
    static func route(for bundleID: String) -> Route? {
        guard #available(macOS 14.2, *) else { return nil }

        var appDevice: AudioObjectID?
        var routerDevice: AudioObjectID?
        for process in objects(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList) {
            guard number(process, kAudioProcessPropertyIsRunningOutput) != 0,
                  let processBundleID = string(process, kAudioProcessPropertyBundleID) else { continue }
            let device = objects(process, kAudioProcessPropertyDevices, scope: kAudioDevicePropertyScopeOutput).first
            if processBundleID == bundleID {
                appDevice = device
            } else if routerBundleIDs.contains(processBundleID) {
                routerDevice = device
            }
        }
        // A router only counts while the app itself is playing, otherwise it may be busy with another app
        guard let appDevice else { return nil }
        return route(of: routerDevice ?? appDevice)
    }

    /// The audio objects of an app's processes.
    static func processes(for bundleID: String) -> [AudioObjectID] {
        guard #available(macOS 14.2, *) else { return [] }
        return objects(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList).filter {
            string($0, kAudioProcessPropertyBundleID) == bundleID
        }
    }

    static var systemOutput: Route? {
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = propertyAddress(kAudioHardwarePropertyDefaultOutputDevice)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { return nil }
        return route(of: device)
    }

    private static func route(of device: AudioObjectID) -> Route? {
        guard let name = string(device, kAudioObjectPropertyName) else { return nil }
        return Route(name: name, transport: number(device, kAudioDevicePropertyTransportType))
    }

    private static func propertyAddress(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func objects(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var address = propertyAddress(selector, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var result = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &result) == noErr else { return [] }
        return result
    }

    private static func number(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32 {
        var address = propertyAddress(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        return value
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = propertyAddress(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}

struct MusicOutputDevice: Identifiable, Equatable {
    let name: String
    let kind: String
    let isSelected: Bool
    /// Set on the "this Mac" entry when its sound really comes out of another device.
    var localRoute: LocalAudioRoute.Route? = nil

    var id: String { name }

    var displayName: String {
        localRoute?.name ?? (kind == "computer" ? "MacBook" : name)
    }

    var iconName: String {
        if let localRoute {
            return localRoute.iconName
        }
        switch kind {
        case "computer":
            return "macbook"
        case "HomePod":
            return "homepod.fill"
        case "Apple TV":
            return "appletv.fill"
        case "TV":
            return "tv.fill"
        case "Bluetooth device":
            return LocalAudioRoute.bluetoothIcon(for: name)
        default:
            return "airplayaudio"
        }
    }
}

final class MusicOutputController: ObservableObject {
    static let shared = MusicOutputController()

    @Published private(set) var devices: [MusicOutputDevice] = []

    // Music keeps the old device selected for a few seconds after a switch
    private let switchSettleTime: TimeInterval = 15
    private var ignoreSelectionUntil: Date = .distantPast
    private var notificationTask: Task<Void, Never>?
    // A paused app has no sound to follow, so the last place it went still counts
    private var lastLocalRoute: LocalAudioRoute.Route?

    var selectedDevices: [MusicOutputDevice] {
        devices.filter(\.isSelected)
    }

    private var isMusicRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").isEmpty
    }

    private init() {
        notificationTask = Task { @Sendable [weak self] in
            let notifications = DistributedNotificationCenter.default().notifications(
                named: NSNotification.Name("com.apple.Music.playerInfo")
            )

            for await notification in notifications {
                guard notification.userInfo?["Player State"] as? String == "Paused" else { continue }
                await self?.rememberCurrentOutput()
            }
        }
    }

    deinit {
        notificationTask?.cancel()
    }

    // MARK: - Public Methods
    @MainActor
    func refresh() async {
        guard Date() >= ignoreSelectionUntil else { return }
        devices = showingLocalRoute(in: await fetchDevices() ?? [])
    }

    /// Music says "this Mac", so what the Mac does with the sound decides where it really goes.
    private func showingLocalRoute(in devices: [MusicOutputDevice]) -> [MusicOutputDevice] {
        let selected = devices.filter(\.isSelected)
        guard selected.count == 1, selected[0].kind == "computer" else { return devices }

        if let route = LocalAudioRoute.route(for: "com.apple.Music") {
            lastLocalRoute = route
        }
        guard let route = lastLocalRoute ?? LocalAudioRoute.systemOutput, !route.isBuiltIn else { return devices }

        // Music may list that device too. Then that entry is the one to mark
        if devices.contains(where: { $0.kind != "computer" && $0.name == route.name }) {
            return devices.map {
                MusicOutputDevice(name: $0.name, kind: $0.kind, isSelected: $0.name == route.name)
            }
        }
        return devices.map {
            $0.kind == "computer" ? MusicOutputDevice(name: $0.name, kind: $0.kind, isSelected: true, localRoute: route) : $0
        }
    }

    @MainActor
    func select(_ device: MusicOutputDevice) async {
        ignoreSelectionUntil = Date().addingTimeInterval(switchSettleTime)
        Defaults[.lastMusicOutputDevices] = [device.name]
        devices = devices.map {
            MusicOutputDevice(name: $0.name, kind: $0.kind, isSelected: $0.name == device.name)
        }
        await setOutput(to: [device.name])
    }

    /// Moves playback back to the device it was paused on, if Music has changed it since.
    @MainActor
    func restoreLastOutput() async {
        let remembered = Defaults[.lastMusicOutputDevices]
        guard !remembered.isEmpty, let current = await fetchDevices() else { return }

        let available = Set(current.map(\.name))
        let target = remembered.filter { available.contains($0) }
        let selected = Set(current.filter(\.isSelected).map(\.name))
        guard !target.isEmpty, Set(target) != selected else { return }

        ignoreSelectionUntil = Date().addingTimeInterval(switchSettleTime)
        devices = current.map {
            MusicOutputDevice(name: $0.name, kind: $0.kind, isSelected: target.contains($0.name))
        }
        await setOutput(to: target)
    }

    // MARK: - Private Methods
    @MainActor
    private func rememberCurrentOutput() async {
        guard Date() >= ignoreSelectionUntil, let current = await fetchDevices() else { return }
        let selected = current.filter(\.isSelected).map(\.name)
        if !selected.isEmpty {
            Defaults[.lastMusicOutputDevices] = selected
        }
    }

    private func fetchDevices() async -> [MusicOutputDevice]? {
        guard isMusicRunning else { return nil }

        let script = """
        tell application "Music"
            set deviceList to {}
            repeat with outputDevice in (every AirPlay device whose available is true)
                set end of deviceList to {name of outputDevice, (kind of outputDevice) as text, selected of outputDevice}
            end repeat
            return deviceList
        end tell
        """
        guard let descriptor = try? await AppleScriptHelper.execute(script) else { return nil }
        guard descriptor.numberOfItems > 0 else { return [] }

        return (1...descriptor.numberOfItems).compactMap { index in
            guard let item = descriptor.atIndex(index),
                  let name = item.atIndex(1)?.stringValue,
                  let kind = item.atIndex(2)?.stringValue else { return nil }
            return MusicOutputDevice(name: name, kind: kind, isSelected: item.atIndex(3)?.booleanValue ?? false)
        }
    }

    private func setOutput(to names: [String]) async {
        guard isMusicRunning else { return }

        let deviceList = names.map { name in
            let escaped = name
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "AirPlay device \"\(escaped)\""
        }.joined(separator: ", ")

        let script = """
        tell application "Music"
            set wasPlaying to player state is playing
            set current AirPlay devices to {\(deviceList)}
            if wasPlaying then play
        end tell
        """
        try? await AppleScriptHelper.executeVoid(script)
    }
}
