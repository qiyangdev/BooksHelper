import AppKit
import Testing
@testable import BooksHelper

#if DEBUG
@MainActor
struct BooksTranslationTests {
    @Test func nativeSidebarPickerSwitchesBetweenTranslationAndSummary() throws {
        let translation = BooksTranslation()
        translation.startForUITests()
        let view = BooksReadingMat(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        view.rightWidth = 320
        view.onSelectMode = { translation.selectMode($0) }
        translation.onOutputChange = { [weak view] in view?.show($0) }
        translation.update(.paragraphs([BooksParagraph(text: "Source", top: 72, height: 80)]))
        view.layout()

        let picker = try #require(view.subviews.compactMap { $0 as? NSSegmentedControl }.first)
        #expect(picker.trackingMode == .selectOne)
        #expect(picker.label(forSegment: 0) == "Translate")
        #expect(picker.label(forSegment: 1) == "Summary")
        #expect(!picker.isHidden && !picker.frame.isEmpty)
        let action = try #require(picker.action)
        picker.selectedSegment = BooksSidebarMode.summary.rawValue
        #expect(NSApp.sendAction(action, to: picker.target, from: picker))
        #expect(translation.output == .summary("Summary fixture"))
        view.layout()
        let summary = try #require(view.subviews.compactMap { $0 as? NSScrollView }.first { !$0.isHidden })
        #expect(picker.frame.minY - summary.frame.maxY == 16)
        let text = try #require(summary.documentView as? NSTextView)
        #expect(text.string == "Summary fixture")
        view.show(.summarizing)
        view.layout()
        let placeholder = try #require(summary.documentView?.subviews.compactMap { $0 as? NSTextView }.first)
        #expect(placeholder.string == "Summarizing…")
        #expect(placeholder.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == .secondaryLabelColor)
        #expect(picker.frame.minY - summary.frame.maxY == 16)
        view.show(.summary("First"))
        view.layout()
        #expect(summary.documentView === text)
        #expect(text.string == "First")
        #expect(text.textColor == .labelColor)
        view.show(.summary("First sentence."))
        view.layout()
        #expect(text.string == "First sentence.")
        let storage = try #require(text.textStorage)
        for index in [0, storage.length - 1] {
            let paragraph = storage.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle
            #expect(paragraph?.lineHeightMultiple == 1.25)
        }
        picker.selectedSegment = BooksSidebarMode.translation.rawValue
        #expect(NSApp.sendAction(action, to: picker.target, from: picker))
        #expect(translation.output == .paragraphs([
            BooksParagraph(text: "Chinese fixture translation", top: 72, height: 80)
        ]))
    }

    @Test func refreshingTheReadingWindowKeepsItsTranslation() {
        let translation = BooksTranslation()
        translation.startForUITests()
        translation.update(.paragraphs([BooksParagraph(text: "Source", top: 72, height: 80)]))
        let beforeRefresh = translation.output

        translation.update(.loading)
        #expect(translation.output == beforeRefresh)
        translation.update(.paragraphs([BooksParagraph(text: "Source", top: 90, height: 80)]))
        #expect(translation.output == .paragraphs([
            BooksParagraph(text: "Chinese fixture translation", top: 90, height: 80)
        ]))

        translation.update(nil)
        #expect(translation.output == nil)
    }

    @Test func outOfOrderTranslationsUpdateTheirOwnParagraphs() {
        let originals = [
            BooksParagraph(text: "First paragraph", top: 10, height: 40),
            BooksParagraph(text: "—", top: 60, height: 20),
            BooksParagraph(text: "Second paragraph", top: 10, height: 40, column: .right),
            BooksParagraph(text: "Third paragraph", top: 60, height: 20, column: .right),
        ]
        var progress = BooksTranslation.PageProgress()
        #expect(progress.displayParagraphs(from: originals).map(\.isTranslationPlaceholder) == [true, false, true, true])
        #expect(progress.displayParagraphs(from: originals).map(\.showsTranslationShimmer) == [true, false, true, true])

        progress.prefixes[3] = "第三"
        let streaming = progress.displayParagraphs(from: originals)
        #expect(streaming[0].translationPrefix == nil)
        #expect(streaming[3].translationPrefix == "第三")
        #expect(streaming[3].isTranslationPlaceholder)
        #expect(streaming.map(\.showsTranslationShimmer) == [true, false, true, false])

        progress.completed[3] = "第三段"
        progress.completed[0] = "第一段"
        let partial = progress.displayParagraphs(from: originals)
        #expect(partial.map(\.text) == ["第一段", "—", "Second paragraph", "第三段"])
        #expect(partial.map(\.isTranslationPlaceholder) == [false, false, true, false])
        #expect(partial.map(\.showsTranslationShimmer) == [false, false, true, false])

        progress.completed[2] = "第二段"
        let completed = progress.displayParagraphs(from: originals)
        #expect(completed.map(\.text) == ["第一段", "—", "第二段", "第三段"])
        #expect(completed.map(\.isTranslationPlaceholder) == [false, false, false, false])
        #expect(completed.map(\.position) == originals.map(\.position))
    }

    @Test func selectingOllamaUpdatesTheEngineCheckmarkAndCurrentTranslation() throws {
        let translation = BooksTranslation()
        translation.startForUITests()
        translation.update(.paragraphs([BooksParagraph(text: "Source", top: 72, height: 80)]))

        func engineChoices() -> [NSMenuItem] {
            translation.menu.items.first { $0.submenu?.title == "Engine" }?.submenu?.items ?? []
        }

        #expect(engineChoices().first { $0.state == .on }?.representedObject as? String == "system")
        let ollama = try #require(engineChoices().first { $0.representedObject as? String == "ollama" })
        let action = try #require(ollama.action)
        #expect(NSApp.sendAction(action, to: ollama.target, from: ollama))
        #expect(engineChoices().first { $0.state == .on }?.representedObject as? String == "ollama")
        #expect(translation.output == .paragraphs([
            BooksParagraph(text: "Ollama fixture translation", top: 72, height: 80)
        ]))
        #expect(translation.menu.items.map(\.title) == ["Translate To", "Engine", "Model"])
        let models = try #require(translation.menu.item(withTitle: "Model")?.submenu?.items)
        #expect(models.first { $0.state == .on }?.title == "qwen3.5:4b")
        let second = try #require(models.first { $0.title == "second-fixture:4b" })
        let modelAction = try #require(second.action)
        #expect(NSApp.sendAction(modelAction, to: second.target, from: second))
        #expect(translation.menu.item(withTitle: "Model")?.submenu?.items.first { $0.state == .on }?.title
            == "second-fixture:4b")
        #expect(translation.output == .paragraphs([
            BooksParagraph(text: "second-fixture:4b translation", top: 72, height: 80)
        ]))
        let system = try #require(engineChoices().first { $0.representedObject as? String == "system" })
        #expect(NSApp.sendAction(action, to: system.target, from: system))
        #expect(translation.menu.item(withTitle: "Model") == nil)
    }

    @Test func selectingTranslationLanguageMovesTheMenuCheckmark() throws {
        let translation = BooksTranslation()
        translation.startForUITests()

        func languageChoices() -> [NSMenuItem] {
            translation.menu.item(withTitle: "Translate To")?.submenu?.items ?? []
        }

        func checkedLanguageIDs() -> [String] {
            languageChoices().filter { $0.state == .on }.compactMap { $0.representedObject as? String }
        }

        let chinese = Locale.Language(identifier: "zh-Hans").minimalIdentifier
        #expect(translation.menu.items.map(\.title) == ["Translate To", "Engine"])
        let japaneseItem = try #require(languageChoices().first { $0.representedObject as? String == "ja" })
        let action = try #require(japaneseItem.action)
        #expect(checkedLanguageIDs() == [chinese])

        #expect(NSApp.sendAction(action, to: japaneseItem.target, from: japaneseItem))
        #expect(checkedLanguageIDs() == ["ja"])
    }
}
#endif
