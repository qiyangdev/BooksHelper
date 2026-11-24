import AppKit

final class BooksParagraphDocument: NSView {
    private var paragraphViews: [[NSTextView]] = []
    private var shimmerTimer: Timer?
    private var pendingRanges: [(index: Int, range: NSRange)] = []
    private var highlightedRanges: [(layout: NSLayoutManager, range: NSRange)] = []
    private var translationViews: [Int: [NSTextView]] = [:]
    private var coveredSource: [Int: NSRange] = [:]
    private var replacements: [Int: ParagraphReplacement] = [:]
    private var completionFades: [Int: ParagraphReplacement] = [:]

    override var isFlipped: Bool { true }

    func show(_ paragraphs: [BooksParagraph], viewport: CGSize, topOffset: CGFloat) -> Bool {
        let texts = paragraphs.map(displayText)
        let viewCounts = paragraphs.map { $0.continuation == nil ? 1 : 2 }
        let canFade = frame.size == viewport && window?.isVisible == true
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        var changedText = paragraphViews.map(\.count) != viewCounts
        if changedText {
            clearShimmer()
            for fade in completionFades.values { fade.finish() }
            completionFades.removeAll()
            for index in Array(translationViews.keys) { removeTranslation(at: index) }
            for view in paragraphViews.joined() { view.removeFromSuperview() }
            paragraphViews = zip(texts, viewCounts).map { makeTextViews($0, count: $1) }
            for view in paragraphViews.joined() { addSubview(view) }
        } else {
            for (index, text) in texts.enumerated() {
                guard let storage = paragraphViews[index].first?.textStorage,
                      let layout = paragraphViews[index].first?.layoutManager,
                      !storage.isEqual(to: text) else { continue }
                completionFades.removeValue(forKey: index)?.finish()
                if canFade, !paragraphs[index].isTranslationPlaceholder,
                   let prefix = translationViews[index]?.first?.string, !prefix.isEmpty, text.string.hasPrefix(prefix) {
                    replacements.removeValue(forKey: index)?.finish()
                    completionFades[index] = ParagraphReplacement.fadeRemainingSource(
                        in: paragraphViews[index], after: coveredSource[index] ?? NSRange()
                    )
                }
                removeTranslation(at: index)
                clearShimmer(for: layout)
                storage.setAttributedString(text)
                changedText = true
            }
        }

        let usesTwoColumns = paragraphs.contains { $0.position.column == .right || $0.continuation != nil }
        let gutter: CGFloat = 24
        let columnWidth = usesTwoColumns ? max(0, (viewport.width - gutter) / 2) : viewport.width
        let firstTop = paragraphs.map { min($0.position.top, $0.continuation?.top ?? $0.position.top) }.min() ?? 0
        let alignedTopOffset = max(topOffset, -firstTop)
        var nextTop: [BooksParagraph.Column: CGFloat] = [:]
        for (paragraph, views) in zip(paragraphs, paragraphViews) {
            let positions = [paragraph.position] + (paragraph.continuation.map { [$0] } ?? [])
            for (position, view) in zip(positions, views) {
                guard let container = view.textContainer else { continue }
                let top = max(nextTop[position.column, default: 0], position.top + alignedTopOffset)
                let height = max(0, min(position.height, viewport.height - top))
                let containerSize = CGSize(width: columnWidth, height: height)
                if container.containerSize != containerSize { container.containerSize = containerSize }
                let x = position.column == .left ? 0 : columnWidth + gutter
                let frame = CGRect(x: x, y: top, width: columnWidth, height: height)
                if view.frame != frame { view.frame = frame }
                nextTop[position.column] = frame.maxY
            }
        }
        for (index, paragraph) in paragraphs.enumerated() {
            if let prefix = paragraph.translationPrefix {
                updateTranslation(at: index, prefix: prefix, canFade: canFade)
            } else {
                removeTranslation(at: index)
            }
        }
        if frame.size != viewport { setFrameSize(viewport) }
        pendingRanges = paragraphs.indices.compactMap { index in
            let text = texts[index]
            guard paragraphs[index].showsTranslationShimmer, text.length > 0 else { return nil }
            var range = NSRange()
            let color = text.attribute(.foregroundColor, at: text.length - 1, effectiveRange: &range) as? NSColor
            return color == .secondaryLabelColor ? (index, range) : nil
        }
        startShimmerIfNeeded()
        return changedText
    }

    private func startShimmerIfNeeded() {
        guard !pendingRanges.isEmpty, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            stopShimmer()
            return
        }
        guard shimmerTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 20, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                if let self { self.updateShimmer() } else { timer.invalidate() }
            }
        }
        shimmerTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stopShimmer() {
        shimmerTimer?.invalidate()
        shimmerTimer = nil
        clearShimmer()
    }

    private func clearShimmer() {
        for (layout, range) in highlightedRanges {
            layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)
        }
        highlightedRanges.removeAll(keepingCapacity: true)
    }

    private func clearShimmer(for layout: NSLayoutManager) {
        highlightedRanges.removeAll { highlight in
            guard highlight.layout === layout else { return false }
            layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: highlight.range)
            return true
        }
    }

    private func updateShimmer() {
        guard window?.isVisible == true, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            stopShimmer()
            return
        }
        clearShimmer()
        let time = ProcessInfo.processInfo.systemUptime
        let edgeColor = NSColor.labelColor.withAlphaComponent(0.68)
        let centerColor = NSColor.labelColor.withAlphaComponent(0.84)
        for (index, pending) in pendingRanges {
            let views = paragraphViews[index]
            guard let layout = views.first?.layoutManager else { continue }
            let width = views.map(\.bounds.width).max() ?? 0
            guard width > 0 else { continue }
            let phase = (time + Double(index) * 0.16).truncatingRemainder(dividingBy: 2.4) / 1.8
            guard phase < 1 else { continue }
            let radius = min(48, width * 0.18)
            let paragraphFrame = views.reduce(CGRect.null) { $0.union($1.frame) }
            let slope = CGFloat(tan(20 * Double.pi / 180))
            let travelInset = radius + paragraphFrame.height / 2 * slope
            let center = CGFloat(phase) * (width + 2 * travelInset) - travelInset
            for view in views {
                guard !view.bounds.isEmpty, let container = view.textContainer else { continue }
                let glyphs = layout.glyphRange(for: container)
                layout.enumerateLineFragments(forGlyphRange: glyphs) { _, line, _, lineGlyphs, _ in
                    guard line.intersects(view.bounds) else { return }
                    // Each line samples the same diagonal band at its height in the paragraph.
                    let bandCenter = center - (view.frame.minY + line.midY - paragraphFrame.midY) * slope
                    for (spread, color) in [(radius, edgeColor), (radius / 2, centerColor)] {
                        let band = CGRect(x: bandCenter - spread, y: line.midY - 0.5, width: 2 * spread, height: 1)
                        let hit = band.intersection(line)
                        guard !hit.isEmpty else { continue }
                        let first = layout.glyphIndex(for: CGPoint(x: hit.minX, y: line.midY), in: container)
                        let last = layout.glyphIndex(for: CGPoint(x: hit.maxX, y: line.midY), in: container)
                        guard first != NSNotFound, last != NSNotFound else { continue }
                        let matchingGlyphs = NSIntersectionRange(
                            lineGlyphs, NSRange(location: min(first, last), length: abs(last - first) + 1)
                        )
                        guard matchingGlyphs.length > 0 else { continue }
                        let characters = layout.characterRange(forGlyphRange: matchingGlyphs, actualGlyphRange: nil)
                        let range = NSIntersectionRange(pending, characters)
                        guard range.length > 0 else { continue }
                        layout.addTemporaryAttribute(.foregroundColor, value: color, forCharacterRange: range)
                        self.highlightedRanges.append((layout, range))
                    }
                }
            }
        }
    }

    private func makeTextViews(_ text: NSAttributedString, count: Int) -> [NSTextView] {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)

        let views = (0..<count).map { index in
            let container = NSTextContainer()
            container.widthTracksTextView = false
            container.heightTracksTextView = false
            container.lineFragmentPadding = 0
            container.lineBreakMode = index == count - 1 ? .byTruncatingTail : .byWordWrapping
            layout.addTextContainer(container)
            let view = NSTextView(frame: .zero, textContainer: container)
            view.wantsLayer = true
            view.layer?.masksToBounds = true
            view.drawsBackground = false
            view.isEditable = false
            view.isSelectable = false
            view.isVerticallyResizable = false
            view.textContainerInset = .zero
            return view
        }
        storage.setAttributedString(text)
        return views
    }

    private func removeTranslation(at index: Int) {
        replacements.removeValue(forKey: index)?.finish()
        if let covered = coveredSource.removeValue(forKey: index), covered.length > 0 {
            paragraphViews[index].first?.layoutManager?.removeTemporaryAttribute(.foregroundColor, forCharacterRange: covered)
        }
        if let views = translationViews.removeValue(forKey: index) {
            for view in views { view.removeFromSuperview() }
        }
    }

    private func updateTranslation(at index: Int, prefix: String, canFade: Bool) {
        let sources = paragraphViews[index]
        guard let sourceLayout = sources.first?.layoutManager else { return }
        let overlays: [NSTextView]
        if let existing = translationViews[index] {
            overlays = existing
        } else {
            overlays = makeTextViews(NSAttributedString(), count: sources.count)
            translationViews[index] = overlays
            for (source, overlay) in zip(sources, overlays) {
                addSubview(overlay, positioned: .above, relativeTo: source)
            }
        }
        guard let translation = overlays.first?.textStorage else { return }
        let text = styledText(normalizedText(prefix), color: .labelColor)
        let textChanged = !translation.isEqual(to: text)
        let geometryChanged = zip(sources, overlays).contains { $0.frame != $1.frame }
        guard textChanged || geometryChanged else { return }
        replacements.removeValue(forKey: index)?.finish()
        clearShimmer(for: sourceLayout)
        for (source, overlay) in zip(sources, overlays) {
            overlay.frame = source.frame
            overlay.textContainer?.containerSize = source.textContainer?.containerSize ?? .zero
        }

        let previousText = translation.string
        if textChanged { translation.setAttributedString(text) }
        let previousMask = coveredSource[index] ?? NSRange()
        let newMask = coveredCharacters(in: sources, by: overlays)
        if textChanged, !geometryChanged || previousText.isEmpty,
           canFade, text.string.hasPrefix(previousText) {
            let incoming = NSRange(location: previousText.utf16.count, length: text.length - previousText.utf16.count)
            let outgoingStart = NSMaxRange(previousMask)
            let outgoing = NSRange(location: outgoingStart, length: max(0, NSMaxRange(newMask) - outgoingStart))
            replacements[index] = ParagraphReplacement.animate(
                incoming: incoming, in: overlays, outgoing: outgoing, in: sources
            )
        }

        if previousMask != newMask {
            if previousMask.length > 0 {
                sourceLayout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: previousMask)
            }
            if newMask.length > 0 {
                sourceLayout.addTemporaryAttribute(.foregroundColor, value: NSColor.clear, forCharacterRange: newMask)
            }
            coveredSource[index] = newMask
        }
    }

    private func coveredCharacters(in sources: [NSTextView], by overlays: [NSTextView]) -> NSRange {
        guard let sourceLayout = sources.first?.layoutManager, let storage = sources.first?.textStorage,
              let overlayLayout = overlays.first?.layoutManager else { return NSRange() }
        // In a continued paragraph, every source fragment before the last translated fragment is covered.
        guard let last = overlays.lastIndex(where: { view in
            view.textContainer.map { overlayLayout.glyphRange(for: $0).length > 0 } ?? false
        }), let targetContainer = overlays[last].textContainer,
            let sourceContainer = sources[last].textContainer else { return NSRange() }

        let targetGlyphs = overlayLayout.glyphRange(for: targetContainer)
        let boundary = overlayLayout.lineFragmentUsedRect(forGlyphAt: NSMaxRange(targetGlyphs) - 1, effectiveRange: nil)
        let sourceGlyphs = sourceLayout.glyphRange(for: sourceContainer)
        var coveredEnd = sourceLayout.characterRange(
            forGlyphRange: NSRange(location: sourceGlyphs.location, length: 0), actualGlyphRange: nil
        ).location
        sourceLayout.enumerateLineFragments(forGlyphRange: sourceGlyphs) { _, line, _, glyphs, stop in
            let glyphEnd: Int
            if line.midY < boundary.minY {
                glyphEnd = NSMaxRange(glyphs)
            } else if line.midY <= boundary.maxY, boundary.maxX > line.minX {
                let glyph = sourceLayout.glyphIndex(for: CGPoint(x: boundary.maxX, y: line.midY), in: sourceContainer)
                guard NSLocationInRange(glyph, glyphs) else { return }
                glyphEnd = glyph + 1
                stop.pointee = true
            } else {
                stop.pointee = true
                return
            }
            let characters = sourceLayout.characterRange(
                forGlyphRange: NSRange(location: glyphs.location, length: glyphEnd - glyphs.location), actualGlyphRange: nil
            )
            coveredEnd = NSMaxRange(characters)
        }
        if coveredEnd > 0, coveredEnd <= storage.length {
            coveredEnd = max(coveredEnd, NSMaxRange(storage.doubleClick(at: coveredEnd - 1)))
        }
        return NSRange(location: 0, length: min(coveredEnd, storage.length))
    }

    private func normalizedText(_ text: String) -> String {
        text.components(separatedBy: .newlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    private func displayText(_ paragraph: BooksParagraph) -> NSAttributedString {
        styledText(normalizedText(paragraph.text), color: paragraph.isTranslationPlaceholder ? .secondaryLabelColor : .labelColor)
    }

    private func styledText(_ text: String, color: NSColor) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        return NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 14),
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ])
    }
}
