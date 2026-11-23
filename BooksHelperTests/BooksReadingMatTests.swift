import AppKit
import CoreGraphics
import QuartzCore
import Testing
@testable import BooksHelper

@MainActor
struct BooksReadingMatTests {
    @Test func rightEdgeIsAResizeHandleAndTextStaysInTheExposedArea() throws {
        let view = BooksReadingMat(frame: CGRect(x: 0, y: 0, width: 8, height: 516))
        let reader = try #require(view.subviews.compactMap { $0 as? NSScrollView }.first)
        view.layout()
        let collapsedEdge = try #require(view.hitTest(CGPoint(x: 4, y: 258)))
        collapsedEdge.updateTrackingAreas()
        #expect(collapsedEdge.trackingAreas.contains {
            $0.options.contains([.activeAlways, .mouseEnteredAndExited, .mouseMoved])
        })
        #expect(collapsedEdge.acceptsFirstMouse(for: nil))
        #expect(!collapsedEdge.needsPanelToBecomeKey)
        #expect(collapsedEdge.accessibilityRole() == .splitter)
        #expect(!collapsedEdge.accessibilityPerformPress())
        #expect(!view.hasRoomForText)
        #expect(reader.isHidden)

        view.rightWidth = 320
        view.setFrameSize(CGSize(width: 320, height: 516))
        view.show(.paragraphs([BooksParagraph(text: "Current Books page", top: 0, height: 50)]))
        view.layout()
        let expandedEdge = try #require(view.hitTest(CGPoint(x: 316, y: 258)))
        #expect(expandedEdge === collapsedEdge)
        #expect(view.hasRoomForText)
        #expect(!reader.isHidden)
        #expect(reader.frame == view.bounds.insetBy(dx: 16, dy: 16))
        #expect(reader.frame.maxX < expandedEdge.frame.minX)
        #expect((reader.documentView?.subviews.first as? NSTextView)?.string == "Current Books page")

        let originalReaderFrame = reader.frame
        view.rightWidth = 319
        view.setFrameSize(CGSize(width: 319, height: 516))
        view.show(.paragraphs([BooksParagraph(text: "Next Books page", top: 0, height: 50)]))
        view.layout()
        #expect(reader.isHidden)
        #expect(reader.frame == originalReaderFrame)
        #expect((reader.documentView?.subviews.first as? NSTextView)?.string == "Current Books page")

        view.rightWidth = 420
        view.setFrameSize(CGSize(width: 420, height: 516))
        view.layout()
        #expect(!reader.isHidden)
        #expect(reader.frame.width == originalReaderFrame.width + 100)
        #expect((reader.documentView?.subviews.first as? NSTextView)?.string == "Next Books page")

        view.rightWidth = 360
        view.setFrameSize(CGSize(width: 360, height: 516))
        view.layout()
        #expect(!reader.isHidden)
        #expect(reader.frame.width == originalReaderFrame.width + 40)

        view.show(nil)
        view.layout()
        #expect(reader.isHidden)
    }

    @Test func translationStatusIsCenteredInPlaceOfParagraphs() throws {
        let view = BooksReadingMat(frame: CGRect(x: 0, y: 0, width: 320, height: 516))
        view.rightWidth = 320
        let reader = try #require(view.subviews.compactMap { $0 as? NSScrollView }.first)
        let document = try #require(reader.documentView)
        let status = try #require(view.subviews.compactMap { $0 as? NSTextField }.first)
        let indicator = try #require(view.subviews.compactMap { $0 as? NSProgressIndicator }.first)

        view.show(.paragraphs([BooksParagraph(text: "Previous translation", top: 0, height: 50)]))
        view.layout()
        view.show(.translating)
        view.layout()
        #expect(reader.isHidden)
        #expect(!status.isHidden)
        #expect(status.stringValue == String(localized: "Translating…"))
        #expect(status.alignment == .center)
        #expect(status.frame.midX == view.bounds.midX)
        #expect(!indicator.isHidden)
        #expect(indicator.style == .spinning && indicator.isIndeterminate)
        #expect(indicator.frame.midX == view.bounds.midX)
        #expect(status.frame.union(indicator.frame).midY == view.bounds.midY)
        let loadingHeight = status.frame.height

        let message = "The required language packs aren’t ready. Try again after downloading them."
        view.show(.translationUnavailable(message))
        view.layout()
        #expect(reader.isHidden)
        #expect(!status.isHidden)
        #expect(indicator.isHidden)
        #expect(status.stringValue == message)
        #expect(status.frame.height > loadingHeight)
        #expect(status.frame.midX == view.bounds.midX)
        #expect(status.frame.midY == view.bounds.midY)

        view.show(.paragraphs([BooksParagraph(text: "Current translation", top: 0, height: 50)]))
        view.layout()
        #expect(status.isHidden)
        #expect(indicator.isHidden)
        #expect(!reader.isHidden)
        #expect((document.subviews.first as? NSTextView)?.string == "Current translation")
    }

    @Test func translatedParagraphsFollowSourcePositionsAndAvoidOverlap() throws {
        let view = BooksReadingMat(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        view.rightWidth = 320
        let reader = try #require(view.subviews.compactMap { $0 as? NSScrollView }.first)
        let document = try #require(reader.documentView)
        let longText = String(repeating: "This paragraph is long enough to wrap. ", count: 20)
        view.show(.paragraphs([
            BooksParagraph(text: "Short translation", top: 48, height: 35),
            BooksParagraph(text: longText, top: 96, height: 24),
            BooksParagraph(text: "Following translation", top: 124, height: 35),
        ]))
        view.layout()

        let blocks = document.subviews.compactMap { $0 as? NSTextView }
        try #require(blocks.count == 3)
        #expect(blocks[0].frame.minY == 40)
        #expect(blocks[0].frame.height == 35)
        #expect(blocks[1].frame.minY == 88)
        #expect(blocks[1].frame.height == 24)
        #expect(blocks[2].frame.minY == 116)
        #expect(blocks[2].frame.minY >= blocks[1].frame.maxY)
        #expect(document.frame.height >= blocks[2].frame.maxY)
        #expect(document.frame.height == reader.contentSize.height)
    }

    @Test func wideningSidebarRemovesTruncationWithoutMovingSourceAnchor() throws {
        let view = BooksReadingMat(frame: CGRect(x: 0, y: 0, width: 320, height: 516))
        view.rightWidth = 320
        let reader = try #require(view.subviews.compactMap { $0 as? NSScrollView }.first)
        let document = try #require(reader.documentView)
        view.show(.paragraphs([
            BooksParagraph(
                text: "A readable translation should remain on its original lines\nwhen the sidebar grows a little wider.",
                top: 48,
                height: 45
            ),
        ]))
        view.layout()

        let block = try #require(document.subviews.first as? NSTextView)
        let layout = try #require(block.layoutManager)
        let container = try #require(block.textContainer)
        func truncated() -> Bool {
            layout.ensureLayout(for: container)
            var hasEllipsis = false
            layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(for: container)) { _, _, _, glyphs, _ in
                hasEllipsis = hasEllipsis || layout.truncatedGlyphRange(inLineFragmentForGlyphAt: glyphs.location).length > 0
            }
            return hasEllipsis
        }

        #expect(truncated())
        let initialFrame = block.frame

        view.rightWidth = 520
        view.setFrameSize(CGSize(width: 520, height: 516))
        view.layout()

        #expect(!truncated())
        #expect(block.frame.minY == initialFrame.minY)
        #expect(block.frame.height == initialFrame.height)
        #expect(document.frame.height == reader.contentSize.height)
    }

    @Test func translationContinuesIntoTheRightColumnWithoutMovingItsNextParagraph() throws {
        let view = BooksReadingMat(frame: CGRect(x: 0, y: 0, width: 640, height: 200))
        view.rightWidth = 640
        let reader = try #require(view.subviews.compactMap { $0 as? NSScrollView }.first)
        let document = try #require(reader.documentView)
        view.show(.paragraphs([
            BooksParagraph(text: "Left opening", top: 20, height: 40),
            BooksParagraph(
                text: String(repeating: "The translation continues on the next page. ", count: 8),
                top: 100, height: 40, continuation: .init(column: .right, top: 20, height: 60)
            ),
            BooksParagraph(text: "Right following", top: 100, height: 40, column: .right),
        ]))
        view.layout()

        let blocks = document.subviews.compactMap { $0 as? NSTextView }
        try #require(blocks.count == 4)
        #expect(blocks[0].frame.minY == blocks[2].frame.minY)
        #expect(blocks[1].frame.minY == blocks[3].frame.minY)
        #expect(blocks[0].frame.maxX < blocks[2].frame.minX)
        let firstContainer = try #require(blocks[1].textContainer)
        let secondContainer = try #require(blocks[2].textContainer)
        let layout = try #require(blocks[1].layoutManager)
        #expect(blocks[2].layoutManager === layout)
        let firstRange = layout.glyphRange(for: firstContainer)
        let secondRange = layout.glyphRange(for: secondContainer)
        #expect(firstRange.length > 0)
        #expect(secondRange.length > 0)
        #expect(NSMaxRange(firstRange) == secondRange.location)
    }
}
