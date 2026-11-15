//
//  LockLiquidGlass.swift
//  boringNotch
//
//  Glass that shows what is really behind the widget: bent at the rim like a thick pane, lightly blurred
//  and with its colours lifted. Core Animation's backdrop layer and filters do the work in the window server,
//  so it follows a moving wallpaper for free. Both are private and may change with a macOS update, in which
//  case `isAvailable` turns false and the widgets fall back to glass that is only drawn.
//

import AppKit
import SwiftUI

struct LockLiquidGlass: NSViewRepresentable {
    var cornerRadius: CGFloat
    /// How far the rim bends what is behind it, in points
    var refraction: Double
    var blur: Double
    var saturation: Double

    static let isAvailable: Bool = {
        guard NSClassFromString("CABackdropLayer") is CALayer.Type, let filters = LockLiquidGlassView.filterClass else { return false }
        return filters.responds(to: NSSelectorFromString("filterWithType:"))
    }()

    func makeNSView(context: Context) -> LockLiquidGlassView {
        LockLiquidGlassView()
    }

    func updateNSView(_ view: LockLiquidGlassView, context: Context) {
        view.settings = .init(cornerRadius: cornerRadius, refraction: refraction, blur: blur, saturation: saturation)
    }
}

final class LockLiquidGlassView: NSView {
    struct Settings: Equatable {
        var cornerRadius: CGFloat = 28
        var refraction: Double = 40
        var blur: Double = 2
        var saturation: Double = 1.5
    }

    var settings = Settings() {
        didSet {
            if settings != oldValue { rebuild() }
        }
    }

    static let filterClass: AnyObject? = NSClassFromString("CAFilter")

    private let backdrop: CALayer?
    private var builtFor: (size: CGSize, scale: CGFloat, settings: Settings)?

    /// How wide the bending rim is, in points
    private static let rim: CGFloat = 28

    override init(frame: NSRect) {
        backdrop = (NSClassFromString("CABackdropLayer") as? CALayer.Type)?.init()
        super.init(frame: frame)
        wantsLayer = true
        guard let backdrop else { return }
        // Reads what the window server has behind this window, not just this window's own views
        backdrop.setValue(true, forKey: "windowServerAware")
        backdrop.masksToBounds = true
        backdrop.cornerCurve = .continuous
        layer?.addSublayer(backdrop)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func layout() {
        super.layout()
        rebuild()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        rebuild()
    }

    private func rebuild() {
        guard let backdrop, bounds.width > 1, bounds.height > 1 else { return }
        let scale = window?.backingScaleFactor ?? 2
        if let builtFor, builtFor.size == bounds.size, builtFor.scale == scale, builtFor.settings == settings { return }
        builtFor = (bounds.size, scale, settings)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdrop.frame = bounds
        backdrop.cornerRadius = settings.cornerRadius

        var filters: [NSObject] = []
        if settings.refraction > 0,
           let map = Self.lensMap(size: bounds.size, scale: scale, cornerRadius: settings.cornerRadius),
           let lens = Self.filter("displacementMap", [
               "inputMaskImage": map,
               "inputAmount": settings.refraction,
               // The map's middle grey means "stay where you are"
               "inputOffset": 0.5,
           ]) {
            filters.append(lens)
        }
        if settings.blur > 0, let blur = Self.filter("gaussianBlur", ["inputRadius": settings.blur, "inputNormalizeEdges": true]) {
            filters.append(blur)
        }
        if let saturate = Self.filter("colorSaturate", ["inputAmount": settings.saturation]) {
            filters.append(saturate)
        }
        backdrop.filters = filters
        CATransaction.commit()
    }

    /// A filter with these inputs, or nil when this macOS doesn't know the filter or one of the inputs.
    private static func filter(_ type: String, _ inputs: [String: Any]) -> NSObject? {
        guard
            let filterClass,
            let filter = filterClass.perform(NSSelectorFromString("filterWithType:"), with: type)?.takeUnretainedValue() as? NSObject,
            filter.responds(to: NSSelectorFromString("inputKeys")),
            let known = filter.perform(NSSelectorFromString("inputKeys"))?.takeUnretainedValue() as? [String],
            inputs.keys.allSatisfy(known.contains)
        else { return nil }
        for (key, value) in inputs {
            filter.setValue(value, forKey: key)
        }
        return filter
    }

    /// Which way each pixel looks: red is the shift across, green the shift down, middle grey none.
    /// Only the rim shifts, outwards and ever more towards the edge, the way a thick pane's rounded edge bends light.
    private static func lensMap(size: CGSize, scale: CGFloat, cornerRadius: CGFloat) -> CGImage? {
        let width = Int((size.width * scale).rounded())
        let height = Int((size.height * scale).rounded())
        guard width > 0, height > 0, width * height < 16_000_000 else { return nil }

        let w = CGFloat(width)
        let h = CGFloat(height)
        let radius = min(cornerRadius * scale * 1.2, min(w, h) / 2)
        let band = min(rim * scale, min(w, h) / 2)

        /// Distance to the rounded rectangle's edge, negative inside
        func distance(_ x: CGFloat, _ y: CGFloat) -> CGFloat {
            let qx = abs(x - w / 2) - (w / 2 - radius)
            let qy = abs(y - h / 2) - (h / 2 - radius)
            let outsideX = max(qx, 0)
            let outsideY = max(qy, 0)
            return (outsideX * outsideX + outsideY * outsideY).squareRoot() + min(max(qx, qy), 0) - radius
        }

        var pixels = [UInt8](repeating: 128, count: width * height * 4)
        for row in 0..<height {
            for column in 0..<width {
                let index = (row * width + column) * 4
                pixels[index + 3] = 255
                let x = CGFloat(column) + 0.5
                let y = CGFloat(row) + 0.5
                let depth = -distance(x, y)
                guard depth >= 0, depth < band else { continue }
                let normalX = distance(x + 1, y) - distance(x - 1, y)
                let normalY = distance(x, y + 1) - distance(x, y - 1)
                let length = max((normalX * normalX + normalY * normalY).squareRoot(), 0.0001)
                let closeness = 1 - depth / band
                let strength = closeness * closeness * closeness
                pixels[index] = UInt8(max(0, min(255, (0.5 + 0.5 * normalX / length * strength) * 255)))
                pixels[index + 1] = UInt8(max(0, min(255, (0.5 + 0.5 * normalY / length * strength) * 255)))
            }
        }
        return pixels.withUnsafeMutableBytes { buffer in
            CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )?.makeImage()
        }
    }
}
