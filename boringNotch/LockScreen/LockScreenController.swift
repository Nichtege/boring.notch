//
//  LockScreenController.swift
//  boringNotch
//
//  Puts the active profile's widgets above the lock screen and takes them away on unlock.
//

import AppKit
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
        showWidgets()
        livenessChanged()
    }

    func screenUnlocked() {
        isLocked = false
        hideWidgets()
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
            let panel = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.isMovable = false
            panel.isReleasedWhenClosed = false
            panel.ignoresMouseEvents = !widget.kind.takesClicks
            panel.level = .mainMenu + 3
            panel.appearance = NSAppearance(named: .darkAqua)
            panel.collectionBehavior = [.fullScreenAuxiliary, .stationary, .canJoinAllSpaces, .ignoresCycle]
            panel.contentView = NSHostingView(rootView: LockWidgetPanelContent(widget: widget, room: Self.shadowRoom))
            panel.alphaValue = Self.reduceMotion ? 1 : 0

            LockScreenSpace.shared.add(panel)
            panel.orderFrontRegardless()
            panels.append(panel)
        }

        guard !Self.reduceMotion else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.6
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panels.forEach { $0.animator().alphaValue = 1 }
        }
    }

    private func hideWidgets(animated: Bool = true) {
        let leaving = panels
        panels = []
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
        if kinds.contains(.lyrics) {
            // Only asks when the song changed since the last time
            LyricsManager.shared.refresh()
        }
    }
}

/// One widget in its panel. Stops its clocks while the display sleeps.
private struct LockWidgetPanelContent: View {
    let widget: LockWidget
    let room: CGFloat
    @ObservedObject private var controller = LockScreenController.shared

    var body: some View {
        LockWidgetView(widget: widget)
            .padding(room)
            .environment(\.lockWidgetsPaused, !controller.isScreenAwake)
    }
}
