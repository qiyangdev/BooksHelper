import AppKit
import QuartzCore

final class BooksReadingMat: NSView {
    private static let textInset: CGFloat = 16

    private let reader = NSScrollView()
    private let document = BooksParagraphDocument()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let loadingIndicator = NSProgressIndicator()
    private let edge = BooksReadingMatEdge()
    private let backdropMask = CALayer()
    private var content: BooksPageContent?
    var onResize: ((CGFloat) -> Void)? {
        get { edge.onResize }
        set { edge.onResize = newValue }
    }
    var onResizeEnded: (() -> Void)? {
        get { edge.onResizeEnded }
        set { edge.onResizeEnded = newValue }
    }
    var resizeDirections: NSCursor.FrameResizeDirection.Set {
        get { edge.resizeDirections }
        set { edge.resizeDirections = newValue }
    }
    var hasRoomForText: Bool { rightWidth > 2 * Self.textInset }
    var outerMargin = BooksSidebarGeometry.margin {
        didSet {
            if oldValue != outerMargin { needsLayout = true }
        }
    }
    var backdropWidth: CGFloat = 0 {
        didSet {
            if oldValue != backdropWidth { needsLayout = true }
        }
    }
    var rightWidth = BooksSidebarGeometry.margin {
        didSet {
            if oldValue != rightWidth { needsLayout = true }
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        backdropMask.cornerCurve = .continuous
        backdropMask.backgroundColor = NSColor.black.cgColor
        layer?.mask = backdropMask
        reader.drawsBackground = false
        reader.hasVerticalScroller = false
        reader.verticalScrollElasticity = .none
        reader.isHidden = true
        reader.documentView = document
        statusLabel.alignment = .center
        statusLabel.font = .systemFont(ofSize: 14)
        statusLabel.textColor = .labelColor
        statusLabel.maximumNumberOfLines = 0
        statusLabel.isHidden = true
        loadingIndicator.style = .spinning
        loadingIndicator.controlSize = .small
        loadingIndicator.isIndeterminate = true
        loadingIndicator.isDisplayedWhenStopped = false
        loadingIndicator.sizeToFit()
        loadingIndicator.isHidden = true
        edge.setAccessibilityElement(true)
        edge.setAccessibilityRole(.splitter)
        edge.setAccessibilityLabel("Resize Reading Area")
        addSubview(reader)
        addSubview(statusLabel)
        addSubview(loadingIndicator)
        addSubview(edge)
    }

    required init?(coder: NSCoder) { nil }

    override func shouldDelayWindowOrdering(for event: NSEvent) -> Bool { true }

    func endInteraction() { edge.endInteraction() }
    func updateHoverCursor() { edge.updateHoverCursor() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        // Fully transparent pixels pass through mouse events.
        layer?.backgroundColor = BooksReadingMatBackground.fill.withAlphaComponent(0.01).cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let maskWidth = max(backdropWidth, bounds.width)
        backdropMask.frame = CGRect(x: bounds.maxX - maskWidth, y: bounds.minY, width: maskWidth, height: bounds.height)
        backdropMask.cornerRadius = BooksReadingMatBackground.cornerRadius(in: backdropMask.bounds, margin: outerMargin)
        let edgeWidth = min(BooksSidebarGeometry.margin, bounds.width)
        edge.frame = CGRect(x: bounds.maxX - edgeWidth, y: bounds.minY, width: edgeWidth, height: bounds.height)
        let textInset = Self.textInset
        let textFrame = CGRect(
            x: bounds.minX + textInset, y: bounds.minY + textInset,
            width: max(0, bounds.width - 2 * textInset), height: max(0, bounds.height - 2 * textInset)
        )
        guard rightWidth >= BooksSidebarGeometry.minimumExpandedRightWidth, let content, !textFrame.isEmpty else {
            reader.isHidden = true
            statusLabel.isHidden = true
            setLoadingIndicatorVisible(false)
            return
        }
        guard case .paragraphs(let paragraphs) = content else {
            reader.isHidden = true
            showStatus(content, in: textFrame)
            return
        }

        statusLabel.isHidden = true
        setLoadingIndicatorVisible(false)
        if reader.frame != textFrame { reader.frame = textFrame }
        let changedText = document.show(
            paragraphs, viewport: textFrame.size, topOffset: outerMargin - textInset
        )
        if changedText {
            reader.contentView.scroll(to: .zero)
            reader.reflectScrolledClipView(reader.contentView)
        }
        reader.isHidden = false
    }

    func show(_ content: BooksPageContent?) {
        guard self.content != content else { return }
        self.content = content
        needsLayout = true
    }

    private func showStatus(_ content: BooksPageContent, in frame: CGRect) {
        let text: String
        let isLoading: Bool
        switch content {
        case .loading, .translating:
            text = String(localized: "Translating…")
            isLoading = true
        case .noText:
            text = String(localized: "No readable text on this page.")
            isLoading = false
        case .translationUnavailable(let message):
            text = message
            isLoading = false
        case .paragraphs:
            return
        }
        if statusLabel.stringValue != text { statusLabel.stringValue = text }
        statusLabel.preferredMaxLayoutWidth = frame.width
        let indicatorSize = loadingIndicator.frame.size
        let spacing: CGFloat = 8
        let showsIndicator = isLoading && frame.height > indicatorSize.height + spacing
        let indicatorSpace = showsIndicator ? indicatorSize.height + spacing : 0
        let height = min(frame.height - indicatorSpace, ceil(statusLabel.sizeThatFits(frame.size).height))
        statusLabel.frame = CGRect(
            x: frame.minX, y: frame.midY - (height + indicatorSpace) / 2, width: frame.width, height: height
        )
        if showsIndicator {
            loadingIndicator.setFrameOrigin(
                CGPoint(x: frame.midX - indicatorSize.width / 2, y: statusLabel.frame.maxY + spacing)
            )
        }
        setLoadingIndicatorVisible(showsIndicator)
        statusLabel.isHidden = false
    }

    private func setLoadingIndicatorVisible(_ visible: Bool) {
        guard loadingIndicator.isHidden == visible else { return }
        loadingIndicator.isHidden = !visible
        if visible {
            loadingIndicator.startAnimation(nil)
        } else {
            loadingIndicator.stopAnimation(nil)
        }
    }
}

private final class BooksParagraphDocument: NSView {
    private var paragraphViews: [[NSTextView]] = []

    override var isFlipped: Bool { true }

    func show(_ paragraphs: [BooksParagraph], viewport: CGSize, topOffset: CGFloat) -> Bool {
        let texts = paragraphs.map { paragraph in
            // Let the sidebar width determine line breaks within each retained paragraph.
            return paragraph.text.components(separatedBy: .newlines).filter { !$0.isEmpty }.joined(separator: " ")
        }
        let viewCounts = paragraphs.map { $0.continuation == nil ? 1 : 2 }
        let changedText = paragraphViews.compactMap { $0.first?.string } != texts
            || paragraphViews.map(\.count) != viewCounts
        if changedText {
            for view in paragraphViews.joined() { view.removeFromSuperview() }
            paragraphViews = zip(texts, viewCounts).map { makeTextViews($0, count: $1) }
            for view in paragraphViews.joined() { addSubview(view) }
        }

        let usesTwoColumns = paragraphs.contains { $0.position.column == .right || $0.continuation != nil }
        let gutter: CGFloat = 24
        let columnWidth = usesTwoColumns ? max(0, (viewport.width - gutter) / 2) : viewport.width
        var nextTop: [BooksParagraph.Column: CGFloat] = [:]
        for (paragraph, views) in zip(paragraphs, paragraphViews) {
            let positions = [paragraph.position] + (paragraph.continuation.map { [$0] } ?? [])
            for (position, view) in zip(positions, views) {
                guard let container = view.textContainer else { continue }
                let top = max(nextTop[position.column, default: 0], position.top + topOffset)
                let height = max(0, min(position.height, viewport.height - top))
                let containerSize = CGSize(width: columnWidth, height: height)
                if container.containerSize != containerSize { container.containerSize = containerSize }
                let x = position.column == .left ? 0 : columnWidth + gutter
                let frame = CGRect(x: x, y: top, width: columnWidth, height: height)
                if view.frame != frame { view.frame = frame }
                nextTop[position.column] = frame.maxY
            }
        }
        if frame.size != viewport { setFrameSize(viewport) }
        return changedText
    }

    private func makeTextViews(_ text: String, count: Int) -> [NSTextView] {
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
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        storage.setAttributedString(NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ]))
        return views
    }
}
