//
//  LockLiquidGlass.swift
//  boringNotch
//
//  Glass that shows what is really behind the widget, made the way macOS makes its own Liquid Glass:
//  a backdrop layer that reads what the window server has behind the panel, a shape layer that tells it
//  where the pane's edge is, and the system's `glassBackground` filter, which bends the picture along that
//  edge. The values are the ones SwiftUI's `.glassEffect` sets, read off a live layer on macOS 27.2, except
//  for blur and tone: the system's are tuned for controls over app content and come out as grey frost here.
//
//  All of this is private. When a class, the filter or one of its inputs is gone after an update,
//  `isAvailable` is false or the view stays empty, and the widgets fall back to glass that is only drawn.
//

import AppKit
import SwiftUI

struct LockLiquidGlass: NSViewRepresentable {
    var cornerRadius: CGFloat
    /// How much the picture behind is softened. The system uses 5 to 10.
    var blur: Double
    var saturation: Double

    static let isAvailable: Bool = {
        NSClassFromString("CABackdropLayer") is CALayer.Type
            && NSClassFromString("CASDFLayer") is CALayer.Type
            && NSClassFromString("CASDFElementLayer") is CALayer.Type
            && NSClassFromString("CASDFOutputEffect") is NSObject.Type
            && LockLiquidGlassView.makeFilter(blur: 2, saturation: 1) != nil
    }()

    func makeNSView(context: Context) -> LockLiquidGlassView {
        LockLiquidGlassView()
    }

    func updateNSView(_ view: LockLiquidGlassView, context: Context) {
        view.settings = .init(cornerRadius: cornerRadius, blur: blur, saturation: saturation)
    }
}

final class LockLiquidGlassView: NSView {
    struct Settings: Equatable {
        var cornerRadius: CGFloat = 28
        var blur: Double = 1.5
        var saturation: Double = 1.2
    }

    var settings = Settings() {
        didSet {
            if settings != oldValue { rebuild() }
        }
    }

    private static let shapeName = "shape"

    private let backdrop: CALayer?
    private let shape: CALayer?
    private let element: CALayer?

    override init(frame: NSRect) {
        backdrop = (NSClassFromString("CABackdropLayer") as? CALayer.Type)?.init()
        shape = (NSClassFromString("CASDFLayer") as? CALayer.Type)?.init()
        element = (NSClassFromString("CASDFElementLayer") as? CALayer.Type)?.init()
        super.init(frame: frame)
        wantsLayer = true

        guard let backdrop, let shape, let element, let effect = (NSClassFromString("CASDFOutputEffect") as? NSObject.Type)?.init(),
              shape.responds(to: NSSelectorFromString("setEffect:")) else { return }
        // Reads what the window server has behind this window, not just this window's own views
        backdrop.setValue(true, forKey: "windowServerAware")
        // The filter finds the pane's outline in this sublayer, by its name
        shape.name = Self.shapeName
        shape.setValue(effect, forKey: "effect")
        let holder = CALayer()
        element.cornerCurve = .continuous
        holder.addSublayer(element)
        shape.addSublayer(holder)
        backdrop.addSublayer(shape)
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

    private func rebuild() {
        guard let backdrop, let shape, let element, backdrop.superlayer != nil, bounds.width > 1, bounds.height > 1 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdrop.frame = bounds
        shape.frame = bounds
        element.frame = bounds
        element.cornerRadius = settings.cornerRadius
        backdrop.filters = Self.makeFilter(blur: settings.blur, saturation: settings.saturation).map { [$0] } ?? []
        CATransaction.commit()
    }

    /// The system's glass filter, or nil when this macOS doesn't have it with these inputs.
    static func makeFilter(blur: Double, saturation: Double) -> NSObject? {
        let inputs: [String: Any] = [
            "inputSourceSublayerName": shapeName,
            // The bend at the rim: how far the picture is pulled, and how wide the rim is. The system's own values.
            "inputInnerRefractionAmount": -60,
            "inputInnerRefractionHeight": 20,
            "inputOuterRefractionAmount": 0,
            "inputOuterRefractionHeight": 0,
            "inputRefractionDistance0": -1,
            "inputRefractionDistance1": 0,
            "inputRefractionOpacity": 0,
            "inputBlurRadius": blur,
            "inputBlurOpacity0": 1,
            "inputBlurOpacity1": 1,
            "inputBlurOpacity2": 1,
            "inputBlurOpacity3": 1,
            // The pane's tone. The system darkens and greys it, here the picture keeps its light and colour.
            "inputFaceOpacity": 1,
            "inputFaceColorMatrixWhite": 1,
            "inputFaceColorMatrixBlack": 0,
            "inputFaceColorMatrixSaturation": saturation,
            "inputFaceColorMatrixFillColor": CGColor(gray: 0, alpha: 0),
            "inputFaceColorMatrixMaxLuma": 1,
            "inputFaceColorMatrixMaxLumaSDR": 1,
            "inputBleedDistance0": 1,
            "inputBleedDarkenBlend": 1,
            "inputBleedColorMatrixWhite": 1,
            "inputBleedColorMatrixBlack": 0.75,
            "inputBleedColorMatrixSaturation": 1.2,
            "inputShadowColorMatrixWhite": 1,
            "inputShadowColorMatrixSaturation": 1.2,
            "inputSDRHoldingToneWhite": 1,
            "inputSDRGradientDistance0": 1,
            "inputSDRGradientDistance1": 1,
            "inputMaxHeadroom": 9999,
            "inputClamp": 1,
        ]
        guard
            let filterClass = NSClassFromString("CAFilter") as AnyObject?,
            filterClass.responds(to: NSSelectorFromString("filterWithType:")),
            let filter = filterClass.perform(NSSelectorFromString("filterWithType:"), with: "glassBackground")?.takeUnretainedValue() as? NSObject,
            filter.responds(to: NSSelectorFromString("inputKeys")),
            let known = filter.perform(NSSelectorFromString("inputKeys"))?.takeUnretainedValue() as? [String],
            inputs.keys.allSatisfy(known.contains)
        else { return nil }
        for (key, value) in inputs {
            filter.setValue(value, forKey: key)
        }
        return filter
    }
}
