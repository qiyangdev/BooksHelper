import CoreGraphics

nonisolated enum BooksPageLayout {
    static func columnDivider(textFrames: [CGRect], windowWidth: CGFloat) -> CGFloat? {
        let blocks = textFrames.filter { $0.width >= windowWidth * 0.2 }
        for left in blocks {
            if let right = blocks.first(where: { right in
                // Use the original horizontal positions when part of a column is offscreen.
                right.minX - left.minX >= windowWidth * 0.3
                    && right.minX >= left.maxX
                    && right.minY < left.maxY && left.minY < right.maxY
            }) {
                return (left.maxX + right.minX) / 2
            }
        }
        return nil
    }

    static func makeParagraphs(
        from blocks: [(text: String, frame: CGRect)], in viewport: CGRect, divider: CGFloat?
    ) -> [BooksParagraph] {
        let visible = blocks.map { block in
            let bounds = block.frame.intersection(viewport)
            return bounds.offsetBy(dx: -viewport.minX, dy: -viewport.minY)
        }
        let columns: [BooksParagraph.Column?] = blocks.map { block in
            guard let divider else { return .left }
            let minimumSpan = viewport.width * 0.15
            if block.frame.minX < divider - minimumSpan, block.frame.maxX > divider + minimumSpan { return nil }
            return block.frame.midX < divider ? .left : .right
        }
        let gaps = zip(visible.indices, visible.indices.dropFirst()).compactMap { first, second -> CGFloat? in
            guard let column = columns[first], columns[second] == column else { return nil }
            let gap = visible[second].minY - visible[first].maxY
            return gap > 0 ? gap : nil
        }
        let paragraphGap = min(gaps.min() ?? 0, 32)

        return blocks.indices.map { index in
            let rect = visible[index]
            let text = blocks[index].text
            if let column = columns[index] {
                return BooksParagraph(text: text, top: rect.minY.rounded(), height: ceil(rect.height), column: column)
            }

            // Books supplies one union rectangle for a paragraph that continues onto the other page.
            // Use the neighboring paragraphs to reserve the source paragraph's space on each page.
            let previous = columns[..<index].lastIndex { $0 != nil }
            let next = columns[(index + 1)...].firstIndex { $0 != nil }
            let startColumn = previous.flatMap { columns[$0] } ?? next.flatMap { columns[$0]?.opposite } ?? .left
            let start = previous.map { max(rect.minY, visible[$0].maxY + paragraphGap) } ?? rect.minY
            let end = next.map { min(rect.maxY, visible[$0].minY - paragraphGap) } ?? rect.maxY
            let continuation = BooksParagraph.Position(
                column: startColumn.opposite, top: rect.minY.rounded(), height: max(0, floor(end - rect.minY))
            )
            return BooksParagraph(
                text: text, top: start.rounded(), height: max(0, floor(rect.maxY - start)),
                column: startColumn, continuation: continuation
            )
        }
    }
}
