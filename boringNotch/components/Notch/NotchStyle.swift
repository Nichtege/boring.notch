//
//  NotchStyle.swift
//  boringNotch
//
//  The few values the notch's own views share, so a box, a button or a color means the same in every tab.
//  The cards and the Atlas line under the notch have their smoked glass and keep it.
//

import SwiftUI

enum NotchStyle {
    /// Something wants you: a terminal waiting, a deadline today or tomorrow. Only that is orange.
    static let attention = Color.orange
    /// A focus session: calm, and never taken for something waiting.
    static let focus = Color.cyan

    /// A box on the black: the Starlane info, a picked device, Home's tiles.
    static let surface = Color.white.opacity(0.07)
    /// A button, a picked tab, a switched-on control.
    static let control = Color.white.opacity(0.15)
    static let controlHovered = Color.white.opacity(0.24)

    /// Corners of a box inside the notch, as on the shelf's files.
    static let boxRadius: CGFloat = 12
    /// Corners of a cover or a small icon.
    static let coverRadius: CGFloat = 6
}

extension View {
    /// Times and counts: rounded, and every digit as wide as the next, so they don't jump while they change.
    func notchNumber() -> some View {
        fontDesign(.rounded).monospacedDigit()
    }
}
