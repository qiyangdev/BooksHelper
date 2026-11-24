import AppKit
import QuartzCore
import SwiftUI

final class BooksReadingMat: NSView {
    private static let textInset: CGFloat = 16
    private static let toolbarHeight: CGFloat = 33

    private let reader = NSScrollView()
    private let summaryReader = NSTextView.scrollableTextView()
    private let modePicker = BooksModePicker(labels: ["Translate", "Summary"], trackingMode: .selectOne, target: nil, action: nil)
    private let document = BooksParagraphDocument()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let loadingIndicator = NSProgressIndicator()
    private let edge = BooksReadingMatEdge()
    private let backdropMask = CALayer()
    private var content: BooksPageContent?
    private var unavailableView: TranslationUnavailableHostingView?
    var onRetryTranslation: (() -> Void)?
    var onSelectMode: ((BooksSidebarMode) -> Void)?
    private var mode: BooksSidebarMode = .translation
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
        summaryReader.drawsBackground = false
        summaryReader.isHidden = true
        if let summary = summaryReader.documentView as? NSTextView {
            summary.drawsBackground = false
            summary.isEditable = false
            summary.isRichText = false
            summary.font = .systemFont(ofSize: 14)
            summary.textContainerInset = .zero
            summary.textContainer?.lineFragmentPadding = 0
        }
        modePicker.target = self
        modePicker.action = #selector(selectSidebarMode(_:))
        modePicker.selectedSegment = BooksSidebarMode.translation.rawValue
        modePicker.segmentStyle = .automatic
        modePicker.setAccessibilityLabel("Sidebar Mode")
        modePicker.isHidden = true
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
        addSubview(summaryReader)
        addSubview(statusLabel)
        addSubview(loadingIndicator)
        addSubview(modePicker)
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
        let toolbarHeight = Self.toolbarHeight
        let textFrame = CGRect(
            x: bounds.minX + textInset, y: bounds.minY + textInset,
            width: max(0, bounds.width - 2 * textInset), height: max(0, bounds.height - 2 * textInset - toolbarHeight)
        )
        summaryReader.isHidden = true
        let showsToolbar = rightWidth >= BooksSidebarGeometry.minimumExpandedRightWidth && content != nil && !textFrame.isEmpty
        modePicker.isHidden = !showsToolbar
        if showsToolbar {
            let size = modePicker.fittingSize
            modePicker.frame = CGRect(x: bounds.midX - size.width / 2, y: textFrame.maxY + 4, width: size.width, height: size.height)
        }
        guard rightWidth >= BooksSidebarGeometry.minimumExpandedRightWidth, let content, !textFrame.isEmpty else {
            document.stopShimmer()
            reader.isHidden = true
            statusLabel.isHidden = true
            unavailableView?.isHidden = true
            setLoadingIndicatorVisible(false)
            return
        }
        if case .translationUnavailable = content {
            document.stopShimmer()
            reader.isHidden = true
            statusLabel.isHidden = true
            setLoadingIndicatorVisible(false)
            unavailableView?.frame = textFrame
            unavailableView?.isHidden = false
            return
        }
        unavailableView?.isHidden = true
        if case .summary(let text) = content {
            showSummary(text, in: textFrame, isPlaceholder: false)
            return
        }
        if content == .summarizing || (content == .loading && mode == .summary) {
            showSummary(String(localized: "Summarizing…"), in: textFrame, isPlaceholder: true)
            return
        }
        guard case .paragraphs(let paragraphs) = content else {
            document.stopShimmer()
            reader.isHidden = true
            showStatus(content, in: textFrame)
            return
        }

        statusLabel.isHidden = true
        setLoadingIndicatorVisible(false)
        if reader.frame != textFrame { reader.frame = textFrame }
        let changedText = document.show(
            paragraphs, viewport: textFrame.size, topOffset: outerMargin - textInset - toolbarHeight
        )
        if changedText {
            reader.contentView.scroll(to: .zero)
            reader.reflectScrolledClipView(reader.contentView)
        }
        reader.isHidden = false
    }

    private func showSummary(_ text: String, in frame: CGRect, isPlaceholder: Bool) {
        document.stopShimmer()
        reader.isHidden = true
        statusLabel.isHidden = true
        setLoadingIndicatorVisible(false)
        summaryReader.frame = frame
        if let summary = summaryReader.documentView as? NSTextView {
            let color: NSColor = isPlaceholder ? .secondaryLabelColor : .labelColor
            if summary.string != text || summary.textColor != color {
                let extendsSummary = !isPlaceholder && summary.textColor == color && text.hasPrefix(summary.string)
                if extendsSummary, let storage = summary.textStorage {
                    let suffix = String(text.dropFirst(summary.string.count))
                    storage.append(NSAttributedString(string: suffix, attributes: [
                        .font: NSFont.systemFont(ofSize: 14), .foregroundColor: color,
                    ]))
                } else {
                    summary.string = text
                    summary.textColor = color
                    summaryReader.contentView.scroll(to: .zero)
                }
            }
        }
        summaryReader.isHidden = false
    }

    @objc private func selectSidebarMode(_ picker: NSSegmentedControl) {
        guard let mode = BooksSidebarMode(rawValue: picker.selectedSegment), mode != self.mode else { return }
        self.mode = mode
        needsLayout = true
        onSelectMode?(mode)
    }

    func show(_ content: BooksPageContent?) {
        guard self.content != content else { return }
        self.content = content
        if case .translationUnavailable(let message) = content {
            let title: LocalizedStringKey = mode == .summary ? "Summary Unavailable" : "Translation Unavailable"
            let root = TranslationUnavailableView(title: title, message: message) { [weak self] in
                self?.onRetryTranslation?()
            }
            if let unavailableView {
                unavailableView.rootView = root
            } else {
                let view = TranslationUnavailableHostingView(rootView: root)
                view.sizingOptions = []
                view.isHidden = true
                addSubview(view, positioned: .below, relativeTo: edge)
                unavailableView = view
            }
        }
        needsLayout = true
    }

    private func showStatus(_ content: BooksPageContent, in frame: CGRect) {
        let text: String
        let isLoading: Bool
        switch content {
        case .loading:
            text = mode == .summary ? String(localized: "Summarizing…") : String(localized: "Translating…")
            isLoading = true
        case .noText:
            text = String(localized: "No readable text on this page.")
            isLoading = false
        case .translationUnavailable, .paragraphs, .summary, .summarizing:
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

private final class BooksModePicker: NSSegmentedControl {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct TranslationUnavailableView: View {
    let title: LocalizedStringKey
    let message: String
    let onRetry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: "exclamationmark.triangle")
        } description: {
            Text(verbatim: message)
        } actions: {
            Button("Retry", action: onRetry)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private final class TranslationUnavailableHostingView: NSHostingView<TranslationUnavailableView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func shouldDelayWindowOrdering(for event: NSEvent) -> Bool { true }
}
