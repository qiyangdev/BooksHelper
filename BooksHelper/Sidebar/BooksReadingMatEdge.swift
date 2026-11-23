import AppKit
import Darwin

final class BooksReadingMatEdge: NSView {
    private static let resizeBothWays = NSCursor.frameResize(position: .right, directions: .all)
    private static let resizeInwardOnly = NSCursor.frameResize(position: .right, directions: .inward)
    private static let resizeOutwardOnly = NSCursor.frameResize(position: .right, directions: .outward)
    var onResize: ((CGFloat) -> Void)?
    var onResizeEnded: (() -> Void)?
    var resizeDirections: NSCursor.FrameResizeDirection.Set = .outward {
        didSet {
            if oldValue != resizeDirections { refreshCursor() }
        }
    }
    private var pressPoint: CGPoint?
    private var lastDragX: CGFloat?
    private var ownsCursor = false
    private lazy var hoverArea = NSTrackingArea(
        rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
        owner: self, userInfo: nil
    )

    private var resizeCursor: NSCursor {
        switch resizeDirections {
        case .all: Self.resizeBothWays
        case .inward: Self.resizeInwardOnly
        case .outward: Self.resizeOutwardOnly
        default: .arrow
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func shouldDelayWindowOrdering(for event: NSEvent) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: resizeCursor)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if !trackingAreas.contains(hoverArea) { addTrackingArea(hoverArea) }
    }

    override func mouseEntered(with event: NSEvent) { updateHoverCursor() }
    override func mouseMoved(with event: NSEvent) { updateHoverCursor() }
    override func mouseExited(with event: NSEvent) { updateHoverCursor() }

    private func refreshCursor() {
        window?.invalidateCursorRects(for: self)
        updateHoverCursor()
    }

    func updateHoverCursor() {
        guard let window, window.isVisible else { return }
        let screenPoint = NSEvent.mouseLocation
        let location = window.convertPoint(fromScreen: screenPoint)
        if bounds.contains(convert(location, from: nil)),
           NSWindow.windowNumber(at: screenPoint, belowWindowWithWindowNumber: 0) == window.windowNumber {
            setResizeCursor()
        } else if pressPoint == nil {
            resetHoverCursor()
        }
    }

    private func setResizeCursor() {
        if !ownsCursor {
            Self.setsCursorInBackground?(true)
            ownsCursor = true
        }
        resizeCursor.set()
    }

    private func resetHoverCursor() {
        guard ownsCursor else { return }
        NSCursor.arrow.set()
        Self.setsCursorInBackground?(false)
        ownsCursor = false
    }

    override func mouseDown(with event: NSEvent) {
        finishDrag()
        pressPoint = window?.convertPoint(toScreen: event.locationInWindow)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pressPoint, let point = window?.convertPoint(toScreen: event.locationInWindow) else { return }

        let delta = point.x - (lastDragX ?? pressPoint.x)
        guard delta != 0 else { return }
        lastDragX = point.x
        onResize?(delta)
        setResizeCursor()
    }

    override func mouseUp(with event: NSEvent) {
        finishDrag()
        updateHoverCursor()
    }

    func endInteraction() {
        finishDrag()
        resetHoverCursor()
    }

    private func finishDrag() {
        let wasDragging = lastDragX != nil
        pressPoint = nil
        lastDragX = nil
        if wasDragging { onResizeEnded?() }
    }

    // AppKit doesn't publish cursor changes from this non-key panel while
    // Books is active. Resolve the WindowServer option at runtime so mouse
    // interaction still works on systems where it is unavailable.
    private static let setsCursorInBackground: ((Bool) -> Void)? = {
        typealias Connection = @convention(c) () -> Int32
        typealias SetProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
        guard let scope = dlopen(nil, RTLD_LAZY),
              let connectionSymbol = dlsym(scope, "CGSMainConnectionID"),
              let propertySymbol = dlsym(scope, "CGSSetConnectionProperty") else { return nil }
        let connection = unsafeBitCast(connectionSymbol, to: Connection.self)()
        let setProperty = unsafeBitCast(propertySymbol, to: SetProperty.self)
        return { enabled in
            _ = setProperty(
                connection, connection, "SetsCursorInBackground" as CFString,
                enabled ? kCFBooleanTrue : kCFBooleanFalse
            )
        }
    }()
}
