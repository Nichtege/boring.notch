//
//  FullscreenMediaDetection.swift
//  boringNotch
//
//  Created by Richard Kunkli on 06/09/2024.
//

import Foundation
import Combine
import Defaults
import IOKit.pwr_mgt
import MacroVisionKit

@MainActor
final class FullscreenMediaDetector: ObservableObject {
    static let shared = FullscreenMediaDetector()

    @Published var fullscreenStatus: [String: Bool] = [:]

    private var monitorTask: Task<Void, Never>?
    private var videoCheckTask: Task<Void, Never>?
    private var optionCancellable: AnyCancellable?
    private var currentSpaces: [MacroVisionKit.FullScreenMonitor.SpaceInfo] = []

    private let videoCheckInterval: Duration = .seconds(2)

    private init() {
        startMonitoring()
    }

    deinit {
        monitorTask?.cancel()
        videoCheckTask?.cancel()
    }

    private func startMonitoring() {
        optionCancellable = Defaults.publisher(.hideNotchOption, options: [])
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.updateStatus(with: self.currentSpaces)
                self.updateVideoChecks()
            }

        monitorTask = Task { @MainActor in
            let stream = await FullScreenMonitor.shared.spaceChanges()
            for await spaces in stream {
                currentSpaces = spaces
                updateStatus(with: spaces)
                updateVideoChecks()
            }
        }
    }

    private func updateStatus(with spaces: [MacroVisionKit.FullScreenMonitor.SpaceInfo]) {
        var newStatus: [String: Bool] = [:]
        let option = Defaults[.hideNotchOption]

        for space in spaces {
            if let uuid = space.screenUUID {
                let shouldDetect: Bool
                if option == .videoOnly {
                    shouldDetect = isVideoPlaying()
                } else if option == .nowPlayingOnly, let musicSourceBundle = MusicManager.shared.bundleIdentifier  {
                    shouldDetect = space.runningApps.contains(musicSourceBundle)
                } else {
                    shouldDetect = true
                }
                newStatus[uuid] = shouldDetect
            }
        }

        self.fullscreenStatus = newStatus
    }

    /// A video can start or stop without a space change, so look again while something is in full screen.
    private func updateVideoChecks() {
        let needsChecks = !currentSpaces.isEmpty && Defaults[.hideNotchOption] == .videoOnly
        guard needsChecks != (videoCheckTask != nil) else { return }

        videoCheckTask?.cancel()
        videoCheckTask = nil
        guard needsChecks else { return }

        videoCheckTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: self?.videoCheckInterval ?? .seconds(2))
                guard let self, !Task.isCancelled else { return }
                self.updateStatus(with: self.currentSpaces)
            }
        }
    }

    /// Video players keep the display awake, music players only keep the system awake.
    private func isVideoPlaying() -> Bool {
        var assertions: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&assertions) == kIOReturnSuccess,
              let byProcess = assertions?.takeRetainedValue() as? [AnyHashable: [[String: Any]]]
        else { return false }

        return byProcess.values.joined().contains { assertion in
            let type = assertion["AssertType"] as? String
            let isDisplayAssertion = type == kIOPMAssertPreventUserIdleDisplaySleep || type == "NoDisplaySleepAssertion"
            // `caffeinate` keeps the display awake too, but it isn't playing anything
            return isDisplayAssertion && assertion["Process Name"] as? String != "caffeinate"
        }
    }
}

