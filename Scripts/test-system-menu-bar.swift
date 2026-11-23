// Quit BooksHelper, then run from an Accessibility-authorized terminal:
// swift Scripts/test-system-menu-bar.swift /path/to/Debug/BooksHelper.app
import AppKit
import ApplicationServices
import CoreGraphics

struct TestFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@discardableResult
func waitFor<T>(_ message: String, _ read: () -> T?) throws -> T {
    let deadline = ProcessInfo.processInfo.systemUptime + 5
    repeat {
        if let result = read() { return result }
        Thread.sleep(forTimeInterval: 0.05)
    } while ProcessInfo.processInfo.systemUptime < deadline
    throw TestFailure(message: message)
}

func attribute(_ name: String, on item: AXUIElement) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(item, name as CFString, &value) == .success else { return nil }
    return value
}

func children(of item: AXUIElement) -> [AXUIElement] {
    attribute(kAXChildrenAttribute, on: item) as? [AXUIElement] ?? []
}

func center(of item: AXUIElement) -> CGPoint? {
    guard let position = attribute(kAXPositionAttribute, on: item),
          CFGetTypeID(position) == AXValueGetTypeID(),
          let dimensions = attribute(kAXSizeAttribute, on: item),
          CFGetTypeID(dimensions) == AXValueGetTypeID() else { return nil }
    var origin = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
          AXValueGetValue(dimensions as! AXValue, .cgSize, &size),
          size.width > 0, size.height > 0 else { return nil }
    return CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
}

func findText(_ text: String, under item: AXUIElement) -> AXUIElement? {
    if attribute(kAXRoleAttribute, on: item) as? String == kAXTextAreaRole,
       attribute(kAXValueAttribute, on: item) as? String == text { return item }
    for child in children(of: item) {
        if let found = findText(text, under: child) { return found }
    }
    return nil
}

func openLanguageMenu(from statusItem: AXUIElement) throws -> [AXUIElement] {
    let result = AXUIElementPerformAction(statusItem, kAXPressAction as CFString)
    // Native menu tracking can outlast the AX call. Poll for the visible menu.
    guard result == .success || result == .cannotComplete else {
        throw TestFailure(message: "Could not press the system menu bar icon (AX error \(result.rawValue)).")
    }
    let translation = try waitFor("The system status menu did not show Translation.") {
        children(of: statusItem).first.flatMap { menu in
            children(of: menu).first { attribute(kAXTitleAttribute, on: $0) as? String == "Translation" }
        }
    }
    let submenuLocation = try waitFor("The Translation submenu has no visible position.") { center(of: translation) }
    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: submenuLocation, mouseButton: .left)?
        .post(tap: .cghidEventTap)
    return try waitFor("No languages appeared in the Translation submenu.") {
        guard let submenu = children(of: translation).first else { return nil }
        let choices = children(of: submenu)
        guard choices.contains(where: { center(of: $0) != nil }) else { return nil }
        return choices
    }
}

func checkedTitles(in items: [AXUIElement]) -> [String] {
    items.filter { attribute("AXMenuItemMarkChar", on: $0) as? String == "✓" }
        .compactMap { attribute(kAXTitleAttribute, on: $0) as? String }
}

func run() throws {
    guard CommandLine.arguments.count == 2 else {
        throw TestFailure(message: "Usage: swift Scripts/test-system-menu-bar.swift /path/to/Debug/BooksHelper.app")
    }
    guard AXIsProcessTrusted(), CGPreflightPostEventAccess() else {
        throw TestFailure(message: "The terminal running this test needs macOS Accessibility access.")
    }

    let appURL = URL(fileURLWithPath: CommandLine.arguments[1])
    guard let app = Bundle(url: appURL),
          let executable = app.executableURL,
          let bundleID = app.bundleIdentifier else {
        throw TestFailure(message: "The BooksHelper app bundle is invalid.")
    }
    guard NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty else {
        throw TestFailure(message: "Quit the running BooksHelper before testing its system menu bar item.")
    }

    let fixture = Process()
    fixture.executableURL = executable
    fixture.arguments = ["--ui-test-fixture"]
    fixture.currentDirectoryURL = FileManager.default.temporaryDirectory
    fixture.environment = ProcessInfo.processInfo.environment.merging([
        "LLVM_PROFILE_FILE": FileManager.default.temporaryDirectory.appendingPathComponent("BooksHelper-menu-%p.profraw").path
    ]) { _, fixtureValue in fixtureValue }
    try fixture.run()
    let pointer = CGEvent(source: nil)?.location
    defer {
        if fixture.isRunning {
            fixture.terminate()
            fixture.waitUntilExit()
        }
        if let pointer { CGWarpMouseCursorPosition(pointer) }
    }

    let root = AXUIElementCreateApplication(fixture.processIdentifier)
    try waitFor("The Debug fixture did not show its initial Chinese translation.") {
        findText("Chinese fixture translation", under: root)
    }
    let statusItem = try waitFor("BooksHelper did not register a system menu bar item.") {
        guard let extras = attribute("AXExtrasMenuBar", on: root),
              CFGetTypeID(extras) == AXUIElementGetTypeID() else { return nil as AXUIElement? }
        return children(of: extras as! AXUIElement)
            .first { attribute(kAXDescriptionAttribute, on: $0) as? String == "BooksHelper" }
    }

    let chinese = Locale.current.localizedString(forIdentifier: "zh-Hans") ?? "zh-Hans"
    let japanese = Locale.current.localizedString(forIdentifier: "ja") ?? "ja"
    let initialChoices = try openLanguageMenu(from: statusItem)
    guard checkedTitles(in: initialChoices) == [chinese] else {
        throw TestFailure(message: "Simplified Chinese was not the only checked item.")
    }
    guard let japaneseItem = initialChoices.first(where: { attribute(kAXTitleAttribute, on: $0) as? String == japanese }),
          AXUIElementPerformAction(japaneseItem, kAXPressAction as CFString) == .success else {
        throw TestFailure(message: "Could not choose Japanese in the system menu.")
    }
    try waitFor("The sidebar did not update to the Japanese translation.") {
        findText("Japanese fixture translation", under: root)
    }
    guard findText("Chinese fixture translation", under: root) == nil else {
        throw TestFailure(message: "The previous Chinese translation was still visible.")
    }

    let updatedChoices = try openLanguageMenu(from: statusItem)
    guard checkedTitles(in: updatedChoices) == [japanese] else {
        throw TestFailure(message: "Japanese was not the only checked item after the switch.")
    }
    print("System menu bar: Simplified Chinese → Japanese, checkmark and sidebar both updated.")
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
    exit(1)
}
