//
//  RemoteMediaManager.swift
//  boringNotch
//
//  What other devices play, for the Sound tab and the tile in Control Center.
//

import Combine
import Defaults
import Foundation
import Network
import WidgetKit

final class RemoteMediaManager: ObservableObject {
    static let shared = RemoteMediaManager()

    @Published private(set) var devices: [RemoteNowPlaying] = []
    /// What was picked in the Sound tab, nil for this Mac. Stays while the device is away, as an iPhone that
    /// pauses goes away for a while, and it should show again when it's back. Also over a restart of this app.
    /// Music starting on this Mac clears it.
    @Published private(set) var selected = Defaults[.selectedMediaDevice]
    /// Says the notch's close gesture should leave a scroll in the list alone
    var scrolls = false
    /// The volume of the speaker the shown device plays on, from 0 to 1. Nil while it isn't known, and then the
    /// player has no slider for it.
    @Published private(set) var speakerVolume: Double?

    private let controller = RemoteNowPlayingController()
    private let speakerIDs = SpeakerIDs()
    /// The speaker `speakerVolume` belongs to
    private var volumeSpeaker: String?
    private var lastVolumeSet = Date.distantPast
    private var cancellables = Set<AnyCancellable>()
    private var lastControlTile: [String]?

    private init() {
        controller.$devices
            .receive(on: DispatchQueue.main)
            .sink { [weak self] devices in
                self?.devicesChanged(devices)
            }
            .store(in: &cancellables)

        controller.speakerVolumes
            .receive(on: DispatchQueue.main)
            .sink { [weak self] answer in
                guard let self, answer.speaker == self.volumeSpeaker else { return }
                // An answer asked for before the slider moved would put it back for a moment
                if answer.volume != nil && Date().timeIntervalSince(self.lastVolumeSet) < 1.5 { return }
                self.speakerVolume = answer.volume
            }
            .store(in: &cancellables)

        // The IDs come a moment after the search starts
        speakerIDs.onChange = { [weak self] in
            guard let self, self.volumeSpeaker == nil, MusicManager.shared.remoteDevice != nil else { return }
            self.refreshSpeakerVolume()
        }

        Publishers.Merge(
            MusicManager.shared.$musicState.map { _ in () },
            MusicOutputController.shared.$devices.map { _ in () }
        )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.updateControlTile()
            }
            .store(in: &cancellables)

        MusicManager.shared.$remoteDevice
            .map { $0 != nil }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { isShown in
                PlayKeyInterceptor.shared.setActive(isShown)
            }
            .store(in: &cancellables)

        Task { @MainActor in
            await MusicOutputController.shared.refresh()
        }
    }

    private var speakersInReach: [MusicOutputDevice] {
        MusicOutputController.shared.devices.filter(\.isSpeaker)
    }

    /// Where an iPhone's sound comes out. macOS won't say to this app, but it only knows an iPhone at all while that
    /// plays to a speaker: its own name for the connection is "iPhone → speaker". So with one speaker in reach it's
    /// that one. With more it can't be told, and then this is nil.
    func speaker(of device: RemoteNowPlaying) -> MusicOutputDevice? {
        guard device.isPhone else { return nil }
        let speakers = speakersInReach
        return speakers.count == 1 ? speakers.first : nil
    }

    /// The name to show for where a device plays.
    func outputName(of device: RemoteNowPlaying) -> String {
        speaker(of: device)?.name ?? device.deviceName
    }

    func outputIconName(of device: RemoteNowPlaying) -> String {
        speaker(of: device)?.iconName ?? device.iconName
    }

    /// The speaker Music plays on. What it sends there comes back as that speaker's own entry, as the same song,
    /// and that can be there before Music says it has switched.
    var musicSpeaker: String? {
        if let selected = MusicOutputController.shared.selectedDevices.first(where: \.isSpeaker) {
            return selected.name
        }
        let music = MusicManager.shared
        guard music.musicHasContent else { return nil }
        return devices.first { !$0.isPhone && $0.state.title == music.musicTitle && $0.state.artist == music.musicArtist }?.deviceName
    }

    /// What the Sound tab lists. A speaker plays one thing at a time, but when the sound moves to another source
    /// macOS keeps telling of the old one for some seconds. So with one speaker, it's what plays and changed last.
    var listedDevices: [RemoteNowPlaying] {
        guard speakersInReach.count == 1 else { return devices }
        let music = MusicManager.shared
        let current = devices.max { one, other in
            if one.state.isPlaying != other.state.isPlaying { return other.state.isPlaying }
            return one.state.lastUpdated < other.state.lastUpdated
        }
        // Music on the speaker takes it from an iPhone, unless that has started since
        if let current, current.isPhone, music.musicIsPlaying, musicSpeaker != nil, current.state.lastUpdated < music.musicLastUpdated {
            return []
        }
        return current.map { [$0] } ?? []
    }

    private func devicesChanged(_ newDevices: [RemoteNowPlaying]) {
        let wasPlaying = devices.first { $0.deviceName == selected }?.state.isPlaying == true
        devices = newDevices
        let isPlaying = devices.first { $0.deviceName == selected }?.state.isPlaying == true
        // When what was picked stops, what comes from this Mac takes over. Only then: it can be picked while paused
        if wasPlaying && !isPlaying && MusicManager.shared.musicIsPlaying {
            select(nil)
        } else {
            showSelected()
        }
        updateControlTile()
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

    /// Where the shown device's sound comes out: the speaker an iPhone plays on, or a speaker playing by itself.
    private func speakerID(of device: RemoteNowPlaying) -> String? {
        let name = device.isPhone ? speaker(of: device)?.name : device.deviceName
        return name.flatMap { speakerIDs.ids[$0] }
    }

    /// For when the player shows another device. The first time, macOS asks to allow finding devices in the network.
    func refreshSpeakerVolume() {
        speakerIDs.start()
        guard let device = MusicManager.shared.remoteDevice, let speaker = speakerID(of: device) else {
            volumeSpeaker = nil
            speakerVolume = nil
            return
        }
        if speaker != volumeSpeaker {
            volumeSpeaker = speaker
            speakerVolume = nil
        }
        controller.readVolume(ofSpeaker: speaker)
    }

    func setSpeakerVolume(_ level: Double) {
        guard let volumeSpeaker else { return }
        lastVolumeSet = Date()
        speakerVolume = level
        controller.setVolume(level, ofSpeaker: volumeSpeaker)
    }

    /// The tile is its own process. It only gets to know what plays, and only while it does.
    private func updateControlTile() {
        let music = MusicManager.shared
        var tile: [String]?
        if music.musicIsPlaying {
            tile = [music.musicTitle, musicSpeaker ?? "Mac", musicSpeaker == nil ? "laptopcomputer" : "homepod.fill"]
        } else if let playing = listedDevices.first(where: \.state.isPlaying) {
            tile = [playing.state.title, outputName(of: playing), outputIconName(of: playing)]
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

/// The ID macOS knows each speaker by. Music gives only names, and the ID is in the speaker's AirPlay announcement
/// in the local network. It's looked for from the first time it's needed, and only names and IDs are kept.
private final class SpeakerIDs {
    /// Name → ID
    private(set) var ids: [String: String] = [:]
    var onChange: (() -> Void)?

    private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_airplay._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            var ids: [String: String] = [:]
            for result in results {
                guard case let .service(name, _, _, _) = result.endpoint,
                      case let .bonjour(record) = result.metadata,
                      let id = record["psi"] else { continue }
                ids[name] = id
            }
            guard let self, ids != self.ids else { return }
            self.ids = ids
            self.onChange?()
        }
        browser.start(queue: .main)
        self.browser = browser
    }
}
