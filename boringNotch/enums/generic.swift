//
//  generic.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 04/08/24.
//

import Foundation
import Defaults

public enum NotchState {
    case closed
    case open
}

public enum NotchViews {
    case home
    /// Where it plays and how loud each app is, side by side
    case sound
    case shelf
    case starlane
    /// Has no tab: reached from the timer at the right of the header, Home and the ball beside the notch
    case focus
}

enum WindowHeightMode: String, Defaults.Serializable {
    case matchMenuBar = "Match menubar height"
    case matchRealNotchSize = "Match real notch height"
    case custom = "Custom height"
}

enum SliderColorEnum: String, CaseIterable, Defaults.Serializable {
    case white = "White"
    case albumArt = "Match album art"
    case accent = "Accent color"
}
