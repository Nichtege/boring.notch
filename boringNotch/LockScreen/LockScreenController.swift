//
//  LockScreenController.swift
//  boringNotch
//
//  Puts the active profile's widgets above the lock screen and takes them away on unlock.
//

import AppKit
import Combine
import Defaults
import SwiftUI

@MainActor
final class LockScreenController: ObservableObject {
    static let shared = LockScreenController()

    @Published private(set) var isLocked = false
    @Published private(set) var isScreenAwake = true
    /// The settings tab shows the widgets too, and they should be alive there
    var isPreviewing = false {
        didSet { livenessChanged() }
    }

    private var panels: [NSPanel] = []
    /// The stage's cover, which moves aside when lyrics come and back when they go
    private var coverPanel: NSPanel?
    private var lyricsWatch: AnyCancellable?
    private var refreshTimer: Timer?

    private static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private init() {
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.isScreenAwake = false
                self?.livenessChanged()
            }
        }
        workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.isScreenAwake = true
                self?.livenessChanged()
            }
        }
    }

    func screenLocked() {
        isLocked = true
        LockWallpaperTone.shared.refresh()
        showWidgets()
        livenessChanged()
    }

    func screenUnlocked() {
        isLocked = false
        hideWidgets()
        LockWallpaperTone.shared.refresh()
        livenessChanged()
    }

    /// For a change made while the screen is locked, like another profile from a shortcut.
    func reloadIfLocked() {
        guard isLocked else { return }
        hideWidgets(animated: false)
        showWidgets()
        livenessChanged()
    }

    /// Another widget may need a source that wasn't running yet.
    func layoutChanged() {
        livenessChanged()
    }

    // MARK: - Panels

    private var screen: NSScreen? {
        let chosen = Defaults[.lockScreenDisplay]
        return NSScreen.screens.first { !chosen.isEmpty && $0.displayUUID == chosen } ?? NSScreen.screens.first
    }

    private func showWidgets() {
        guard panels.isEmpty, Defaults[.lockScreenWidgets], LockScreenSpace.shared.isAvailable, let screen else { return }

        if Defaults[.lockScreenFullCover] {
            // Goes in first and one level lower, so every widget lies on top of it
            let background = makePanel(frame: screen.frame, takesClicks: false, content: LockStageBackground())
            background.level = Self.stageLevel
            present(background)

            let side = LockStage.coverSide(on: screen.frame.size)
            let cover = makePanel(frame: coverFrame(on: screen), takesClicks: true, content: LockStageCover(side: side))
            cover.level = Self.stageLevel
            present(cover)
            coverPanel = cover
            lyricsWatch = LyricsManager.shared.$lines
                .map(\.isEmpty)
                .removeDuplicates()
                .dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    Task { @MainActor in self?.moveCover() }
                }
        }

        let grid = LockGrid(screenSize: screen.frame.size)
        for widget in LockProfiles.active.widgets {
            let frame = grid.frame(of: widget).insetBy(dx: -Self.shadowRoom, dy: -Self.shadowRoom)
            // The grid counts from the top left, AppKit from the bottom left
            let rect = NSRect(
                x: screen.frame.minX + frame.minX,
                y: screen.frame.maxY - frame.maxY,
                width: frame.width,
                height: frame.height
            )
            // The glass wants to know where on screen it is, without the room for its shadow
            let glassFrame = rect.insetBy(dx: Self.shadowRoom, dy: Self.shadowRoom)
            present(makePanel(
                frame: rect,
                takesClicks: widget.kind.takesClicks,
                content: LockWidgetPanelContent(widget: widget, room: Self.shadowRoom, screenFrame: glassFrame)
            ))
        }

        guard !Self.reduceMotion else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.6
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panels.forEach { $0.animator().alphaValue = 1 }
        }
    }

    /// The cover's panel, with the cover's middle on the screen's middle line, or left of it beside the lyrics.
    private func coverFrame(on screen: NSScreen) -> NSRect {
        let side = LockStage.coverSide(on: screen.frame.size)
        let size = NSSize(width: side + LockStage.coverMargin.width * 2, height: side + LockStage.coverMargin.height * 2)
        let centerX = screen.frame.minX + screen.frame.width * LockStage.coverCenterX(showsLyrics: LockStage.showsLyrics)
        return NSRect(
            x: (centerX - size.width / 2).rounded(),
            y: (screen.frame.midY - size.height / 2).rounded(),
            width: size.width,
            height: size.height
        )
    }

    private func moveCover() {
        guard let coverPanel, let screen else { return }
        let frame = coverFrame(on: screen)
        guard !Self.reduceMotion else {
            coverPanel.setFrame(frame, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.7
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            coverPanel.animator().setFrame(frame, display: true)
        }
    }

    private func makePanel(frame: NSRect, takesClicks: Bool, content: some View) -> NSPanel {
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = !takesClicks
        // The lock screen is a shield over everything. Only windows at its level or above get the pointer's clicks.
        panel.level = Self.widgetLevel
        panel.canBecomeVisibleWithoutLogin = true
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.collectionBehavior = [.fullScreenAuxiliary, .stationary, .canJoinAllSpaces, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: content)
        panel.alphaValue = Self.reduceMotion ? 1 : 0
        return panel
    }

    private func present(_ panel: NSPanel) {
        LockScreenSpace.shared.add(panel)
        panel.orderFrontRegardless()
        panels.append(panel)
    }

    private func hideWidgets(animated: Bool = true) {
        let leaving = panels
        panels = []
        coverPanel = nil
        lyricsWatch = nil
        guard animated, !Self.reduceMotion else {
            leaving.forEach { $0.close() }
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            leaving.forEach { $0.animator().alphaValue = 0 }
        } completionHandler: {
            Task { @MainActor in
                leaving.forEach { $0.close() }
            }
        }
    }

    private static let stageLevel = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
    private static let widgetLevel = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)

    /// Around each widget, so its shadow isn't cut off at the panel's edge
    private static let shadowRoom: CGFloat = 26

    // MARK: - Liveness

    /// Whether anyone can see widgets right now.
    var isLive: Bool {
        (isLocked && isScreenAwake && !panels.isEmpty) || isPreviewing
    }

    private func livenessChanged() {
        let live = isLive
        let kinds = Set(LockProfiles.active.widgets.map(\.kind))
        LockSystemStats.shared.isRunning = live && kinds.contains(.system)
        LockClickRouter.shared.setActive(isLocked && isScreenAwake && !panels.isEmpty)
        // The stage's backdrop moves with the song, where the notch's bars are allowed to listen to it
        LockStagePulse.shared.isListening = isLocked && isScreenAwake && coverPanel != nil
            && Defaults[.liveMusicVisualizer] && Defaults[.lockScreenMotion]

        refreshTimer?.invalidate()
        refreshTimer = nil
        guard live else { return }
        refreshData()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshData() }
        }
    }

    /// Each source decides for itself whether what it has is still fresh.
    private func refreshData() {
        let kinds = Set(LockProfiles.active.widgets.map(\.kind))
        if kinds.contains(.weather) || kinds.contains(.sun) {
            LockWeather.shared.refreshIfStale()
        }
        if kinds.contains(.calendar) || kinds.contains(.reminders) {
            LockEvents.shared.refreshIfStale()
        }
        if kinds.contains(.lyrics) || (Defaults[.lockScreenFullCover] && Defaults[.lockScreenCoverLayout] == .side) {
            // Only asks when the song changed since the last time
            LyricsManager.shared.refresh()
        }
    }
}

/// One widget in its panel. Stops its clocks while the display sleeps.
private struct LockWidgetPanelContent: View {
    let widget: LockWidget
    let room: CGFloat
    let screenFrame: CGRect
    @ObservedObject private var controller = LockScreenController.shared
    @ObservedObject private var music = MusicManager.shared
    @Default(.lockScreenFullCover) private var coverTakesOver

    /// While the cover has the screen, it has all of it. The widgets come back when the music stops.
    private var isStoodIn: Bool {
        coverTakesOver && LockStage.hasSong
    }

    var body: some View {
        LockWidgetView(widget: widget)
            .padding(room)
            .environment(\.lockWidgetsPaused, !controller.isScreenAwake)
            .environment(\.lockWidgetScreenFrame, screenFrame)
            .environment(\.lockClicksEnabled, !isStoodIn)
            .opacity(isStoodIn ? 0 : 1)
            .allowsHitTesting(!isStoodIn)
            .animation(.smooth(duration: 0.5), value: isStoodIn)
    }
}
