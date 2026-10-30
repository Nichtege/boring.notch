//
//  NotchPanels.swift
//  boringNotch
//
//  What the floating panels under the notch share: where they go and what they're made of.
//

import AppKit
import SwiftUI

// MARK: - Placement
@MainActor
final class NotchPanelLayout {
    static let shared = NotchPanelLayout()

    let gapBelowNotch: CGFloat = 6

    private let moveDuration: TimeInterval = 0.3
    private var screensWithOpenNotch: Set<String> = []

    private init() {}

    /// The panels sit under the notch, so they move down with an opening notch and back up with a closing one.
    func notchChanged(isOpen: Bool, screenUUID: String?) {
        guard let uuid = screenUUID ?? NSScreen.main?.displayUUID else { return }
        if isOpen {
            screensWithOpenNotch.insert(uuid)
        } else {
            screensWithOpenNotch.remove(uuid)
        }
        AtlasPromptController.shared.notchMoved()
        NotificationCardController.shared.reposition()
    }

    /// A panel stays where it is, and a new one goes where the mouse is.
    func screen(for panel: NSPanel) -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return panel.isVisible ? (panel.screen ?? NSScreen.main) : (NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main)
    }

    /// Where the notch ends on this screen, open or closed.
    func notchBottom(on screen: NSScreen) -> CGFloat {
        let closedHeight = max(screen.safeAreaInsets.top, screen.frame.maxY - screen.visibleFrame.maxY)
        let isOpen = screen.displayUUID.map(screensWithOpenNotch.contains) ?? false
        return screen.frame.maxY - (isOpen ? openNotchSize.height : closedHeight)
    }

    func move(_ panel: NSPanel, to frame: NSRect, animated: Bool) {
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = moveDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }
}

// MARK: - Material
extension View {
    /// Smoked glass: white text on it measured 8.2:1 over a white page. A tint on the glass itself
    /// doesn't get there, the black has to go underneath. Glass brings its own edge, the opaque
    /// fallback needs one drawn.
    func smokedGlass<S: InsettableShape>(in shape: S) -> some View {
        modifier(SmokedGlass(shape: shape))
    }
}

private struct SmokedGlass<S: InsettableShape>: ViewModifier {
    let shape: S

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *), !reduceTransparency, contrast != .increased {
            content
                .background(.black.opacity(0.6), in: shape)
                .glassEffect(.regular, in: shape)
        } else {
            content
                .background(.black, in: shape)
                .overlay(shape.strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
        }
    }
}
