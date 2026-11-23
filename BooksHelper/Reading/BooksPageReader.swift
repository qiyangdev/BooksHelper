import ApplicationServices
import CoreGraphics
import Foundation
import os

nonisolated struct BooksWindowCandidate: Sendable {
    let number: Int
    let frame: CGRect
}

nonisolated enum BooksPageUpdate: Sendable {
    case readingWindow(Int, BooksReadingPage?)
    case noReadingWindow
    case retry
}

nonisolated enum BooksPageReader {
    private static let log = Logger(subsystem: "org.bookshelper.BooksHelper", category: "BooksText")

    static func read(
        processID: pid_t, candidates: [BooksWindowCandidate], currentWindow: Int?, includeText: Bool = true
    ) -> BooksPageUpdate {
        guard AXIsProcessTrusted() else { return .noReadingWindow }

        let application = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(application, 0.25)
        guard let windows = attribute(kAXWindowsAttribute, of: application) as? [AXUIElement] else { return .retry }
        let standardWindows = windows.compactMap { window -> (AXUIElement, CGRect)? in
            guard attribute(kAXRoleAttribute, of: window) as? String == kAXWindowRole,
                  attribute(kAXSubroleAttribute, of: window) as? String == kAXStandardWindowSubrole,
                  attribute(kAXIdentifierAttribute, of: window) as? String == "SceneWindow",
                  let bounds = frame(of: window) else { return nil }
            return (window, bounds)
        }

        var checkedCurrentWindow = false
        let deadline = ContinuousClock.now + .seconds(1)
        for candidate in candidates {
            guard ContinuousClock.now < deadline else { return .retry }
            guard let (window, windowFrame) = standardWindows.first(where: { matchesWindow($0.1, candidate.frame) }) else {
                continue
            }
            if candidate.number == currentWindow { checkedCurrentWindow = true }
            let pages = readingAreas(in: window, deadline: deadline)
            guard !pages.isEmpty else { continue }
            return .readingWindow(
                candidate.number,
                includeText ? readPages(pages, viewport: windowFrame, deadline: deadline) : nil
            )
        }

        // Core Graphics and AX can briefly report different positions during a move or a popover transition.
        if let currentWindow, !checkedCurrentWindow, candidates.contains(where: { $0.number == currentWindow }) {
            return .retry
        }
        return .noReadingWindow
    }

    private static func readingAreas(
        in window: AXUIElement, deadline: ContinuousClock.Instant
    ) -> [AXUIElement] {
        var pending = Array(children(of: window).reversed())
        var pages: [AXUIElement] = []
        var remainingNodes = 400
        while remainingNodes > 0, ContinuousClock.now < deadline, let element = pending.popLast() {
            remainingNodes -= 1
            switch attribute(kAXRoleAttribute, of: element) as? String {
            case "AXWebArea": pages.append(element)
            case kAXPopoverRole, kAXSheetRole, kAXWindowRole, kAXMenuRole: break
            default: pending.append(contentsOf: children(of: element).reversed())
            }
        }
        return pages
    }

    private static func readPages(
        _ pages: [AXUIElement], viewport: CGRect, deadline: ContinuousClock.Instant
    ) -> BooksReadingPage? {
        var textBlocks: [(text: String, frame: CGRect)] = []
        var remainingNodes = 800
        for page in pages {
            collectText(
                in: page, viewport: viewport, textBlocks: &textBlocks,
                remainingNodes: &remainingNodes, deadline: deadline
            )
        }
        log.debug("Books reading tree: \(800 - remainingNodes) elements visited, \(textBlocks.count) paragraphs")
        if textBlocks.isEmpty {
            if ContinuousClock.now >= deadline { return nil }
            return BooksReadingPage(content: .noText, isTwoColumn: nil)
        }
        let divider = BooksPageLayout.columnDivider(textFrames: textBlocks.map(\.frame), windowWidth: viewport.width)
        let isTwoColumn = divider != nil
        let layout = isTwoColumn || (remainingNodes > 0 && ContinuousClock.now < deadline) ? isTwoColumn : nil
        let paragraphs = BooksPageLayout.makeParagraphs(from: textBlocks, in: viewport, divider: divider)
        return BooksReadingPage(content: .paragraphs(paragraphs), isTwoColumn: layout)
    }

    static func matchesWindow(_ first: CGRect, _ second: CGRect) -> Bool {
        abs(first.minX - second.minX) <= 4
            && abs(first.minY - second.minY) <= 4
            && abs(first.width - second.width) <= 4
            && abs(first.height - second.height) <= 4
    }

    private static func collectText(
        in element: AXUIElement, viewport: CGRect,
        textBlocks: inout [(text: String, frame: CGRect)],
        remainingNodes: inout Int, deadline: ContinuousClock.Instant
    ) {
        guard remainingNodes > 0, ContinuousClock.now < deadline else { return }
        remainingNodes -= 1

        let role = attribute(kAXRoleAttribute, of: element) as? String
        if role == kAXToolbarRole || role == kAXButtonRole || role == kAXPopoverRole || role == kAXSheetRole {
            return
        }

        // On continuation pages, Books can position the web area offscreen while its
        // paragraph nodes still intersect the reading window. Check the text itself.
        if role == kAXStaticTextRole || role == "AXHeading",
           let frame = frame(of: element), !frame.intersection(viewport).isEmpty,
           let text = text(of: element) {
            if textBlocks.last?.text != text || textBlocks.last?.frame != frame {
                textBlocks.append((text, frame))
            }
            return
        }

        for child in children(of: element) {
            if remainingNodes == 0 || ContinuousClock.now >= deadline { break }
            collectText(
                in: child, viewport: viewport,
                textBlocks: &textBlocks, remainingNodes: &remainingNodes, deadline: deadline
            )
        }
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        attribute(kAXVisibleChildrenAttribute, of: element) as? [AXUIElement]
            ?? attribute(kAXChildrenAttribute, of: element) as? [AXUIElement] ?? []
    }

    private static func text(of element: AXUIElement) -> String? {
        for name in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
            if let value = attribute(name, of: element) as? String {
                let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { return text }
            }
        }
        return nil
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let position = attribute(kAXPositionAttribute, of: element),
              let size = attribute(kAXSizeAttribute, of: element),
              CFGetTypeID(position) == AXValueGetTypeID(),
              CFGetTypeID(size) == AXValueGetTypeID() else { return nil }

        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    private static func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
}
