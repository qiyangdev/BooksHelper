import CoreGraphics
import Testing
@testable import BooksHelper

struct BooksPageLayoutTests {
    @Test func findsTwoColumnsEvenWhenAXReportsACombinedParagraphAndAnOffsetPage() {
        let left = CGRect(x: -320, y: 60, width: 375, height: 110)
        let right = CGRect(x: 116, y: 65, width: 375, height: 175)
        let spanning = CGRect(x: -320, y: 60, width: 811, height: 536)
        #expect(BooksPageLayout.columnDivider(textFrames: [left, spanning, right], windowWidth: 924) == 85.5)
        #expect(BooksPageLayout.columnDivider(textFrames: [left, spanning], windowWidth: 924) == nil)
    }

    @Test func doesNotTreatAlignedParagraphsOrShortIndentedTextAsTwoColumns() {
        let paragraph = CGRect(x: 75, y: 60, width: 650, height: 110)
        let nextParagraph = CGRect(x: 75, y: 200, width: 650, height: 110)
        let indent = CGRect(x: 720, y: 70, width: 110, height: 30)
        #expect(BooksPageLayout.columnDivider(
            textFrames: [paragraph, nextParagraph, indent], windowWidth: 924
        ) == nil)
    }

    @Test func crossPageParagraphUsesTheBottomOfOnePageAndTheTopOfTheOther() {
        let viewport = CGRect(x: 0, y: 0, width: 924, height: 698)
        let blocks = [
            ("Left opening", CGRect(x: 57, y: 60, width: 370, height: 100)),
            ("Left following", CGRect(x: 57, y: 180, width: 370, height: 280)),
            ("Cross-page paragraph", CGRect(x: 57, y: 60, width: 810, height: 550)),
            ("Right following", CGRect(x: 493, y: 180, width: 374, height: 150)),
        ]
        let divider = BooksPageLayout.columnDivider(textFrames: blocks.map { $0.1 }, windowWidth: viewport.width)
        let paragraphs = BooksPageLayout.makeParagraphs(from: blocks, in: viewport, divider: divider)
        let crossPage = paragraphs[2]
        #expect(crossPage.text == "Cross-page paragraph")
        #expect(crossPage.position == BooksParagraph.Position(column: .left, top: 480, height: 130))
        #expect(crossPage.continuation == BooksParagraph.Position(column: .right, top: 60, height: 100))
        #expect(paragraphs[3].position == BooksParagraph.Position(column: .right, top: 180, height: 150))
    }
}
