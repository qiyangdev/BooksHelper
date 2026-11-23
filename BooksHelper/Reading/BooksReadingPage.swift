import CoreGraphics

nonisolated struct BooksParagraph: Equatable, Sendable {
    enum Column: Equatable, Sendable {
        case left, right

        var opposite: Self { self == .left ? .right : .left }
    }

    struct Position: Equatable, Sendable {
        let column: Column
        let top: CGFloat
        let height: CGFloat
    }

    var text: String
    let position: Position
    let continuation: Position?

    init(text: String, top: CGFloat, height: CGFloat, column: Column = .left, continuation: Position? = nil) {
        self.text = text
        position = Position(column: column, top: top, height: height)
        self.continuation = continuation
    }
}

nonisolated enum BooksPageContent: Equatable, Sendable {
    case loading
    case noText
    case paragraphs([BooksParagraph])
    case translating
    case translationUnavailable(String)
}

nonisolated struct BooksReadingPage: Sendable {
    let content: BooksPageContent
    let isTwoColumn: Bool?
}
