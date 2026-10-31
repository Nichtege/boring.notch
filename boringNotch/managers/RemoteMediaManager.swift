//
//  RemoteMediaManager.swift
//  boringNotch
//
//  What other devices play, for the Devices tab and the tile in Control Center.
//

import Combine
import Defaults
import Foundation
import WidgetKit

final class RemoteMediaManager: ObservableObject {
    static let shared = RemoteMediaManager()

    @Published private(set) var devices: [RemoteNowPlaying] = []
    /// What was picked in the Devices tab, nil for this Mac. Stays while the device is away, as an iPhone that
    /// pauses goes away for a while, and it should show again when it's back. Also over a restart of this app.
    @Published private(set) var selected = Defaults[.selectedMediaDevice]
    /// Says the notch's close gesture should leave a scroll in the list alone
    var scrolls = false

    private let controller = RemoteNowPlayingController()
    private var cancellables = Set<AnyCancellable>()
    private var lastControlTile: [String]?

    private init() {
        controller.$devices
            .receive(on: DispatchQueue.main)
            .sink { [weak self] devices in
                self?.devices = devices
                self?.showSelected()
                self?.updateControlTile()
            }
            .store(in: &cancellables)

        Publishers.Merge(
            MusicManager.shared.$musicState.map { _ in () },
            MusicOutputController.shared.$devices.map { _ in () }
        )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.updateControlTile()
            }
            .store(in: &cancellables)

        Task { @MainActor in
            await MusicOutputController.shared.refresh()
        }
    }

    private var speakersInReach: [MusicOutputDevice] {
        MusicOutputController.shared.devices.filter { $0.kind != "computer" && $0.kind != "Bluetooth device" }
    }

    private func isSpeaker(_ device: RemoteNowPlaying) -> Bool {
        RemoteNowPlaying.iconName(for: device.deviceName) == RemoteNowPlaying.iconName(for: "")
    }

    /// Where an iPhone's sound comes out. macOS won't say to this app, but it only knows an iPhone at all while that
    /// plays to a speaker: its own name for the connection is "iPhone → speaker". So with one speaker in reach it's
    /// that one. With more it can't be told, and then this is nil.
    func speaker(of device: RemoteNowPlaying) -> MusicOutputDevice? {
        guard !isSpeaker(device) else { return nil }
        let speakers = speakersInReach
        return speakers.count == 1 ? speakers.first : nil
    }

    /// The speaker Music plays on. What it sends there comes back as that speaker's own entry, as the same song,
    /// and that can be there before Music says it has switched.
    var musicSpeaker: String? {
        if let selected = MusicOutputController.shared.selectedDevices.first(where: { $0.kind != "computer" && $0.kind != "Bluetooth device" }) {
            return selected.name
        }
        let music = MusicManager.shared
        guard music.musicHasContent else { return nil }
        return devices.first { isSpeaker($0) && $0.state.title == music.musicTitle && $0.state.artist == music.musicArtist }?.deviceName
    }

    /// What the Devices tab lists. A speaker plays one thing at a time, but when the sound moves to another source
    /// macOS keeps telling of the old one for some seconds. So with one speaker, it's what plays and changed last.
    var listedDevices: [RemoteNowPlaying] {
        guard speakersInReach.count == 1 else { return devices }
        let music = MusicManager.shared
        let current = devices.max { one, other in
            if one.state.isPlaying != other.state.isPlaying { return other.state.isPlaying }
            return one.state.lastUpdated < other.state.lastUpdated
        }
        // Music on the speaker takes it from an iPhone, unless that has started since
        if let current, !isSpeaker(current), music.musicIsPlaying, musicSpeaker != nil, current.state.lastUpdated < music.musicLastUpdated {
            return []
        }
        return current.map { [$0] } ?? []
    }

    func select(_ deviceName: String?) {
        selected = deviceName
        Defaults[.selectedMediaDevice] = deviceName
        showSelected()
    }

    /// Only ever from the main thread: the list, or the updates above that are delivered there.
    private func showSelected() {
        let device = devices.first { $0.deviceName == selected }
        MainActor.assumeIsolated {
            MusicManager.shared.show(remote: device)
        }
    }

    func send(_ command: RemoteNowPlayingController.Command, to device: String) {
        controller.send(command, to: device)
    }

    func refresh() {
        controller.refresh()
    }

    /// The tile is its own process. It only gets to know what plays, and only while it does.
    private func updateControlTile() {
        let music = MusicManager.shared
        var tile: [String]?
        if music.musicIsPlaying {
            tile = [music.musicTitle, musicSpeaker ?? "Mac", musicSpeaker == nil ? "laptopcomputer" : "homepod.fill"]
        } else if let playing = listedDevices.first(where: \.state.isPlaying) {
            let speaker = speaker(of: playing)
            tile = [
                playing.state.title,
                speaker?.name ?? playing.deviceName,
                speaker?.iconName ?? RemoteNowPlaying.iconName(for: playing.deviceName),
            ]
        }
        guard tile != lastControlTile else { return }
        lastControlTile = tile

        let shared = UserDefaults(suiteName: "MC8NLUCW46.com.nichtege.boringnotch")
        shared?.set(tile?[0], forKey: "mediaTileTitle")
        shared?.set(tile?[1], forKey: "mediaTileDevice")
        shared?.set(tile?[2], forKey: "mediaTileIcon")
        ControlCenter.shared.reloadControls(ofKind: "com.nichtege.boringnotch.media")
    }
}
