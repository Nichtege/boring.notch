//
//  LockWallpaperTone.swift
//  boringNotch
//
//  The colour for widgets that match the wallpaper. The wallpaper can be a video with no file to read,
//  so this takes a thumbnail of the wallpaper's own window, which needs the Screen Recording permission.
//  Nothing but that one window is looked at, and only its overall colour is kept.
//

import Defaults
import ScreenCaptureKit
import SwiftUI

extension Defaults.Keys {
    /// Hue and saturation of the wallpaper's colour, empty until it was read once
    static let lockScreenWallpaperTone = Key<[Double]>("lockScreenWallpaperTone", default: [])
}

enum LockWallpaperColor {
    /// Read wherever an accent is drawn, written on the main thread only
    static var current = color(from: Defaults[.lockScreenWallpaperTone])

    static func color(from tone: [Double]) -> Color {
        guard tone.count == 2, tone[1] > 0 else { return .white }
        return Color(hue: tone[0], saturation: tone[1], brightness: 1)
    }
}

@MainActor
final class LockWallpaperTone: ObservableObject {
    static let shared = LockWallpaperTone()

    /// Goes up when the colour changed, for views that drew the old one
    @Published private(set) var version = 0
    private var isReading = false

    private init() {}

    var isAllowed: Bool {
        CGPreflightScreenCaptureAccess()
    }

    var isWanted: Bool {
        LockProfiles.active.widgets.contains { $0.style.accent == .wallpaper }
    }

    /// Looks at the wallpaper again, where a widget wants its colour and macOS allows the look.
    func refresh() {
        guard !isReading, isWanted, isAllowed else { return }
        isReading = true
        let display = Defaults[.lockScreenDisplay]
        let screen = NSScreen.screens.first { !display.isEmpty && $0.displayUUID == display } ?? NSScreen.screens.first
        let size = screen?.frame.size ?? .zero
        Task {
            defer { isReading = false }
            guard let tone = await Self.read(screenSize: size) else { return }
            let old = Defaults[.lockScreenWallpaperTone]
            if old.count == 2 {
                let turn = abs(old[0] - tone[0])
                // A wallpaper that moves shifts a little all the time, which is no reason to redraw
                if min(turn, 1 - turn) < 0.03, abs(old[1] - tone[1]) < 0.06 { return }
            }
            Defaults[.lockScreenWallpaperTone] = tone
            LockWallpaperColor.current = LockWallpaperColor.color(from: tone)
            version += 1
        }
    }

    private static func read(screenSize: CGSize) async -> [Double]? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else {
            return nil
        }
        let walls = content.windows.filter { $0.windowLayer < -1000 && ($0.title ?? "").hasPrefix("Wallpaper") }
        guard let wall = walls.first(where: { $0.frame.size == screenSize }) ?? walls.first else { return nil }
        let configuration = SCStreamConfiguration()
        configuration.width = 64
        configuration.height = 40
        configuration.showsCursor = false
        let filter = SCContentFilter(desktopIndependentWindow: wall)
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) else {
            return nil
        }
        return tone(of: image)
    }

    /// The hue most of the picture's colour sits at, and how strong to show it: light enough to read as type.
    nonisolated static func tone(of image: CGImage) -> [Double]? {
        let width = 64, height = 40
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var x = 0.0, y = 0.0, colour = 0.0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let red = Double(pixels[index]) / 255, green = Double(pixels[index + 1]) / 255, blue = Double(pixels[index + 2]) / 255
            let high = max(red, green, blue), delta = high - min(red, green, blue)
            guard delta > 0 else { continue }
            var hue: Double
            if high == red {
                hue = (green - blue) / delta
            } else if high == green {
                hue = 2 + (blue - red) / delta
            } else {
                hue = 4 + (red - green) / delta
            }
            hue *= .pi / 3
            // Saturation times brightness: grey, black and white pixels have no say in the hue
            x += cos(hue) * delta
            y += sin(hue) * delta
            colour += delta
        }
        let colourfulness = colour / Double(width * height)
        // How much the colours agree: a picture of every colour has none to match
        let agreement = colour > 0 ? hypot(x, y) / colour : 0
        guard colourfulness > 0.05, agreement > 0.25 else { return [0, 0] }
        var hue = atan2(y, x) / (2 * .pi)
        if hue < 0 { hue += 1 }
        return [hue, min(max(colourfulness * 1.4, 0.28), 0.55)]
    }
}
