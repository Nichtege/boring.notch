//
//  LockClickRouter.swift
//  boringNotch
//
//  Clicks for the lock screen. While the Mac is locked, macOS hands the pointer's clicks to the lock screen
//  alone, whatever lies on top of it. The pointer's position and whether its button is down can still be read,
//  so this watches for a press and release over one of our buttons and runs that button's action itself.
//

import AppKit
import SwiftUI

@MainActor
final class LockClickRouter {
    static let shared = LockClickRouter()

    private let targets = NSHashTable<LockClickTargetView>.weakObjects()
    private var timer: Timer?
    private var wasDown = false
    private weak var pressed: LockClickTargetView?

    private init() {}

    /// While this is on, the buttons leave their own action alone, so a click can never count twice.
    var isActive: Bool {
        timer != nil
    }

    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        timer?.invalidate()
        timer = nil
        pressed = nil
        guard active else { return }
        // Held down from before, like the click that locked the screen, is not a press on a button
        wasDown = true
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    fileprivate func add(_ target: LockClickTargetView) {
        targets.add(target)
    }

    private func poll() {
        let isDown = CGEventSource.buttonState(.hidSystemState, button: .left)
        defer { wasDown = isDown }
        if isDown && !wasDown {
            pressed = target(at: NSEvent.mouseLocation)
        } else if !isDown && wasDown, let pressed {
            // Released somewhere else is how a click is taken back
            if target(at: NSEvent.mouseLocation) === pressed {
                pressed.action?()
            }
            self.pressed = nil
        }
    }

    private func target(at point: NSPoint) -> LockClickTargetView? {
        targets.allObjects.first { target in
            guard target.isEnabled, let window = target.window, window.isVisible, window.alphaValue > 0.5 else { return false }
            return window.convertToScreen(target.convert(target.bounds, to: nil)).contains(point)
        }
    }
}

final class LockClickTargetView: NSView {
    var action: (() -> Void)?
    var isEnabled = true

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            MainActor.assumeIsolated {
                LockClickRouter.shared.add(self)
            }
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

/// Marks the area behind a button as one the router may click.
struct LockClickTarget: NSViewRepresentable {
    let isEnabled: Bool
    let action: () -> Void

    func makeNSView(context: Context) -> LockClickTargetView {
        LockClickTargetView()
    }

    func updateNSView(_ view: LockClickTargetView, context: Context) {
        view.action = action
        view.isEnabled = isEnabled
    }
}

private struct LockClicksEnabledKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// False while the buttons are there but not shown, like a widget that stepped aside.
    var lockClicksEnabled: Bool {
        get { self[LockClicksEnabledKey.self] }
        set { self[LockClicksEnabledKey.self] = newValue }
    }
}
