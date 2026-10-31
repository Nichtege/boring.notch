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
    private var musicCoverCache: (artwork: Data, image: NSImage)?
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
    /// Music's own, also while something else shows here
    @Published private(set) var musicState: PlaybackState?
    /// Set while a device picked in the Devices tab shows instead of Music
    @Published private(set) var remoteDevice: RemoteNowPlaying?

    var isRemoteSource: Bool {
        remoteDevice != nil
    }

    var musicIsPlaying: Bool { musicState?.isPlaying == true }
    var musicLastUpdated: Date { musicState?.lastUpdated ?? .distantPast }
    var musicTitle: String { musicState?.title ?? "" }
    var musicArtist: String { musicState?.artist ?? "" }
    var musicHasContent: Bool { (musicState?.duration ?? 0) > 0 }
    var musicCover: NSImage? {
        guard let artwork = musicState?.artwork else { return nil }
        if musicCoverCache?.artwork != artwork {
            musicCoverCache = (artwork, NSImage(data: artwork) ?? defaultImage)
        }
        return musicCoverCache?.image
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
    }

    public func destroy() {
        debounceIdleTask?.cancel()
        cancellables.removeAll()
    }

    // MARK: - Update Methods
    @MainActor
    private func musicChanged(_ state: PlaybackState) {
        let started = state.isPlaying && musicState?.isPlaying != true
        musicState = state
        // What comes from this Mac goes first, until someone picks something else again
        if started {
            RemoteMediaManager.shared.select(nil)
        } else if remoteDevice == nil {
            updateFromPlaybackState(state)
        }
    }

    /// nil goes back to Music.
    @MainActor
    func show(remote device: RemoteNowPlaying?) {
        remoteDevice = device
        if let state = device?.state ?? musicState {
            updateFromPlaybackState(state)
        }
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
        if let remoteDevice {
            RemoteMediaManager.shared.send(.toggle, to: remoteDevice.deviceName)
            return
        }
        toggleMusicPlay()
    }

    /// Also while something else shows, for Music's own row in the Devices tab.
    func toggleMusicPlay() {
        Task {
            if musicState?.isPlaying != true {
                await MusicOutputController.shared.restoreLastOutput()
            }
            await controller.togglePlay()
        }
    }

    func nextTrack() {
        if let remoteDevice {
            RemoteMediaManager.shared.send(.next, to: remoteDevice.deviceName)
            return
        }
        nextMusicTrack()
    }

    func nextMusicTrack() {
        Task {
            await controller.nextTrack()
        }
    }

    func previousTrack() {
        if let remoteDevice {
            RemoteMediaManager.shared.send(.previous, to: remoteDevice.deviceName)
            return
        }
        previousMusicTrack()
    }

    func previousMusicTrack() {
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
        if let remoteDevice {
            RemoteMediaManager.shared.send(.skip(seconds: Int(seconds)), to: remoteDevice.deviceName)
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
