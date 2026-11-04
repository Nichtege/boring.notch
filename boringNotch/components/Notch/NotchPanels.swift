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
    /// Asked for their screen when it matters, since that can change while a notch is open.
    private var openNotches: [BoringViewModel] = []

    private init() {}

    /// The panels sit under the notch, so they move down with an opening notch and back up with a closing one.
    func notchChanged(_ notch: BoringViewModel, isOpen: Bool) {
        openNotches.removeAll { $0 === notch }
        if isOpen {
            openNotches.append(notch)
        }
        movePanels()
    }

    /// The notches went away with their windows, and none of them will report closing any more.
    func notchesRemoved() {
        openNotches.removeAll()
        movePanels()
    }

    private func movePanels() {
        AtlasPromptController.shared.notchMoved()
        NotificationCardController.shared.reposition()
    }

    /// A panel stays where it is, and a new one goes where the mouse is.
    func screen(for panel: NSPanel) -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return panel.isVisible ? (panel.screen ?? NSScreen.main) : (NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main)
    }

    /// The Mac's own screen, where the notch is, whichever screen the mouse is on. With the lid closed
    /// it's the one with the menu bar.
    var mainScreen: NSScreen? {
        NSScreen.screens.first { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            else { return false }
            return CGDisplayIsBuiltin(CGDirectDisplayID(number.uint32Value)) != 0
        } ?? NSScreen.screens.first
    }

    /// Where the notch ends on this screen, open or closed.
    func notchBottom(on screen: NSScreen) -> CGFloat {
        let closedHeight = max(screen.safeAreaInsets.top, screen.frame.maxY - screen.visibleFrame.maxY)
        let uuid = screen.displayUUID
        let isOpen = uuid != nil && openNotches.contains { ($0.screenUUID ?? NSScreen.main?.displayUUID) == uuid }
        return screen.frame.maxY - (isOpen ? openNotchSize.height : closedHeight)
    }

    /// Floats above everything, on every space and over full screen, always in dark.
    func configure(_ panel: NSPanel) {
        panel.isFloatingPanel = true
        panel.level = .mainMenu + 4
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.collectionBehavior = [.fullScreenAuxiliary, .stationary, .canJoinAllSpaces, .ignoresCycle]
    }

    /// The panel decides its own size; the view inside only reports what it needs.
    func embed<Content: View>(_ host: NSHostingView<Content>, in panel: NSPanel) {
        host.sizingOptions = []
        host.autoresizingMask = [.width, .height]
        host.frame = panel.contentView?.bounds ?? .zero
        panel.contentView?.addSubview(host)
    }

    func move(_ panel: NSPanel, to frame: NSRect, animated: Bool) {
        // Without a duration too, or a move still underway would end up overriding this one
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated ? moveDuration : 0
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(frame, display: true)
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
        if !reduceTransparency, contrast != .increased {
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
