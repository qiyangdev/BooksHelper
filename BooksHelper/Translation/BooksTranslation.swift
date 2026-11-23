import AppKit
import NaturalLanguage
import Observation
import SwiftUI
import Translation
import os

@Observable
final class BooksTranslation: NSObject, NSMenuItemValidation {
    struct Request: Equatable {
        let id = UUID()
        let paragraphs: [String]
        let source: Locale.Language?
        let target: Locale.Language

        var text: String { paragraphs.joined(separator: "\n\n") }
    }

    private static let targetKey = "BooksTranslationTargetLanguage"
    private static let log = Logger(subsystem: "org.bookshelper.BooksHelper", category: "Translation")

    private let defaults = UserDefaults.standard
    private let translatedPages: NSCache<NSString, NSArray> = {
        let cache = NSCache<NSString, NSArray>()
        cache.countLimit = 64
        cache.totalCostLimit = 4 * 1024 * 1024
        return cache
    }()
    private var target = Locale.Language(identifier: "zh-Hans")
    private var languages: [Locale.Language]?
    private var input: BooksPageContent?
    private var languagesTask: Task<Void, Never>?
#if DEBUG
    private var usesFixtureTranslation = false
#endif
    let menu = NSMenu(title: String(localized: "Translation"))
    private(set) var request: Request?
    private(set) var output: BooksPageContent? {
        didSet { onOutputChange?(output) }
    }
    var onOutputChange: ((BooksPageContent?) -> Void)?

    func installHost(in view: NSView) {
        let host = NSHostingView(rootView: BooksTranslationHost(model: self))
        host.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        view.addSubview(host, positioned: .below, relativeTo: nil)
    }

    func start() {
        guard languagesTask == nil else { return }
        updateMenu()
        languagesTask = Task { [weak self] in
            let supported = await LanguageAvailability().supportedLanguages
            guard let self, !Task.isCancelled else { return }
            let languages = supported.sorted {
                self.languageName($0).localizedStandardCompare(self.languageName($1)) == .orderedAscending
            }
            self.languages = languages
            let preferred = defaults.string(forKey: Self.targetKey) ?? "zh-Hans"
            let identifier = Locale.Language(identifier: preferred).maximalIdentifier
            target = languages.first { $0.maximalIdentifier == identifier } ?? languages.first ?? target
            updateMenu()
            prepareRequest()
        }
    }

    func stop() {
        languagesTask?.cancel()
        languagesTask = nil
        update(nil)
    }

#if DEBUG
    func startForUITests() {
        usesFixtureTranslation = true
        languages = [Locale.Language(identifier: "zh-Hans"), Locale.Language(identifier: "ja")]
        updateMenu()
    }
#endif

    func update(_ content: BooksPageContent?) {
        guard input != content else { return }
        let previous = input
        input = content
        if case .paragraphs(let previousParagraphs) = previous,
           case .paragraphs(let paragraphs) = content,
           previousParagraphs.map(\.text) == paragraphs.map(\.text) {
            if case .paragraphs(let translated) = output { showParagraphs(translated.map(\.text)) }
            return
        }
        prepareRequest()
    }

    private func prepareRequest() {
        guard case .paragraphs(let paragraphs) = input else {
            request = nil
            output = input
            return
        }
        guard let languages else {
            output = .translating
            return
        }
        guard !languages.isEmpty else {
            output = .translationUnavailable(
                String(localized: "macOS didn’t return any translation languages. Quit and reopen BooksHelper to try again.")
            )
            return
        }
#if DEBUG
        if usesFixtureTranslation {
            let result = target.languageCode?.identifier == "ja"
                ? "Japanese fixture translation" : "Chinese fixture translation"
            showParagraphs(Array(repeating: result, count: paragraphs.count))
            return
        }
#endif
        let texts = paragraphs.map(\.text)
        let key = Self.cacheKey(paragraphs: texts, target: target)
        if let cached = translatedPages.object(forKey: key) as? [String] {
            request = nil
            showParagraphs(cached)
            return
        }
        let source = NLLanguageRecognizer.dominantLanguage(for: texts.joined(separator: "\n\n")).map {
            Locale.Language(identifier: $0.rawValue)
        }
        if let source, source.languageCode == target.languageCode, source.script == target.script {
            request = nil
            output = input
        } else {
            request = Request(paragraphs: texts, source: source, target: target)
            output = .translating
        }
    }

    func translate(_ request: Request, using session: TranslationSession) async {
        guard self.request?.id == request.id, !Task.isCancelled else { return }
        let paragraphs = request.paragraphs
        let indices = paragraphs.indices.filter { paragraphs[$0].rangeOfCharacter(from: .letters) != nil }
        guard !indices.isEmpty else {
            showParagraphs(paragraphs)
            return
        }
        do {
            let responses = try await session.translations(from: indices.map {
                TranslationSession.Request(sourceText: paragraphs[$0])
            })
            guard self.request?.id == request.id, !Task.isCancelled else { return }
            guard responses.count == indices.count else {
                throw TranslationError.internalError
            }
            var translated = paragraphs
            for (index, response) in zip(indices, responses) { translated[index] = response.targetText }
            let key = Self.cacheKey(paragraphs: paragraphs, target: request.target)
            let characters = translated.reduce(key.length) { $0 + $1.utf16.count }
            translatedPages.setObject(translated as NSArray, forKey: key, cost: characters * 2)
            showParagraphs(translated)
        } catch {
            guard self.request?.id == request.id, !Task.isCancelled else { return }
            Self.log.error("System translation failed (\((error as NSError).domain, privacy: .public), \((error as NSError).code))")
            if TranslationError.nothingToTranslate ~= error {
                output = .noText
                return
            }
            let message = await failureMessage(for: error, request: request)
            guard self.request?.id == request.id, !Task.isCancelled else { return }
            output = .translationUnavailable(message)
        }
    }

    private func showParagraphs(_ translated: [String]) {
        guard case .paragraphs(let paragraphs) = input, paragraphs.count == translated.count else { return }
        output = .paragraphs(zip(paragraphs, translated).map { paragraph, text in
            var translation = paragraph
            translation.text = text
            return translation
        })
    }

    private static func cacheKey(paragraphs: [String], target: Locale.Language) -> NSString {
        let text = paragraphs.map { "\($0.utf16.count):\($0)" }.joined()
        return "\(target.maximalIdentifier)\n\(text)" as NSString
    }

    private func failureMessage(for error: any Error, request: Request) async -> String {
        let target = languageName(request.target)
        switch error {
        case TranslationError.unsupportedSourceLanguage:
            if let source = request.source {
                let name = languageName(source)
                return String(localized: "macOS can’t translate from \(name).")
            }
            return String(localized: "macOS doesn’t support the source language on this page.")
        case TranslationError.unsupportedTargetLanguage, TranslationError.unsupportedLanguagePairing:
            return String(localized: "macOS doesn’t support translating this page into \(target). Choose another language in the Translation menu.")
        case TranslationError.unableToIdentifyLanguage:
            return String(localized: "macOS couldn’t identify the language on this page. Try again on a page with more text.")
        default:
            break
        }

        let systemError = error as NSError
        let wasCanceled = error is CancellationError || TranslationError.alreadyCancelled ~= error
            || (systemError.domain == NSCocoaErrorDomain && systemError.code == NSUserCancelledError)
        var needsLanguagePacks = TranslationError.notInstalled ~= error
        if wasCanceled, !needsLanguagePacks {
            let availability = LanguageAvailability()
            if let source = request.source {
                needsLanguagePacks = await availability.status(from: source, to: request.target) == .supported
            } else {
                needsLanguagePacks = (try? await availability.status(for: request.text, to: request.target)) == .supported
            }
        }
        if needsLanguagePacks {
            return String(localized: "The language packs needed for \(target) aren’t ready. Choose Translation → Retry Translation to reopen the download prompt, or wait if the packs are already downloading.")
        }
        if wasCanceled {
            return String(localized: "Translation was canceled. Choose Translation → Retry Translation to try again.")
        }
        return String(localized: "The macOS translation service couldn’t finish translating into \(target). Choose Translation → Retry Translation to try again.")
    }

    private func languageName(_ language: Locale.Language) -> String {
        let identifier = language.script?.identifier == "Hans" && language.minimalIdentifier == "zh"
            ? "zh-Hans" : language.minimalIdentifier
        return Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }

    private func updateMenu() {
        menu.removeAllItems()
        let heading: String
        if let languages {
            heading = languages.isEmpty ? String(localized: "No Translation Languages Available")
                : String(localized: "Translate To")
        } else {
            heading = String(localized: "Loading Translation Languages…")
        }
        menu.addItem(NSMenuItem.sectionHeader(title: heading))
        for language in languages ?? [] {
            let item = NSMenuItem(title: languageName(language), action: #selector(selectTarget(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = language.minimalIdentifier
            item.state = language == target ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let retry = NSMenuItem(
            title: String(localized: "Retry Translation"), action: #selector(retryTranslation), keyEquivalent: ""
        )
        retry.target = self
        menu.addItem(retry)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(retryTranslation) else { return true }
        if case .translationUnavailable = output, let languages, !languages.isEmpty { return true }
        return false
    }

    @objc private func retryTranslation() {
        if case .translationUnavailable = output { prepareRequest() }
    }

    @objc private func selectTarget(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? String,
              let language = languages?.first(where: { $0.minimalIdentifier == identifier }) else { return }
        if language == target {
            retryTranslation()
            return
        }
        target = language
        saveTarget(identifier)
        updateMenu()
        prepareRequest()
    }

    private func saveTarget(_ identifier: String) {
#if DEBUG
        if usesFixtureTranslation { return }
#endif
        defaults.set(identifier, forKey: Self.targetKey)
    }
}

private struct BooksTranslationHost: View {
    let model: BooksTranslation

    var body: some View {
        if let request = model.request {
            Color.clear
                .translationTask(.init(source: request.source, target: request.target)) { session in
                    await model.translate(request, using: session)
                }
                .id(request.id)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}
