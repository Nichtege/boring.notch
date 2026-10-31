//
//  AppleMusicController.swift
//  boringNotch
//
//  Created by Alexander on 2025-03-29.
//

import Foundation
import Combine
import SwiftUI

class AppleMusicController: NSObject {
    // MARK: - Properties
    @Published private var playbackState: PlaybackState = PlaybackState(
        bundleIdentifier: "com.apple.Music",
        playbackRate: 1
    )
    
    var playbackStatePublisher: AnyPublisher<PlaybackState, Never> {
        $playbackState.eraseToAnyPublisher()
    }

    private var artworkKey: String?
    private var updateTask: Task<Void, Never>?
    private var isUpdateDue = false
    private var mayBeQuitting = false
    private var retryTask: Task<Void, Never>?

    // MARK: - Initialization
    override init() {
        super.init()
        setupPlaybackStateChangeObserver()
        Task {
            await updatePlaybackInfo()
        }
    }
    
    private func setupPlaybackStateChangeObserver() {
        // macOS holds back the rest once this app has been active and isn't any more, which only
        // happens through Settings: after a visit there the closed notch would stop hearing of songs
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(playerInfoChanged(_:)),
            name: NSNotification.Name("com.apple.Music.playerInfo"),
            object: nil,
            suspensionBehavior: .deliverImmediately
        )

        let workspace = NSWorkspace.shared.notificationCenter
        // Music doesn't tell about sleep, and the time asleep would count as played
        workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                await self?.updatePlaybackInfo()
            }
        }
        workspace.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            guard AppleMusicController.isMusic(notification) else { return }
            Task { @MainActor in
                await self?.updatePlaybackInfo()
            }
        }
        // A crash or force quit says nothing. No script here: it would start Music again
        workspace.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            guard AppleMusicController.isMusic(notification) else { return }
            Task { @MainActor in
                self?.retryTask?.cancel()
                self?.publishNotPlaying()
            }
        }
    }

    private static func isMusic(_ notification: Notification) -> Bool {
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        return app?.bundleIdentifier == "com.apple.Music"
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
        updateTask?.cancel()
        retryTask?.cancel()
    }

    /// What Music says here holds even when it's too busy for the script that follows, which would
    /// leave the old state showing. A key it doesn't send keeps the old value until the script answers.
    /// Distributed notifications always arrive on the main thread.
    @MainActor
    @objc private func playerInfoChanged(_ notification: Notification) {
        let info = notification.userInfo
        let playerState = info?["Player State"] as? String
        var updatedState = playbackState

        if let playerState, (playerState == "Playing") != updatedState.isPlaying {
            // The bar counts on from the last known position, so that has to be right from here on
            if updatedState.isPlaying {
                updatedState.currentTime += Date().timeIntervalSince(updatedState.lastUpdated) * updatedState.playbackRate
            }
            updatedState.isPlaying = playerState == "Playing"
            updatedState.lastUpdated = Date()
        }
        if let title = info?["Name"] as? String, title != updatedState.title {
            updatedState.title = title
            updatedState.currentTime = 0
            updatedState.lastUpdated = Date()
        }
        if let artist = info?["Artist"] as? String {
            updatedState.artist = artist
        }
        if let album = info?["Album"] as? String {
            updatedState.album = album
        }
        playbackState = updatedState

        retryTask?.cancel()
        mayBeQuitting = playerState == "Stopped"
        isUpdateDue = true
        guard updateTask == nil else { return }
        updateTask = Task { @MainActor [weak self] in
            while let self, self.isUpdateDue {
                self.isUpdateDue = false
                if self.mayBeQuitting {
                    // Music may be quitting, and asking it right now could start it again
                    try? await Task.sleep(for: .seconds(2))
                }
                await self.updatePlaybackInfo()
            }
            self?.updateTask = nil
        }
    }
    
    // MARK: - Protocol Implementation
    func togglePlay() async {
        // The one command that may start Music: someone pressed play
        try? await AppleScriptHelper.executeVoid("tell application \"Music\" to playpause")
    }
    
    func nextTrack() async {
        await executeCommand("next track")
    }
    
    func previousTrack() async {
        await executeCommand("previous track")
    }
    
    func seek(to time: Double) async {
        await executeCommand("set player position to \(time)")
        await updatePlaybackInfo()
    }
    
    func toggleShuffle() async {
        await executeCommand("set shuffle enabled to not shuffle enabled")
        try? await Task.sleep(for: .milliseconds(150))
        await updatePlaybackInfo()
    }
    
    func toggleRepeat() async {
        await executeCommand("""
            if song repeat is off then
                set song repeat to all
            else if song repeat is all then
                set song repeat to one
            else
                set song repeat to off
            end if
            """)
        try? await Task.sleep(for: .milliseconds(150))
        await updatePlaybackInfo()
    }
    
    /// On the main actor as it writes the state that updates work on.
    @MainActor
    func setVolume(_ level: Double) async {
        let clampedLevel = max(0.0, min(1.0, level))
        let volumePercentage = Int(clampedLevel * 100)
        await executeCommand("set sound volume to \(volumePercentage)")
        playbackState.volume = clampedLevel
    }
    
    private func isActive() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").isEmpty
    }

    func setFavorite(_ favorite: Bool) async {
        await executeCommand("set favorited of current track to \(favorite)")
        try? await Task.sleep(for: .milliseconds(150))
        await updatePlaybackInfo()
    }
    
    /// On the main actor since updates can overlap. The scripts themselves run detached.
    @MainActor
    func updatePlaybackInfo(isRetry: Bool = false) async {
        guard isActive() else {
            publishNotPlaying()
            return
        }
        guard let descriptor = await askedTwice({ try? await self.fetchPlaybackInfoAsync() }) else {
            if !isRetry {
                retryUpdate()
            }
            return
        }
        // What the bar counts from, not when the slower art got here
        let readAt = Date()
        guard descriptor.numberOfItems >= 11 else {
            // Only a script that found Music gone has nothing to say
            publishNotPlaying()
            return
        }

        // Artwork is the heavy part, so only a new track asks for it. Streamed artwork can come
        // late, so a track keeps asking until it has some. A track without an ID always asks, and a
        // stream can keep its ID across songs, so the title counts too: no old cover can stick.
        let trackID = descriptor.atIndex(10)?.stringValue ?? ""
        let key = trackID.isEmpty ? nil : "\(trackID) \(descriptor.atIndex(2)?.stringValue ?? "")"
        var artwork = self.playbackState.artwork
        var answeredKey = artworkKey
        if key == nil || key != artworkKey {
            // No answer is nil and no art is empty. Either way this track has no cover yet, not the last one's
            let answer = await askedTwice { await self.fetchArtwork() }
            artwork = answer?.isEmpty == false ? answer : nil
            answeredKey = artwork == nil ? nil : key
            if answer == nil && !isRetry {
                retryUpdate()
            }
        }

        // Music has said something newer since this was read, and that update comes next
        guard !isUpdateDue else { return }
        artworkKey = answeredKey

        var updatedState = self.playbackState
        
        updatedState.isPlaying = descriptor.atIndex(1)?.booleanValue ?? false
        // The script leaves these empty when there's no current track, as the wording is the app's language
        let title = descriptor.atIndex(2)?.stringValue
        let hasNoTrack = title?.isEmpty == true
        let unknown = String(localized: "Unknown")
        updatedState.title = hasNoTrack ? String(localized: "Not Playing") : title ?? unknown
        updatedState.artist = hasNoTrack ? unknown : descriptor.atIndex(3)?.stringValue ?? unknown
        updatedState.album = hasNoTrack ? unknown : descriptor.atIndex(4)?.stringValue ?? unknown
        updatedState.currentTime = descriptor.atIndex(5)?.doubleValue ?? 0
        updatedState.duration = descriptor.atIndex(6)?.doubleValue ?? 0
        updatedState.isShuffled = descriptor.atIndex(7)?.booleanValue ?? false
        let repeatModeValue = descriptor.atIndex(8)?.int32Value ?? 0
        updatedState.repeatMode = RepeatMode(rawValue: Int(repeatModeValue)) ?? .off
        let volumePercentage = descriptor.atIndex(9)?.int32Value ?? 50
        updatedState.volume = Double(volumePercentage) / 100.0
        updatedState.artwork = artwork
        let lovedState = descriptor.atIndex(11)?.booleanValue ?? false
        updatedState.isFavorite = lovedState
        updatedState.lastUpdated = readAt
        self.playbackState = updatedState
    }
    
    // MARK: - Private Methods
    
    /// Without Music nothing would say so any more, and the notch would go on showing it as playing.
    @MainActor
    private func publishNotPlaying() {
        if playbackState.isPlaying {
            playbackState.isPlaying = false
        }
    }
    
    /// Whatever asked won't ask again, and Music's busy moments pass. Only once, as it can also hang for good.
    @MainActor
    private func retryUpdate() {
        retryTask?.cancel()
        retryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await self?.updatePlaybackInfo(isRetry: true)
        }
    }

    /// Music sometimes doesn't answer one script and does answer the next, and a track's first
    /// update may be the only one it gets.
    private func askedTwice<T>(_ ask: () async -> T?) async -> T? {
        if let answer = await ask() { return answer }
        return await ask()
    }

    private func executeCommand(_ command: String) async {
        guard isActive() else { return }
        let script = "tell application \"Music\" to \(command)"
        try? await AppleScriptHelper.executeVoid(script)
    }
    
    private func fetchPlaybackInfoAsync() async throws -> NSAppleEventDescriptor? {
        let script = """
        tell application "Music"
            if it is not running then return {}
            try
                set playerState to player state is playing
                set currentTrackName to name of current track
                set currentTrackArtist to artist of current track
                set currentTrackAlbum to album of current track
                set trackPosition to player position
                set trackDuration to duration of current track
                set shuffleState to shuffle enabled
                set repeatState to song repeat
                if repeatState is off then
                    set repeatValue to 1
                else if repeatState is one then
                    set repeatValue to 2
                else if repeatState is all then
                    set repeatValue to 3
                end if

                set trackID to ""
                try
                    set trackID to persistent ID of current track
                end try
                
                set currentVolume to sound volume
                set favoriteState to favorited of current track
                return {playerState, currentTrackName, currentTrackArtist, currentTrackAlbum, trackPosition, trackDuration, shuffleState, repeatValue, currentVolume, trackID, favoriteState}
            on error errorText number errorNumber
                -- No answer says nothing about what's playing
                if errorNumber is -1712 then error errorText number errorNumber
                return {false, "", "", "", 0, 0, false, 0, sound volume, "", false}
            end try
        end tell
        """
        
        return try await AppleScriptHelper.execute(script)
    }
    
    private func fetchArtwork() async -> Data? {
        let script = """
        tell application "Music"
            if it is not running then return ""
            try
                return data of artwork 1 of current track
            on error errorText number errorNumber
                -- No answer says nothing about the art
                if errorNumber is -1712 then error errorText number errorNumber
                return ""
            end try
        end tell
        """

        return try? await AppleScriptHelper.execute(script)?.data
    }
    
}
