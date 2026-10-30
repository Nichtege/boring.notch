//
//  MusicOutputController.swift
//  boringNotch
//
//  Shows and changes the AirPlay output of the Music app.
//

import AppKit
import Combine
import Defaults

struct MusicOutputDevice: Identifiable, Equatable {
    let name: String
    let kind: String
    let isSelected: Bool

    var id: String { name }

    var displayName: String {
        kind == "computer" ? "MacBook" : name
    }

    var iconName: String {
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
            return "headphones"
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
        devices = await fetchDevices() ?? []
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
