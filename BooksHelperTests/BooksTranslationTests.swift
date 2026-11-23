import AppKit
import Testing
@testable import BooksHelper

#if DEBUG
@MainActor
struct BooksTranslationTests {
    @Test func selectingTranslationLanguageMovesTheMenuCheckmark() throws {
        let translation = BooksTranslation()
        translation.startForUITests()

        func checkedLanguageIDs() -> [String] {
            translation.menu.items.filter { $0.state == .on }.compactMap { $0.representedObject as? String }
        }

        let chinese = Locale.Language(identifier: "zh-Hans").minimalIdentifier
        let japaneseItem = try #require(translation.menu.items.first { $0.representedObject as? String == "ja" })
        let action = try #require(japaneseItem.action)
        #expect(checkedLanguageIDs() == [chinese])

        #expect(NSApp.sendAction(action, to: japaneseItem.target, from: japaneseItem))
        #expect(checkedLanguageIDs() == ["ja"])
    }
}
#endif
