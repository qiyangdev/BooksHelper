import AppKit
import QuartzCore

@MainActor
final class ParagraphReplacement {
    private let layout: NSLayoutManager?
    private let range: NSRange
    private let layers: [CALayer]
    private var timer: Timer?

    private init(layout: NSLayoutManager?, range: NSRange, layers: [CALayer], duration: TimeInterval) {
        self.layout = layout
        self.range = range
        self.layers = layers
        let timer = Timer(timeInterval: duration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func finish() {
        timer?.invalidate()
        timer = nil
        guard layers.contains(where: { $0.superlayer != nil }) else { return }
        layout?.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)
        for layer in layers { layer.removeFromSuperlayer() }
    }

    static func animate(
        incoming: NSRange, in overlays: [NSTextView], outgoing: NSRange, in sources: [NSTextView]
    ) -> ParagraphReplacement? {
        guard let layout = overlays.first?.layoutManager, let sourceLayout = sources.first?.layoutManager,
              let next = location(of: incoming, in: layout, views: overlays),
              let host = next.view.layer, let nextLayer = snapshot(next.view, in: next.rect) else { return nil }
        let previous = location(of: outgoing, in: sourceLayout, views: sources)
        let previousLayer = previous.flatMap { snapshot($0.view, in: $0.rect) }

        layout.addTemporaryAttribute(.foregroundColor, value: NSColor.clear, forCharacterRange: incoming)
        if let previousLayer, let sourceHost = previous?.view.layer, previous?.line == next.line {
            fade(previousLayer, on: sourceHost, from: 1, to: 0)
        }
        fade(nextLayer, on: host, from: 0, to: 1)
        return ParagraphReplacement(layout: layout, range: incoming, layers: [previousLayer, nextLayer].compactMap { $0 }, duration: 0.10)
    }

    static func fadeRemainingSource(in views: [NSTextView], after covered: NSRange) -> ParagraphReplacement? {
        guard let layout = views.first?.layoutManager, let storage = views.first?.textStorage else { return nil }
        let start = NSMaxRange(covered)
        guard start < storage.length else { return nil }
        let remaining = layout.glyphRange(
            forCharacterRange: NSRange(location: start, length: storage.length - start), actualCharacterRange: nil
        )
        let duration = 0.16
        let layers = views.compactMap { view -> CALayer? in
            guard let container = view.textContainer, let host = view.layer else { return nil }
            let visible = NSIntersectionRange(remaining, layout.glyphRange(for: container))
            guard visible.length > 0 else { return nil }
            let rect = layout.boundingRect(forGlyphRange: visible, in: container).integral.intersection(view.bounds)
            guard !rect.isEmpty, let layer = snapshot(view, in: rect) else { return nil }
            fade(layer, on: host, from: 1, to: 0, duration: duration, key: "sourceCompletion")
            return layer
        }
        guard !layers.isEmpty else { return nil }
        return ParagraphReplacement(layout: nil, range: NSRange(), layers: layers, duration: duration)
    }

    private static func location(
        of characters: NSRange, in layout: NSLayoutManager, views: [NSTextView]
    ) -> (view: NSTextView, rect: CGRect, line: CGFloat)? {
        guard characters.length > 0 else { return nil }
        let glyphs = layout.glyphRange(forCharacterRange: characters, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return nil }
        for view in views {
            guard let container = view.textContainer else { continue }
            let visible = layout.glyphRange(for: container)
            guard NSIntersectionRange(visible, glyphs) == glyphs else { continue }
            let line = layout.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
            guard line == layout.lineFragmentRect(forGlyphAt: NSMaxRange(glyphs) - 1, effectiveRange: nil) else {
                return nil
            }
            let rect = layout.boundingRect(forGlyphRange: glyphs, in: container).integral.intersection(view.bounds)
            return rect.isEmpty ? nil : (view, rect, line.minY)
        }
        return nil
    }

    private static func snapshot(_ view: NSTextView, in rect: CGRect) -> CALayer? {
        guard let image = view.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        view.cacheDisplay(in: rect, to: image)
        guard let contents = image.cgImage else { return nil }
        let layer = CALayer()
        layer.frame = rect
        layer.contents = contents
        return layer
    }

    private static func fade(
        _ layer: CALayer, on host: CALayer, from: Float, to: Float,
        duration: TimeInterval = 0.10, key: String = "replacement"
    ) {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        layer.opacity = to
        host.addSublayer(layer)
        layer.add(animation, forKey: key)
    }
}
