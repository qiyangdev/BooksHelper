//
//  BooksHelperApp.swift
//  BooksHelper
//
//

import AppKit
import ApplicationServices

@main
final class BooksHelperApp: NSObject, NSApplicationDelegate {
    private let companion = BooksCompanionWindow()
    private var statusItem: NSStatusItem?

    static func main() {
        let application = NSApplication.shared
        let delegate = BooksHelperApp()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)

        withExtendedLifetime(delegate) {
            application.run()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installStatusItem()
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-test-fixture") {
            companion.startForUITests()
            return
        }
#endif
        companion.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        companion.stop()
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
    }

    private func installStatusItem() {
        let menu = NSMenu()
        let translationMenu = companion.translationMenu
        let translationItem = NSMenuItem(title: translationMenu.title, action: nil, keyEquivalent: "")
        translationItem.submenu = translationMenu
        menu.addItem(translationItem)
        menu.addItem(.separator())
        let access = menu.addItem(
            withTitle: String(localized: "Enable Books Text Access…"),
            action: #selector(enableBooksTextAccess),
            keyEquivalent: ""
        )
        access.target = self
        let quit = menu.addItem(
            withTitle: String(localized: "Quit BooksHelper"),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: ""
        )
        quit.target = NSApp

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let configuration = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        let icon = NSImage(named: "MenuBarIcon")?.withSymbolConfiguration(configuration)
            ?? NSImage(systemSymbolName: "translate", accessibilityDescription: "BooksHelper")
        icon?.isTemplate = true
        item.button?.image = icon
        if icon == nil { item.button?.title = "文" }
        item.button?.setAccessibilityLabel("BooksHelper")
        item.button?.toolTip = "BooksHelper"
        item.menu = menu
        statusItem = item
    }

    @objc private func enableBooksTextAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        AXIsProcessTrustedWithOptions(options as CFDictionary)
    }
}
