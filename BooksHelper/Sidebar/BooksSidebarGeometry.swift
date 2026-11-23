import CoreGraphics
import Foundation

enum BooksSidebarGeometry {
    static let margin: CGFloat = 8
    static let minimumExpandedRightWidth: CGFloat = 320
    // The system window corner radius measured on macOS 27.
    static let booksCornerRadius: CGFloat = 16

    struct Transition {
        let startedAt: TimeInterval
        let duration: TimeInterval
        let initialWidth: CGFloat
        let initialMargin: CGFloat
        let initialOpacity: CGFloat

        func sample(
            at time: TimeInterval, targetWidth: CGFloat
        ) -> (width: CGFloat, margin: CGFloat, opacity: CGFloat, finished: Bool) {
            let progress = CGFloat(min(1, max(0, (time - startedAt) / duration)))
            let eased = progress * progress * (3 - 2 * progress)
            return (
                initialWidth + (targetWidth - initialWidth) * eased,
                initialMargin + (margin - initialMargin) * eased,
                initialOpacity + (1 - initialOpacity) * eased,
                progress == 1
            )
        }
    }

    static func attachedFrame(
        to booksFrame: CGRect, within visibleFrame: CGRect,
        rightWidth: CGFloat = margin
    ) -> CGRect {
        let limits = rightWidthRange(booksWidth: booksFrame.width, availableWidth: visibleFrame.maxX - booksFrame.maxX)
        return attachedFrame(to: booksFrame, rightWidth: limits.clamp(rightWidth))
    }

    static func attachedFrame(to booksFrame: CGRect, rightWidth: CGFloat) -> CGRect {
        let margin = Self.margin
        return CGRect(
            x: booksFrame.minX - margin, y: booksFrame.minY - margin,
            width: booksFrame.width + margin + rightWidth, height: booksFrame.height + 2 * margin
        )
    }

    static func attachmentFrame(
        fitting targetFrame: CGRect, seam: CGFloat, margin: CGFloat, rightWidth: CGFloat
    ) -> CGRect {
        let inset = Self.margin - margin
        var frame = targetFrame.insetBy(dx: inset, dy: inset)
        frame.size.width = seam - frame.minX + rightWidth
        return frame
    }

    static func rightWidthRange(booksWidth: CGFloat, availableWidth: CGFloat) -> ClosedRange<CGFloat> {
        let margin = Self.margin
        let maximum = min(booksWidth, availableWidth)
        return margin...(maximum >= minimumExpandedRightWidth ? maximum : margin)
    }

    static func settledRightWidth(_ width: CGFloat, from initialWidth: CGFloat, limits: ClosedRange<CGFloat>) -> CGFloat {
        let draggedOutFromBelowMinimum = initialWidth < minimumExpandedRightWidth && width > initialWidth
        guard limits.upperBound >= minimumExpandedRightWidth,
              width >= minimumExpandedRightWidth || draggedOutFromBelowMinimum else { return limits.lowerBound }
        return limits.clamp(max(width, minimumExpandedRightWidth))
    }
}

extension ClosedRange where Bound == CGFloat {
    func clamp(_ value: CGFloat) -> CGFloat {
        Swift.min(Swift.max(value, lowerBound), upperBound)
    }
}
