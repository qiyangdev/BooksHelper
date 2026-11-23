import AppKit
import CoreGraphics
import QuartzCore
import Testing
@testable import BooksHelper

@MainActor
struct BooksSidebarGeometryTests {
    private let visibleFrame = CGRect(x: 0, y: 40, width: 1200, height: 800)
    private let books = CGRect(x: 60, y: 100, width: 600, height: 500)

    @Test func collapsedMatExtendsEquallyOnEverySide() {
        let frame = BooksSidebarGeometry.attachedFrame(to: books, within: visibleFrame)
        #expect(frame == books.insetBy(dx: -8, dy: -8))
    }

    @Test func expandedMatGrowsOnlyToTheRight() {
        let frame = BooksSidebarGeometry.attachedFrame(to: books, within: visibleFrame, rightWidth: 360)
        #expect(frame == CGRect(x: 52, y: 92, width: 968, height: 516))
    }

    @Test func matCornersAddTheMarginToTheBooksRadius() {
        for width: CGFloat in [616, 916] {
            let bounds = CGRect(x: 0, y: 0, width: width, height: 516)
            let mat = BooksReadingMatBackground(frame: bounds)
            mat.layout()
            #expect(BooksReadingMatBackground.cornerRadius(in: bounds, margin: 8) - BooksSidebarGeometry.margin == 16)
            #expect(mat.layer?.cornerRadius == 24)
            #expect(mat.layer?.cornerCurve == .continuous)
        }
    }

    @Test func expansionFitsAvailableSpaceAndRetainsTheMargin() {
        let nearEdge = CGRect(x: 260, y: 140, width: 600, height: 450)
        let frame = BooksSidebarGeometry.attachedFrame(to: nearEdge, within: visibleFrame, rightWidth: 420)
        #expect(frame == CGRect(x: 252, y: 132, width: 948, height: 466))

        let atEdge = CGRect(x: 600, y: 140, width: 600, height: 450)
        let edgeFrame = BooksSidebarGeometry.attachedFrame(to: atEdge, within: visibleFrame, rightWidth: 308)
        #expect(edgeFrame == atEdge.insetBy(dx: -8, dy: -8))
    }

    @Test func rightWidthIsCappedByTheBooksWindowAndScreenSpace() {
        #expect(BooksSidebarGeometry.rightWidthRange(booksWidth: 600, availableWidth: 700) == 8...600)
        #expect(BooksSidebarGeometry.rightWidthRange(booksWidth: 600, availableWidth: 400) == 8...400)
        #expect(BooksSidebarGeometry.rightWidthRange(booksWidth: 600, availableWidth: 0) == 8...8)
        #expect(BooksSidebarGeometry.rightWidthRange(booksWidth: 600, availableWidth: 319) == 8...8)
        #expect(BooksSidebarGeometry.rightWidthRange(booksWidth: 319, availableWidth: 700) == 8...8)

        let roomyScreen = CGRect(x: 0, y: 0, width: 1600, height: 800)
        let expanded = BooksSidebarGeometry.attachedFrame(to: books, within: roomyScreen, rightWidth: 900)
        #expect(expanded.maxX - books.maxX == books.width)
        let collapsed = BooksSidebarGeometry.attachedFrame(to: books, within: visibleFrame, rightWidth: -10)
        #expect(collapsed == books.insetBy(dx: -8, dy: -8))
    }

    @Test func releasedWidthSnapsToACollapsedOrReadableSize() {
        #expect(BooksSidebarGeometry.settledRightWidth(8, from: 8, limits: 8...600) == 8)
        #expect(BooksSidebarGeometry.settledRightWidth(9, from: 8, limits: 8...320) == 320)
        #expect(BooksSidebarGeometry.settledRightWidth(93, from: 8, limits: 8...600) == 320)
        #expect(BooksSidebarGeometry.settledRightWidth(319, from: 320, limits: 8...600) == 8)
        #expect(BooksSidebarGeometry.settledRightWidth(320, from: 408, limits: 8...600) == 320)
        #expect(BooksSidebarGeometry.settledRightWidth(319, from: 8, limits: 8...600) == 320)
        #expect(BooksSidebarGeometry.settledRightWidth(360, from: 320, limits: 8...600) == 360)
        #expect(BooksSidebarGeometry.settledRightWidth(360, from: 320, limits: 8...340) == 340)
        #expect(BooksSidebarGeometry.settledRightWidth(150, from: 320, limits: 8...320) == 8)
        #expect(BooksSidebarGeometry.settledRightWidth(150, from: 320, limits: 8...8) == 8)
        #expect(BooksSidebarGeometry.settledRightWidth(101, from: 100, limits: 8...600) == 320)
        #expect(BooksSidebarGeometry.settledRightWidth(99, from: 100, limits: 8...600) == 8)
    }

    @Test func userResizedWidthIsAppliedOnlyOnTheRight() {
        let frame = BooksSidebarGeometry.attachedFrame(
            to: books, within: visibleFrame, rightWidth: 420
        )
        #expect(frame == CGRect(x: 52, y: 92, width: 1028, height: 516))
    }

    @Test func matTransitionCanReverseFromItsCurrentWidth() {
        let expand = BooksSidebarGeometry.Transition(
            startedAt: 4, duration: 0.5, initialWidth: 8, initialMargin: 8, initialOpacity: 0
        )
        let middle = expand.sample(at: 4.25, targetWidth: 308)
        let end = expand.sample(at: 4.5, targetWidth: 308)
        #expect(middle.width == 158 && middle.opacity == 0.5 && !middle.finished)
        #expect(end.width == 308 && end.opacity == 1 && end.finished)

        let collapse = BooksSidebarGeometry.Transition(
            startedAt: 4.25, duration: 0.5, initialWidth: middle.width, initialMargin: 8, initialOpacity: middle.opacity
        )
        #expect(collapse.sample(at: 4.25, targetWidth: 8).width == middle.width)
        #expect(collapse.sample(at: 4.75, targetWidth: 8).width == 8)
    }

    @Test func attachmentExpandsFromTheBooksFrameWithMatchingCorners() {
        let target = BooksSidebarGeometry.attachedFrame(to: books, within: visibleFrame)
        let transition = BooksSidebarGeometry.Transition(
            startedAt: 2, duration: 1, initialWidth: 0, initialMargin: 0, initialOpacity: 0
        )
        let backdrop = BooksReadingMatBackground()
        let samples: [(TimeInterval, CGFloat)] = [(2, 0), (2.5, 4), (3, 8)]
        for (time, margin) in samples {
            let sample = transition.sample(at: time, targetWidth: 8)
            let frame = BooksSidebarGeometry.attachmentFrame(
                fitting: target, seam: books.maxX, margin: sample.margin, rightWidth: sample.width
            )
            #expect(sample.margin == margin)
            #expect(frame == books.insetBy(dx: -margin, dy: -margin))
            backdrop.setFrameSize(frame.size)
            backdrop.outerMargin = sample.margin
            backdrop.layout()
            #expect(backdrop.layer?.cornerRadius == 16 + margin)
        }
    }
}
