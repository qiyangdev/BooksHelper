import XCTest

final class BooksHelperUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testChangingTargetLanguageUpdatesSidebar() {
        let app = launchFixture()
        let chinese = translation("Chinese fixture translation", in: app)
        let japanese = translation("Japanese fixture translation", in: app)
        XCTAssertTrue(chinese.waitForExistence(timeout: 5))

        app.buttons["Translation"].click()
        let targets = app.menuItems["Translate To"].firstMatch
        XCTAssertTrue(targets.waitForExistence(timeout: 5))
        targets.hover()
        let japaneseTitle = Locale.current.localizedString(forIdentifier: "ja") ?? "ja"
        let japaneseItem = app.menuItems[japaneseTitle].firstMatch
        XCTAssertTrue(japaneseItem.waitForExistence(timeout: 5))
        japaneseItem.click()

        XCTAssertTrue(japanese.waitForExistence(timeout: 5))
        XCTAssertFalse(chinese.exists)
    }

    @MainActor
    func testOllamaModelPickerUpdatesTheSidebar() {
        let app = launchFixture()
        let menu = app.buttons["Translation"]
        menu.click()
        XCTAssertFalse(app.menuItems["Model"].exists)
        let engine = app.menuItems["Engine"].firstMatch
        XCTAssertTrue(engine.waitForExistence(timeout: 5))
        engine.hover()
        let ollama = app.menuItems["Ollama"].firstMatch
        XCTAssertTrue(ollama.waitForExistence(timeout: 5))
        ollama.click()
        XCTAssertTrue(translation("Ollama fixture translation", in: app).waitForExistence(timeout: 5))

        menu.click()
        let models = app.menuItems["Model"].firstMatch
        XCTAssertTrue(models.waitForExistence(timeout: 5))
        models.hover()
        let second = app.menuItems["second-fixture:4b"].firstMatch
        XCTAssertTrue(second.waitForExistence(timeout: 5))
        second.click()
        XCTAssertTrue(translation("second-fixture:4b translation", in: app).waitForExistence(timeout: 5))
    }

    @MainActor
    func testDraggingRightEdgeExpandsCollapsesAndRespectsMaximumWidth() {
        let app = launchFixture()
        let readingWindow = app.windows["BooksHelper Reading Fixture"]
        XCTAssertTrue(readingWindow.waitForExistence(timeout: 5))
        let edge = app.splitters["Resize Reading Area"].firstMatch
        XCTAssertTrue(edge.waitForExistence(timeout: 5))
        let paragraph = translation("Chinese fixture translation", in: app)
        XCTAssertTrue(paragraph.waitForExistence(timeout: 5))

        let seam = readingWindow.frame.maxX
        assertRightEdge(edge, isAt: seam + 320)
        drag(edge, by: -60)
        assertRightEdge(edge, isAt: seam + 8)
        XCTAssertFalse(paragraph.exists)

        drag(edge, by: 40)
        assertRightEdge(edge, isAt: seam + 320)
        XCTAssertTrue(paragraph.waitForExistence(timeout: 5))

        let readingWidth = readingWindow.frame.width
        drag(edge, by: readingWidth - 320 + 12)
        assertRightEdge(edge, isAt: seam + readingWidth)
        XCTAssertTrue(paragraph.exists)
    }

    @MainActor
    func testTwoColumnsWidenSidebarAndReturningToSingleColumnRestoresWidth() {
        let app = launchFixture()
        let readingWindow = app.windows["BooksHelper Reading Fixture"]
        let edge = app.splitters["Resize Reading Area"].firstMatch
        XCTAssertTrue(edge.waitForExistence(timeout: 5))
        let seam = readingWindow.frame.maxX
        let readingWidth = readingWindow.frame.width
        let toggle = app.buttons["Toggle Reading Columns"]

        assertRightEdge(edge, isAt: seam + 320)
        toggle.click()
        assertRightEdge(edge, isAt: seam + readingWidth)
        let translations = app.textViews.matching(NSPredicate(format: "value == %@", "Chinese fixture translation"))
        XCTAssertTrue(translations.element(boundBy: 1).waitForExistence(timeout: 5))
        let columns = translations.allElementsBoundByIndex.map(\.frame).sorted { $0.minX < $1.minX }
        XCTAssertEqual(columns.count, 2)
        XCTAssertLessThan(columns[0].maxX, columns[1].minX)
        XCTAssertEqual(columns[0].minY, columns[1].minY, accuracy: 1)
        toggle.click()
        assertRightEdge(edge, isAt: seam + 320)

        drag(edge, by: -60)
        assertRightEdge(edge, isAt: seam + 8)
        toggle.click()
        assertRightEdge(edge, isAt: seam + 8)
    }

    @MainActor
    func testRetryingFromTheUnavailableViewRestoresTheTranslation() {
        let app = launchFixture(arguments: ["--ui-test-translation-failure"])
        let retry = app.buttons["Retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Fixture translation failed."].exists)

        retry.click()
        XCTAssertTrue(translation("Chinese fixture translation", in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(retry.exists)
    }

    @MainActor
    private func launchFixture(arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-fixture"] + arguments
        app.launch()
        return app
    }

    @MainActor
    private func translation(_ text: String, in app: XCUIApplication) -> XCUIElement {
        app.textViews.matching(NSPredicate(format: "value == %@", text)).firstMatch
    }

    @MainActor
    private func drag(_ edge: XCUIElement, by distance: CGFloat) {
        let start = edge.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = start.withOffset(CGVector(dx: distance, dy: 0))
        start.click(forDuration: 0.1, thenDragTo: end)
    }

    @MainActor
    private func assertRightEdge(
        _ edge: XCUIElement, isAt x: CGFloat, file: StaticString = #filePath, line: UInt = #line
    ) {
        let reachedPosition = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            MainActor.assumeIsolated { abs(edge.frame.maxX - x) <= 1 }
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [reachedPosition], timeout: 5), .completed, file: file, line: line)
    }
}
