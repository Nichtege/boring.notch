//
//  RemoteMediaManager.swift
//  boringNotch
//
//  What other devices play, for the Devices tab and the tile in Control Center.
//

import Combine
import Foundation
import WidgetKit

final class RemoteMediaManager: ObservableObject {
    static let shared = RemoteMediaManager()

    @Published private(set) var devices: [RemoteNowPlaying] = []
    /// What was picked in the Devices tab, nil for this Mac. Stays while the device is away, as an iPhone that
    /// pauses goes away for a while, and it should show again when it's back.
    @Published private(set) var selected: String?
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

        let music = MusicManager.shared
        Publishers.Merge(music.$isPlaying.map { _ in () }, music.$songTitle.map { _ in () })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.updateControlTile()
            }
            .store(in: &cancellables)
    }

    func select(_ deviceName: String?) {
        selected = deviceName
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
        if music.isPlaying {
            tile = [music.songTitle, "Mac", "laptopcomputer"]
        } else if let playing = devices.first(where: \.state.isPlaying) {
            tile = [playing.state.title, playing.deviceName, RemoteNowPlaying.iconName(for: playing.deviceName)]
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
