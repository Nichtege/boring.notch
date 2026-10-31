//
//  MusicManager.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 03/08/24.
//
import AppKit
import Combine
import Defaults
import SwiftUI
import WidgetKit

let defaultImage: NSImage = .init(
    systemSymbolName: "heart.fill",
    accessibilityDescription: "Album Art"
)!

class MusicManager: ObservableObject {
    // MARK: - Properties
    static let shared = MusicManager()
    private var cancellables = Set<AnyCancellable>()
    private var debounceIdleTask: Task<Void, Never>?

    private let controller = AppleMusicController()
    private let remote = RemoteNowPlayingController()
    private var shownRemote: String?
    private var lastControlTile: [String]?
    private var pendingVolume: Double?
    private var volumeTask: Task<Void, Never>?

    // Published properties for UI
    @Published var songTitle: String = "I'm Handsome"
    @Published var artistName: String = "Me"
    @Published var albumArt: NSImage = defaultImage
    @Published var isPlaying = false
    @Published var album: String = "Self Love"
    @Published var isPlayerIdle: Bool = true
    @Published var avgColor: NSColor = .white
    @Published var bundleIdentifier: String? = nil
    @Published var songDuration: TimeInterval = 0
    @Published var elapsedTime: TimeInterval = 0
    @Published var timestampDate: Date = .init()
    @Published var playbackRate: Double = 1
    @Published var isShuffled: Bool = false
    @Published var repeatMode: RepeatMode = .off
    @Published var volume: Double = 0.5
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @Published var usingAppIconForArtwork: Bool = false
    @Published var isFavoriteTrack: Bool = false
    /// The other device's name while what shows comes from there
    @Published private(set) var remoteName: String? = nil
    @Published private(set) var musicState: PlaybackState?
    @Published private(set) var remoteDevices: [RemoteNowPlaying] = []
    @Published var isDeviceListShown = false

    var isRemoteSource: Bool {
        remoteName != nil
    }

    private var artworkData: Data? = nil

    // Store last values at the time artwork was changed
    private var lastArtworkTitle: String = "I'm Handsome"
    private var lastArtworkArtist: String = "Me"
    private var lastArtworkAlbum: String = "Self Love"
    private var lastArtworkBundleIdentifier: String? = nil

    // MARK: - Initialization
    init() {
        // Start remembering the Music output so resuming from the notch can restore it
        _ = MusicOutputController.shared

        controller.playbackStatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.musicChanged(state)
            }
            .store(in: &cancellables)

        remote.$devices
            .receive(on: DispatchQueue.main)
            .sink { [weak self] devices in
                self?.remoteChanged(devices)
            }
            .store(in: &cancellables)
    }

    public func destroy() {
        debounceIdleTask?.cancel()
        cancellables.removeAll()
    }

    // MARK: - Update Methods
    /// What started last is what shows. When that stops, whatever else still plays takes over.
    @MainActor
    private func musicChanged(_ state: PlaybackState) {
        let started = state.isPlaying && musicState?.isPlaying != true
        musicState = state
        if started {
            shownRemote = nil
        } else if !state.isPlaying && shownRemote == nil {
            shownRemote = remoteDevices.first(where: \.state.isPlaying)?.deviceName
        }
        showCurrentSource()
    }

    @MainActor
    private func remoteChanged(_ devices: [RemoteNowPlaying]) {
        let started = devices.first { device in
            device.state.isPlaying && remoteDevices.first { $0.deviceName == device.deviceName }?.state.isPlaying != true
        }
        let shown = devices.first { $0.deviceName == shownRemote }
        remoteDevices = devices
        if let started {
            shownRemote = started.deviceName
        } else if shownRemote != nil && shown?.state.isPlaying != true {
            // A speaker's song from hours ago doesn't take over from anything that stops: only what plays does
            if musicState?.isPlaying == true {
                shownRemote = nil
            } else if let playing = devices.first(where: \.state.isPlaying) {
                shownRemote = playing.deviceName
            } else if shown == nil {
                shownRemote = nil
            }
        }
        showCurrentSource()
    }

    /// What the list says to show: another device, or nil for this Mac.
    @MainActor
    func show(_ deviceName: String?) {
        shownRemote = deviceName
        isDeviceListShown = false
        showCurrentSource()
    }

    func refreshRemoteDevices() {
        remote.refresh()
    }

    @MainActor
    private func showCurrentSource() {
        let shown = remoteDevices.first { $0.deviceName == shownRemote }
        if remoteName != shown?.deviceName {
            remoteName = shown?.deviceName
        }
        if let state = shown?.state ?? musicState {
            updateFromPlaybackState(state)
        }
        updateControlTile()
    }

    /// The tile in Control Center, which is its own process. It only gets to know what plays, and only while it does.
    @MainActor
    private func updateControlTile() {
        // What plays, also when the notch was told to show something else
        let device = remoteDevices.first { $0.deviceName == shownRemote && $0.state.isPlaying }
            ?? (musicState?.isPlaying == true ? nil : remoteDevices.first(where: \.state.isPlaying))
        let state = device?.state ?? musicState
        let tile = state?.isPlaying == true ? [
            state?.title ?? "",
            device?.deviceName ?? "Mac",
            device.map { RemoteNowPlaying.iconName(for: $0.deviceName) } ?? "laptopcomputer",
        ] : nil
        guard tile != lastControlTile else { return }
        lastControlTile = tile

        let shared = UserDefaults(suiteName: "MC8NLUCW46.com.nichtege.boringnotch")
        shared?.set(tile?[0], forKey: "mediaTileTitle")
        shared?.set(tile?[1], forKey: "mediaTileDevice")
        shared?.set(tile?[2], forKey: "mediaTileIcon")
        ControlCenter.shared.reloadControls(ofKind: "com.nichtege.boringnotch.media")
    }

    @MainActor
    private func updateFromPlaybackState(_ state: PlaybackState) {
        // Check for playback state changes (playing/paused)
        if state.isPlaying != self.isPlaying {
            NSLog("Playback state changed: \(state.isPlaying ? "Playing" : "Paused")")
            withAnimation(.smooth) {
                self.isPlaying = state.isPlaying
                self.updateIdleState(state: state.isPlaying)
            }

            if state.isPlaying && !state.title.isEmpty && !state.artist.isEmpty {
                self.updateSneakPeek()
            }
        }

        // Check for changes in track metadata using last artwork change values
        let titleChanged = state.title != self.lastArtworkTitle
        let artistChanged = state.artist != self.lastArtworkArtist
        let albumChanged = state.album != self.lastArtworkAlbum
        let bundleChanged = state.bundleIdentifier != self.lastArtworkBundleIdentifier

        // Check for artwork changes. Having none any more counts: that track shows the app icon, not the last cover
        let artworkChanged = state.artwork != self.artworkData
        let hasContentChange = titleChanged || artistChanged || albumChanged || artworkChanged || bundleChanged

        // Handle artwork and visual transitions for changed content
        if hasContentChange {
            if artworkChanged, let artwork = state.artwork {
                self.updateArtwork(artwork)
            } else if state.artwork == nil {
                // Try to use app icon if no artwork but track changed
                if let appIconImage = AppIconAsNSImage(for: state.bundleIdentifier) {
                    self.usingAppIconForArtwork = true
                    self.updateAlbumArt(newAlbumArt: appIconImage)
                } else {
                    // An app that's only on another device. The cover of the song before would be wrong
                    self.usingAppIconForArtwork = false
                    self.updateAlbumArt(newAlbumArt: defaultImage)
                }
            }
            self.artworkData = state.artwork

            // Update last artwork change values, also for a track with the same cover: it'd count as new on every publish
            self.lastArtworkTitle = state.title
            self.lastArtworkArtist = state.artist
            self.lastArtworkAlbum = state.album
            self.lastArtworkBundleIdentifier = state.bundleIdentifier

            // Only update sneak peek if there's actual content and something changed
            if !state.title.isEmpty && !state.artist.isEmpty && state.isPlaying {
                self.updateSneakPeek()
            }
        }

        let timeChanged = state.currentTime != self.elapsedTime
        let durationChanged = state.duration != self.songDuration
        let playbackRateChanged = state.playbackRate != self.playbackRate
        let shuffleChanged = state.isShuffled != self.isShuffled
        let repeatModeChanged = state.repeatMode != self.repeatMode
        let volumeChanged = state.volume != self.volume
        
        if state.title != self.songTitle {
            self.songTitle = state.title
        }

        if state.artist != self.artistName {
            self.artistName = state.artist
        }

        if state.album != self.album {
            self.album = state.album
        }

        if timeChanged {
            self.elapsedTime = state.currentTime
        }

        if durationChanged {
            self.songDuration = state.duration
        }

        if playbackRateChanged {
            self.playbackRate = state.playbackRate
        }
        
        if shuffleChanged {
            self.isShuffled = state.isShuffled
        }

        if state.bundleIdentifier != self.bundleIdentifier {
            self.bundleIdentifier = state.bundleIdentifier
        }

        if repeatModeChanged {
            self.repeatMode = state.repeatMode
        }
        if state.isFavorite != self.isFavoriteTrack {
            self.isFavoriteTrack = state.isFavorite
        }
        
        // With a newer volume on its way this is old news, and the slider would snap back to it
        if volumeChanged && volumeTask == nil {
            self.volume = state.volume
        }
        
        self.timestampDate = state.lastUpdated
    }

    func toggleFavoriteTrack() {
        // Toggle based on current state
        setFavorite(!isFavoriteTrack)
    }

    func setFavorite(_ favorite: Bool) {
        guard !isRemoteSource else { return }
        Task { @MainActor in
            await controller.setFavorite(favorite)
            try? await Task.sleep(for: .milliseconds(150))
            await controller.updatePlaybackInfo()
        }
    }

    private func updateArtwork(_ artworkData: Data) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            if let artworkImage = NSImage(data: artworkData) {
                DispatchQueue.main.async { [weak self] in
                    self?.usingAppIconForArtwork = false
                    self?.updateAlbumArt(newAlbumArt: artworkImage)
                }
            }
        }
    }

    private func updateIdleState(state: Bool) {
        if state {
            isPlayerIdle = false
            debounceIdleTask?.cancel()
        } else {
            debounceIdleTask?.cancel()
            debounceIdleTask = Task { [weak self] in
                guard let self = self else { return }
                try? await Task.sleep(for: .seconds(Defaults[.waitInterval]))
                withAnimation {
                    self.isPlayerIdle = !self.isPlaying
                }
            }
        }
    }

    func updateAlbumArt(newAlbumArt: NSImage) {
        withAnimation(.smooth) {
            self.albumArt = newAlbumArt
            if Defaults[.coloredSpectrogram] {
                self.calculateAverageColor()
            }
        }
    }

    // MARK: - Playback Position Estimation
    public func estimatedPlaybackPosition(at date: Date = Date()) -> TimeInterval {
        guard isPlaying else { return min(elapsedTime, songDuration) }

        let timeDifference = date.timeIntervalSince(timestampDate)
        let estimated = elapsedTime + (timeDifference * playbackRate)
        return min(max(0, estimated), songDuration)
    }

    func calculateAverageColor() {
        albumArt.averageColor { [weak self] color in
            DispatchQueue.main.async {
                withAnimation(.smooth) {
                    self?.avgColor = color ?? .white
                }
            }
        }
    }

    private func updateSneakPeek() {
        if isPlaying && Defaults[.enableSneakPeek] {
            if Defaults[.sneakPeekStyles] == .standard {
                coordinator.toggleSneakPeek(status: true, type: .music)
            } else {
                coordinator.toggleExpandingView(status: true, type: .music)
            }
        }
    }

    // MARK: - Public Methods for controlling playback
    func toggleShuffle() {
        guard !isRemoteSource else { return }
        Task {
            await controller.toggleShuffle()
        }
    }

    func toggleRepeat() {
        guard !isRemoteSource else { return }
        Task {
            await controller.toggleRepeat()
        }
    }

    func togglePlay() {
        togglePlay(on: remoteName)
    }

    /// nil for this Mac.
    func togglePlay(on deviceName: String?) {
        guard deviceName == nil else {
            remote.send(.toggle, to: deviceName)
            return
        }
        Task {
            if musicState?.isPlaying != true {
                await MusicOutputController.shared.restoreLastOutput()
            }
            await controller.togglePlay()
        }
    }

    func nextTrack() {
        guard !isRemoteSource else {
            remote.send(.next, to: remoteName)
            return
        }
        Task {
            await controller.nextTrack()
        }
    }

    func previousTrack() {
        guard !isRemoteSource else {
            remote.send(.previous, to: remoteName)
            return
        }
        Task {
            await controller.previousTrack()
        }
    }

    func seek(to position: TimeInterval) {
        guard !isRemoteSource else { return }
        Task {
            await controller.seek(to: position)
        }
    }
    func skip(seconds: TimeInterval) {
        guard !isRemoteSource else {
            remote.send(.skip(seconds: Int(seconds)), to: remoteName)
            return
        }
        let newPos = min(max(0, estimatedPlaybackPosition() + seconds), songDuration)
        seek(to: newPos)
    }
    
    /// Only the newest level. One script runs at a time and each can take 2 s, so a dragged slider would pile them up.
    @MainActor
    func setVolume(to level: Double) {
        guard !isRemoteSource else { return }
        pendingVolume = level
        guard volumeTask == nil else { return }
        volumeTask = Task { @MainActor [weak self] in
            while let self, let level = self.pendingVolume {
                self.pendingVolume = nil
                await self.controller.setVolume(level)
            }
            self?.volumeTask = nil
        }
    }

    func openMusicApp() {
        guard !isRemoteSource, let bundleID = bundleIdentifier,
              let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }

    func forceUpdate() {
        // Request immediate update from the controller
        Task {
            await controller.updatePlaybackInfo()
        }
    }
    
    
    func syncVolumeFromActiveApp() async {
        guard bundleIdentifier == "com.apple.Music",
              !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").isEmpty else { return }
        
        let script = """
        tell application "Music"
            if it is running then
                get sound volume
            else
                return 50
            end if
        end tell
        """
        
        if let result = try? await AppleScriptHelper.execute(script) {
            let volumeValue = result.int32Value
            let currentVolume = Double(volumeValue) / 100.0
            
            await MainActor.run {
                if self.volumeTask == nil && abs(currentVolume - self.volume) > 0.01 {
                    self.volume = currentVolume
                }
            }
        }
    }
}
