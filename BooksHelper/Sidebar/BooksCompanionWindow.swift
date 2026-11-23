import AppKit
import CoreGraphics
import QuartzCore

final class BooksCompanionWindow: NSObject {
    private struct Placement: Equatable {
        let windowNumber: Int
        var frame: CGRect
        let seam: CGFloat
        let widthLimits: ClosedRange<CGFloat>
    }

    private let panel = BooksCompanionPanel(
        contentRect: .zero,
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: false
    )
    private let controlsPanel = BooksCompanionPanel(
        contentRect: .zero,
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: false
    )
    private let mat = BooksReadingMat()
    private let backdrop = BooksReadingMatBackground()
    private let translation = BooksTranslation()
    private var requestedRightWidth = BooksSidebarGeometry.minimumExpandedRightWidth
    private var isTwoColumn = false
    private var twoColumnWidthOverride: CGFloat?
    private var resizeGesture: (initialWidth: CGFloat, width: CGFloat)?
    private var timer: Timer?
    private var booksProcessID: pid_t?
    private var readingWindow: Int?
    private var nextPageRead = 0.0
    private var pageRead: Task<Void, Never>?
    private var pageContent: BooksPageContent = .loading
    private var placement: Placement?
    private var transition: BooksSidebarGeometry.Transition?
    private var animationTimer: Timer?
    private var dragMonitor: Any?
    private var draggedWindow: Int?
    private var trackingDisplayLink: CADisplayLink?
#if DEBUG
    private var fixtureWindow: NSWindow?
#endif

    var translationMenu: NSMenu { translation.menu }

    override init() {
        super.init()
        for window in [panel, controlsPanel] {
            window.isOpaque = false
            window.backgroundColor = .clear
            window.isMovable = false
            window.hidesOnDeactivate = false
            window.isExcludedFromWindowsMenu = true
            window.collectionBehavior = [.moveToActiveSpace, .transient, .ignoresCycle]
        }
        panel.contentView = backdrop
        panel.hasShadow = true
        // Only the strip outside Books receives events. AppKit can raise that
        // window on mouse-up without painting over the reading window.
        panel.ignoresMouseEvents = true
        controlsPanel.contentView = mat
        controlsPanel.hasShadow = false
        controlsPanel.acceptsMouseMovedEvents = true
        mat.onResize = { [weak self] delta in self?.resize(by: delta) }
        mat.onResizeEnded = { [weak self] in self?.finishResize() }
        translation.installHost(in: mat)
        translation.onOutputChange = { [weak self] _ in self?.showTranslation() }
    }

    func start() {
        translation.start()
        dragMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) {
            [weak self] event in
            MainActor.assumeIsolated { self?.handleExternalMouse(event) }
        }
        update()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.update()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

#if DEBUG
    func startForUITests() {
        guard let screen = NSScreen.screens.first else { return }
        let visibleFrame = screen.visibleFrame
        let frame = CGRect(
            x: visibleFrame.minX + 32, y: visibleFrame.midY - 180,
            width: max(320, min(440, (visibleFrame.width - 80) / 2)), height: 360
        )
        let window = NSWindow(
            contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false
        )
        window.title = "BooksHelper Reading Fixture"
        // XCUIAutomation cannot query an accessory app's status item directly.
        let menuButton = NSButton(title: "Translation", target: self, action: #selector(showFixtureMenu(_:)))
        menuButton.frame = CGRect(x: 16, y: 16, width: 160, height: 32)
        window.contentView?.addSubview(menuButton)
        let columnsButton = NSButton(
            title: "Toggle Reading Columns", target: self, action: #selector(toggleFixtureColumns)
        )
        columnsButton.frame = CGRect(x: 16, y: 56, width: 180, height: 32)
        window.contentView?.addSubview(columnsButton)
        fixtureWindow = window
        window.orderFrontRegardless()
        translation.startForUITests()
        pageContent = fixturePage(isTwoColumn: false).content
        let windowFrame = window.frame
        let quartzFrame = CGRect(
            x: windowFrame.minX, y: screen.frame.maxY - windowFrame.maxY,
            width: windowFrame.width, height: windowFrame.height
        )
        if place(around: quartzFrame, windowNumber: window.windowNumber, screens: [screen], primaryScreen: screen) {
            panel.order(.below, relativeTo: window.windowNumber)
            controlsPanel.order(.below, relativeTo: window.windowNumber)
        }
    }

    @objc private func showFixtureMenu(_ sender: NSButton) {
        translationMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: sender)
    }

    @objc private func toggleFixtureColumns() {
        setReadingPage(fixturePage(isTwoColumn: !isTwoColumn))
    }

    private func fixturePage(isTwoColumn: Bool) -> BooksReadingPage {
        var paragraphs = [BooksParagraph(text: "A fixed reading page.", top: 72, height: 80)]
        if isTwoColumn {
            paragraphs.append(BooksParagraph(text: "The second page.", top: 72, height: 80, column: .right))
        }
        return BooksReadingPage(content: .paragraphs(paragraphs), isTwoColumn: isTwoColumn)
    }
#endif

    func stop() {
        timer?.invalidate()
        timer = nil
        if let dragMonitor { NSEvent.removeMonitor(dragMonitor) }
        dragMonitor = nil
        pageRead?.cancel()
        hidePanel()
        translation.stop()
    }

    private func resize(by delta: CGFloat) {
        guard let placement else { return }
        let width = placement.widthLimits.clamp(mat.rightWidth + delta)
        resizeGesture = (resizeGesture?.initialWidth ?? mat.rightWidth, width)
        applyRightWidth(width)
    }

    private func finishResize() {
        guard let resizeGesture else { return }
        self.resizeGesture = nil
        guard let placement else { return }
        let width = BooksSidebarGeometry.settledRightWidth(
            resizeGesture.width, from: resizeGesture.initialWidth, limits: placement.widthLimits
        )
        if isTwoColumn, width > BooksSidebarGeometry.margin {
            requestedRightWidth = max(requestedRightWidth, BooksSidebarGeometry.minimumExpandedRightWidth)
            twoColumnWidthOverride = width
        } else {
            requestedRightWidth = width
        }
        applyRightWidth(width, animate: true)
    }

    private func preferredWidth(within limits: ClosedRange<CGFloat>) -> CGFloat {
        if isTwoColumn, requestedRightWidth > BooksSidebarGeometry.margin {
            return limits.clamp(twoColumnWidthOverride ?? limits.upperBound)
        }
        return limits.clamp(requestedRightWidth)
    }

    private func applyRightWidth(_ width: CGFloat, animate: Bool = false) {
        guard var placement else { return }
        let currentWidth = mat.rightWidth
        let targetWidth = placement.frame.maxX - placement.seam
        guard width != currentWidth || width != targetWidth else { return }
        placement.frame.size.width = placement.seam - placement.frame.minX + width
        self.placement = placement
        stopTransition()
        if animate && width != currentWidth {
            startTransition(width: currentWidth, margin: backdrop.outerMargin, opacity: panel.alphaValue, duration: 0.22)
        }
        applyPlacement()
        refreshContent()
    }

    private func update() {
        let screens = NSScreen.screens
        guard let books = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.iBooksX").first,
              !books.isHidden,
              let primaryScreen = screens.first,
              let windows = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
              ) as? [[String: Any]] else {
            booksProcessID = nil
            readingWindow = nil
            hidePanel()
            return
        }

        if booksProcessID != books.processIdentifier {
            booksProcessID = books.processIdentifier
            readingWindow = nil
            nextPageRead = 0
        }
        let candidates = windows.compactMap { window -> BooksWindowCandidate? in
            guard window[kCGWindowOwnerPID as String] as? pid_t == books.processIdentifier,
                  window[kCGWindowLayer as String] as? Int == 0,
                  let number = window[kCGWindowNumber as String] as? Int,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
            return BooksWindowCandidate(number: number, frame: frame)
        }
        if candidates.isEmpty {
            readingWindow = nil
            nextPageRead = 0
        } else if trackingDisplayLink == nil {
            updatePage(processID: books.processIdentifier, candidates: candidates)
        }

        guard let windowNumber = readingWindow,
              let quartzFrame = candidates.first(where: { $0.number == windowNumber })?.frame,
              let index = windows.firstIndex(where: { $0[kCGWindowNumber as String] as? Int == windowNumber }),
              place(around: quartzFrame, windowNumber: windowNumber, screens: screens, primaryScreen: primaryScreen) else {
            hidePanel()
            return
        }

        let following = windows.dropFirst(index + 1).prefix(2)
            .compactMap { $0[kCGWindowNumber as String] as? Int }
        if following != [controlsPanel.windowNumber, panel.windowNumber] {
            // Leave the backdrop in place if only the interactive strip moved.
            let neighbor = windows.dropFirst(index + 1).first {
                $0[kCGWindowNumber as String] as? Int != controlsPanel.windowNumber
            }
            if !panel.isVisible || neighbor?[kCGWindowNumber as String] as? Int != panel.windowNumber {
                panel.order(.below, relativeTo: windowNumber)
            }
            controlsPanel.order(.below, relativeTo: windowNumber)
        }
        mat.updateHoverCursor()
    }

    private func place(
        around quartzFrame: CGRect, windowNumber: Int, screens: [NSScreen], primaryScreen: NSScreen
    ) -> Bool {
        // Core Graphics measures Y down from the primary display's top edge.
        let booksFrame = CGRect(
            x: quartzFrame.minX, y: primaryScreen.frame.maxY - quartzFrame.maxY,
            width: quartzFrame.width, height: quartzFrame.height
        )
        let screen = screens.max {
            intersectionArea($0.frame, booksFrame) < intersectionArea($1.frame, booksFrame)
        }
        guard let screen, screen.frame.intersects(booksFrame) else { return false }

        let widthLimits = BooksSidebarGeometry.rightWidthRange(
            booksWidth: booksFrame.width, availableWidth: screen.visibleFrame.maxX - booksFrame.maxX
        )
        let width = resizeGesture.map { widthLimits.clamp($0.width) } ?? preferredWidth(within: widthLimits)
        let frame = BooksSidebarGeometry.attachedFrame(to: booksFrame, rightWidth: width)
        let newAttachment = !panel.isVisible || placement?.windowNumber != windowNumber
        let newPlacement = Placement(
            windowNumber: windowNumber, frame: frame, seam: booksFrame.maxX,
            widthLimits: widthLimits
        )
        guard newAttachment || placement != newPlacement else { return true }
        placement = newPlacement
        if newAttachment {
            startTransition(width: 0, margin: 0, opacity: 0, duration: 0.24)
        }
        applyPlacement()
        return true
    }

    private func handleExternalMouse(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            stopTrackingDrag()
            guard let readingWindow, placement?.windowNumber == readingWindow,
                  NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0) == readingWindow
            else { return }
            draggedWindow = readingWindow
        case .leftMouseDragged:
            guard draggedWindow != nil, trackingDisplayLink == nil else { return }
            followDraggedWindow()
            let displayLink = panel.displayLink(target: self, selector: #selector(trackDragFrame))
            displayLink.add(to: .main, forMode: .common)
            trackingDisplayLink = displayLink
        case .leftMouseUp:
            if trackingDisplayLink != nil { followDraggedWindow() }
            stopTrackingDrag()
        default:
            break
        }
    }

    @objc private func trackDragFrame() {
        followDraggedWindow()
        if NSEvent.pressedMouseButtons & 1 == 0 { stopTrackingDrag() }
    }

    private func followDraggedWindow() {
        let screens = NSScreen.screens
        guard let draggedWindow, placement?.windowNumber == draggedWindow, panel.isVisible,
              let primaryScreen = screens.first,
              let windows = CGWindowListCopyWindowInfo(
                .optionIncludingWindow, CGWindowID(draggedWindow)
              ) as? [[String: Any]],
              let bounds = windows.first?[kCGWindowBounds as String] as? [String: Any],
              let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return }
        // Sample only the attached window on this path. Discovery, stacking and AX text stay on the slow timer.
        _ = place(around: frame, windowNumber: draggedWindow, screens: screens, primaryScreen: primaryScreen)
    }

    private func stopTrackingDrag() {
        trackingDisplayLink?.invalidate()
        trackingDisplayLink = nil
        draggedWindow = nil
    }

    private func startTransition(width: CGFloat, margin: CGFloat, opacity: CGFloat, duration: TimeInterval) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        transition = BooksSidebarGeometry.Transition(
            startedAt: ProcessInfo.processInfo.systemUptime, duration: duration,
            initialWidth: width, initialMargin: margin, initialOpacity: opacity
        )
        refreshContent()
        guard animationTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applyPlacement()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }

    private func applyPlacement() {
        guard let placement else { return }
        let targetWidth = placement.frame.maxX - placement.seam
        let limits = placement.widthLimits
        var width = targetWidth
        var margin = BooksSidebarGeometry.margin
        var opacity: CGFloat = 1
        var finished = false
        if let transition {
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                finished = true
            } else {
                let sample = transition.sample(at: ProcessInfo.processInfo.systemUptime, targetWidth: targetWidth)
                opacity = sample.opacity
                finished = sample.finished
                if !finished {
                    let scale = panel.backingScaleFactor
                    margin = (sample.margin * scale).rounded() / scale
                    width = min(limits.upperBound, max(margin, (sample.width * scale).rounded() / scale))
                }
            }
        }
        let frame = BooksSidebarGeometry.attachmentFrame(
            fitting: placement.frame, seam: placement.seam, margin: margin, rightWidth: width
        )

        let hadRoomForText = mat.hasRoomForText
        mat.rightWidth = width
        mat.backdropWidth = frame.width
        mat.outerMargin = margin
        backdrop.outerMargin = margin
        if panel.frame.size != frame.size {
            panel.setFrame(frame, display: true)
            panel.invalidateShadow()
        } else if panel.frame.origin != frame.origin {
            panel.setFrameOrigin(frame.origin)
        }
        let controlsFrame = CGRect(x: placement.seam, y: frame.minY, width: width, height: frame.height)
        if controlsPanel.frame.size != controlsFrame.size {
            controlsPanel.setFrame(controlsFrame, display: true)
        } else if controlsPanel.frame.origin != controlsFrame.origin {
            controlsPanel.setFrameOrigin(controlsFrame.origin)
        }
        let ignoresMouse = width == 0
        if controlsPanel.ignoresMouseEvents != ignoresMouse { controlsPanel.ignoresMouseEvents = ignoresMouse }
        var directions: NSCursor.FrameResizeDirection.Set = []
        if width > limits.lowerBound { directions.insert(.inward) }
        if width < limits.upperBound { directions.insert(.outward) }
        mat.resizeDirections = directions
        if panel.alphaValue != opacity { panel.alphaValue = opacity }
        let controlsOpacity = width == 0 ? 0 : opacity
        if controlsPanel.alphaValue != controlsOpacity { controlsPanel.alphaValue = controlsOpacity }
        if finished { stopTransition() }
        let textVisibilityChanged = mat.hasRoomForText != hadRoomForText
        if textVisibilityChanged {
            invalidatePage()
        }
        if finished || textVisibilityChanged {
            refreshContent()
        }
    }

    private func invalidatePage() {
#if DEBUG
        if fixtureWindow != nil { return }
#endif
        pageContent = .loading
        nextPageRead = 0
    }

    private func stopTransition() {
        transition = nil
        animationTimer?.invalidate()
        animationTimer = nil
    }

    private func updatePage(processID: pid_t, candidates: [BooksWindowCandidate]) {
        let now = ProcessInfo.processInfo.systemUptime
        guard pageRead == nil, now >= nextPageRead else { return }
        nextPageRead = now + 0.35
        let currentWindow = readingWindow
        let includeText = placement != nil && mat.hasRoomForText
        pageRead = Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                BooksPageReader.read(
                    processID: processID, candidates: candidates, currentWindow: currentWindow,
                    includeText: includeText
                )
            }.value
            guard let self else { return }
            pageRead = nil
            guard !Task.isCancelled, booksProcessID == processID, trackingDisplayLink == nil else { return }
            switch result {
            case .readingWindow(let number, let page):
                if readingWindow != number {
                    readingWindow = number
                    isTwoColumn = false
                    twoColumnWidthOverride = nil
                    pageContent = .loading
                    refreshContent()
                }
                if placement?.windowNumber == number, mat.hasRoomForText, let page {
                    setReadingPage(page)
                }
            case .noReadingWindow:
                readingWindow = nil
                hidePanel()
            case .retry:
                break
            }
        }
    }

    private func setReadingPage(_ page: BooksReadingPage) {
        pageContent = page.content
        if let layout = page.isTwoColumn, layout != isTwoColumn {
            isTwoColumn = layout
            twoColumnWidthOverride = nil
            if let placement, resizeGesture == nil {
                applyRightWidth(preferredWidth(within: placement.widthLimits), animate: true)
            }
        }
        refreshContent()
    }

    private func refreshContent() {
        if transition == nil {
            translation.update(placement != nil && mat.hasRoomForText ? pageContent : nil)
        }
        showTranslation()
    }

    private func showTranslation() {
        mat.show(placement != nil && transition == nil && mat.hasRoomForText ? translation.output : nil)
    }

    private func hidePanel() {
        stopTrackingDrag()
        stopTransition()
        placement = nil
        translation.update(nil)
        mat.endInteraction()
        if controlsPanel.isVisible { controlsPanel.orderOut(nil) }
        if panel.isVisible { panel.orderOut(nil) }
    }

    private func intersectionArea(_ first: CGRect, _ second: CGRect) -> CGFloat {
        let intersection = first.intersection(second)
        return intersection.width * intersection.height
    }

}

private final class BooksCompanionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown {
            // Keep the mat below Books while handling mouse interactions.
            NSApp.preventWindowOrdering()
        }
        super.sendEvent(event)
    }

    override func beginSheet(
        _ sheetWindow: NSWindow, completionHandler handler: ((NSApplication.ModalResponse) -> Void)? = nil
    ) {
        // The translation sheet needs to appear above Books even though its parent stays below it.
        sheetWindow.level = .modalPanel
        super.beginSheet(sheetWindow, completionHandler: handler)
        if attachedSheet === sheetWindow {
            sheetWindow.level = .modalPanel
            sheetWindow.orderFrontRegardless()
        }
    }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        // The mat may reach past the usable screen while staying aligned with Books.
        frameRect
    }
}
