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

/// Where sound on this Mac really goes. The Music app only knows "this Mac", and with AirPods as the
/// default output it says the same.
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

    static func bluetoothIcon(for name: String) -> String {
        if name.localizedCaseInsensitiveContains("AirPods Pro") { return "airpodspro" }
        if name.localizedCaseInsensitiveContains("AirPods Max") { return "airpodsmax" }
        if name.localizedCaseInsensitiveContains("AirPods") { return "airpods" }
        return "headphones"
    }

    /// The audio objects of an app's processes.
    static func processes(for bundleID: String) -> [AudioObjectID] {
        objects(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList).filter {
            string($0, kAudioProcessPropertyBundleID) == bundleID
        }
    }

    static var systemOutput: Route? {
        route(of: defaultOutputDevice)
    }

    static var defaultOutputDevice: AudioObjectID {
        number(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice)
    }

    static func sampleRate(of device: AudioObjectID) -> Float64 {
        var address = propertyAddress(kAudioDevicePropertyNominalSampleRate)
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate)
        return rate
    }

    private static func route(of device: AudioObjectID) -> Route? {
        guard let name = string(device, kAudioObjectPropertyName) else { return nil }
        return Route(name: name, transport: number(device, kAudioDevicePropertyTransportType))
    }

    static func propertyAddress(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func objects(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> [AudioObjectID] {
        var address = propertyAddress(selector, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var result = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &result) == noErr else { return [] }
        return result
    }

    static func number(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32 {
        var address = propertyAddress(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        return value
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
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
    /// Set on paired AirPods that Music doesn't list. Choosing them connects them.
    var bluetoothAddress: String? = nil

    var id: String { bluetoothAddress ?? name }

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
    @Published private var pairedAirPods: [MusicOutputDevice] = []

    // Music keeps the old device selected for a few seconds after a switch
    private let switchSettleTime: TimeInterval = 15
    private var ignoreSelectionUntil: Date = .distantPast
    private var notificationTask: Task<Void, Never>?

    var selectedDevices: [MusicOutputDevice] {
        devices.filter(\.isSelected)
    }

    /// What the picker offers: Music's list, and paired AirPods it can't have because they aren't connected.
    var pickerDevices: [MusicOutputDevice] {
        devices + pairedAirPods.filter { airPods in
            !devices.contains { $0.name == airPods.name || $0.localRoute?.name == airPods.name }
        }
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

    // MARK: - Public Methods
    @MainActor
    func refresh() async {
        guard Date() >= ignoreSelectionUntil else { return }
        // No answer from Music isn't an empty list, and the button would go away with it
        guard let fetched = await fetchDevices() else {
            if !isMusicRunning {
                devices = []
            }
            return
        }
        devices = showingLocalRoute(in: fetched)
    }

    @MainActor
    func refreshPairedAirPods() async {
        pairedAirPods = await XPCHelperClient.shared.pairedAirPods().compactMap { entry in
            guard let name = entry["name"], let address = entry["address"] else { return nil }
            return MusicOutputDevice(name: name, kind: "Bluetooth device", isSelected: false, bluetoothAddress: address)
        }
    }

    /// Music says "this Mac", so what the Mac does with the sound decides where it really goes.
    private func showingLocalRoute(in devices: [MusicOutputDevice]) -> [MusicOutputDevice] {
        let selected = devices.filter(\.isSelected)
        guard selected.count == 1, selected[0].kind == "computer",
              let route = LocalAudioRoute.systemOutput, !route.isBuiltIn else { return devices }

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
        if let address = device.bluetoothAddress {
            await connectAirPods(address)
            return
        }
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
    /// macOS makes them the default output once they're connected, which Music only follows from "this Mac".
    /// If they can't connect (in their case, say) nothing changes and nothing is said.
    @MainActor
    private func connectAirPods(_ address: String) async {
        guard await XPCHelperClient.shared.connectAirPods(address) else { return }
        if let computer = devices.first(where: { $0.kind == "computer" }), !computer.isSelected {
            await select(computer)
        }
    }

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
