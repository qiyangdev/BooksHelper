import AppKit
import QuartzCore

final class BooksReadingMatBackground: NSView {
    var outerMargin = BooksSidebarGeometry.margin {
        didSet {
            if oldValue != outerMargin { needsLayout = true }
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }

    override func makeBackingLayer() -> CALayer {
        let layer = super.makeBackingLayer()
        layer.cornerCurve = .continuous
        layer.masksToBounds = true
        return layer
    }

    override var wantsUpdateLayer: Bool { true }

    static var fill: NSColor {
        let base = NSColor.windowBackgroundColor
        return base.blended(withFraction: 0.055, of: .labelColor) ?? base
    }

    override func updateLayer() { layer?.backgroundColor = Self.fill.cgColor }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = Self.cornerRadius(in: bounds, margin: outerMargin)
    }

    static func cornerRadius(in bounds: CGRect, margin: CGFloat) -> CGFloat {
        min(BooksSidebarGeometry.booksCornerRadius + margin, bounds.width / 2, bounds.height / 2)
    }
}
