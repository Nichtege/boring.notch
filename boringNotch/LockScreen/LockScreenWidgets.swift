//
//  LockScreenWidgets.swift
//  boringNotch
//
//  Widgets on the lock screen. For now a single test clock, to see whether the trick works at all.
//

import AppKit
import SwiftUI

/// Shows a panel while the Mac is locked, in a space above the lock screen.
@MainActor
final class LockScreenWidgetController {
    static let shared = LockScreenWidgetController()

    private var panel: NSPanel?

    private init() {}

    func screenLocked() {
        guard panel == nil, LockScreenSpace.shared.isAvailable, let screen = NSScreen.main ?? NSScreen.screens.first else { return }

        let size = NSSize(width: 320, height: 160)
        let origin = NSPoint(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.minY + screen.frame.height * 0.22
        )
        let panel = NSPanel(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        panel.level = .mainMenu + 3
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.collectionBehavior = [.fullScreenAuxiliary, .stationary, .canJoinAllSpaces, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: LockScreenTestClock())

        LockScreenSpace.shared.add(panel)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func screenUnlocked() {
        guard let panel else { return }
        panel.close()
        self.panel = nil
    }
}

private struct LockScreenTestClock: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(spacing: 4) {
                Text(context.date, format: .dateTime.hour().minute().second())
                    .font(.system(size: 54, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(verbatim: "Boring Notch · Test")
                    .font(.system(size: 13, weight: .medium))
                    .opacity(0.7)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .padding(8)
        }
    }
}
