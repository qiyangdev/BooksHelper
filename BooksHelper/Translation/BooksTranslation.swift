import AppKit
import NaturalLanguage
import Observation
import SwiftUI
import Translation
import os

@Observable
final class BooksTranslation: NSObject, NSMenuDelegate {
    enum Engine: String, CaseIterable {
        case system, ollama

        var title: String {
            switch self {
            case .system: String(localized: "System Translation")
            case .ollama: String(localized: "Ollama")
            }
        }
    }

    enum Backend: Equatable {
        case system
        case ollama(OllamaTranslation.LocalModel)

        var cacheIdentifier: String {
            switch self {
            case .system: "system"
            case .ollama(let model): "ollama/\(model.name)/\(model.digest)"
            }
        }
    }

    private enum ModelList: Equatable {
        case loading
        case loaded([OllamaTranslation.LocalModel])
        case unavailable
    }

    struct Request: Equatable {
        let id = UUID()
        let paragraphs: [String]
        let source: Locale.Language?
        let target: Locale.Language
        let backend: Backend

        var text: String { paragraphs.joined(separator: "\n\n") }
    }

    struct PageProgress {
        var completed: [Int: String] = [:]
        var prefixes: [Int: String] = [:]

        func displayParagraphs(from originals: [BooksParagraph]) -> [BooksParagraph] {
            originals.enumerated().map { index, original in
                guard original.text.rangeOfCharacter(from: .letters) != nil else { return original }
                var paragraph = original
                if let translated = completed[index] {
                    paragraph.text = translated
                } else {
                    paragraph.translationPrefix = prefixes[index]
                    paragraph.isTranslationPlaceholder = true
                    paragraph.showsTranslationShimmer = paragraph.translationPrefix == nil
                }
                return paragraph
            }
        }
    }

    private static let targetKey = "BooksTranslationTargetLanguage"
    private static let engineKey = "BooksTranslationEngine"
    private static let modelKey = "BooksTranslationOllamaModel"
    private static let log = Logger(subsystem: "org.bookshelper.BooksHelper", category: "Translation")

    private let defaults = UserDefaults.standard
    private let translatedPages: NSCache<NSString, NSArray> = {
        let cache = NSCache<NSString, NSArray>()
        cache.countLimit = 64
        cache.totalCostLimit = 4 * 1024 * 1024
        return cache
    }()
    private var target = Locale.Language(identifier: "zh-Hans")
    private var engine: Engine = .system
    private(set) var mode: BooksSidebarMode = .translation
    private var preferredOllamaModel = OllamaTranslation.defaultModel
    private var modelList: ModelList = .loading
    private var languages: [Locale.Language]?
    private var input: BooksPageContent?
    private var languagesTask: Task<Void, Never>?
    private let ollama = OllamaTranslation()
    @ObservationIgnored private var pageProgress: PageProgress?
    @ObservationIgnored private var ollamaTask: Task<Void, Never>?
    @ObservationIgnored private var modelListTask: Task<Void, Never>?
    @ObservationIgnored private var modelMenu: NSMenu?
#if DEBUG
    private var usesFixtureTranslation = false
    private var failsNextFixtureRequest = false
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
        engine = defaults.string(forKey: Self.engineKey).flatMap(Engine.init(rawValue:)) ?? .system
        target = Locale.Language(identifier: defaults.string(forKey: Self.targetKey) ?? "zh-Hans")
        preferredOllamaModel = defaults.string(forKey: Self.modelKey) ?? OllamaTranslation.defaultModel
        updateMenu()
        loadSystemLanguages()
        refreshOllamaModels()
    }

    private func loadSystemLanguages() {
        languagesTask = Task { [weak self] in
            let supported = await LanguageAvailability().supportedLanguages
            guard let self, !Task.isCancelled else { return }
            let languages = supported.sorted {
                self.languageName($0).localizedStandardCompare(self.languageName($1)) == .orderedAscending
            }
            self.languages = languages
            if engine == .system { matchSystemTarget() }
            updateMenu()
            if engine == .system, mode == .translation { prepareRequest() }
        }
    }

    func stop() {
        languagesTask?.cancel()
        languagesTask = nil
        modelListTask?.cancel()
        modelListTask = nil
        update(nil)
    }

#if DEBUG
    func startForUITests(failFirstRequest: Bool = false) {
        usesFixtureTranslation = true
        failsNextFixtureRequest = failFirstRequest
        languages = [Locale.Language(identifier: "zh-Hans"), Locale.Language(identifier: "ja")]
        modelList = .loaded([
            .init(name: OllamaTranslation.defaultModel, digest: "fixture-qwen"),
            .init(name: "second-fixture:4b", digest: "fixture-second"),
        ])
        updateMenu()
    }
#endif

    func update(_ content: BooksPageContent?) {
        // Window visibility and AX refreshes can temporarily hide the current page.
        guard content != .loading, input != content else { return }
        let previous = input
        input = content
        if case .paragraphs(let previousParagraphs) = previous,
           case .paragraphs(let paragraphs) = content,
           previousParagraphs.map(\.text) == paragraphs.map(\.text) {
            if case .paragraphs(let translated) = output {
                if let pageProgress {
                    output = .paragraphs(pageProgress.displayParagraphs(from: paragraphs))
                } else {
                    showParagraphs(translated.map(\.text))
                }
            }
            return
        }
        prepareRequest()
    }

    private func prepareRequest() {
        ollamaTask?.cancel()
        ollamaTask = nil
        request = nil
        pageProgress = nil
        guard case .paragraphs(let paragraphs) = input else {
            output = input
            return
        }
        if mode == .summary {
            prepareSummary(paragraphs.map(\.text))
            return
        }
        guard let languages = availableTargets else {
            showTranslationPlaceholders(for: paragraphs)
            return
        }
        guard !languages.isEmpty else {
            output = .translationUnavailable(
                String(localized: "macOS didn’t return any translation languages.")
            )
            return
        }
        let backend: Backend
        switch engine {
        case .system:
            backend = .system
        case .ollama:
            guard let selectedOllamaModel else {
                if let failure = ollamaModelFailure {
                    output = failure
                } else {
                    showTranslationPlaceholders(for: paragraphs)
                }
                return
            }
            backend = .ollama(selectedOllamaModel)
        }
#if DEBUG
        if usesFixtureTranslation {
            if failsNextFixtureRequest {
                failsNextFixtureRequest = false
                output = .translationUnavailable("Fixture translation failed.")
                return
            }
            let systemResult = target.languageCode?.identifier == "ja"
                ? "Japanese fixture translation" : "Chinese fixture translation"
            let result: String
            switch backend {
            case .system:
                result = systemResult
            case .ollama(let model):
                result = model.name == OllamaTranslation.defaultModel ? "Ollama fixture translation"
                    : "\(model.name) translation"
            }
            showParagraphs(Array(repeating: result, count: paragraphs.count))
            return
        }
#endif
        let texts = paragraphs.map(\.text)
        let key = Self.cacheKey(paragraphs: texts, target: target, backend: backend)
        if let cached = translatedPages.object(forKey: key) as? [String] {
            showParagraphs(cached)
            return
        }
        let source = NLLanguageRecognizer.dominantLanguage(for: texts.joined(separator: "\n\n")).map {
            Locale.Language(identifier: $0.rawValue)
        }
        if let source, source.languageCode == target.languageCode, source.script == target.script {
            output = input
        } else {
            let request = Request(paragraphs: texts, source: source, target: target, backend: backend)
            self.request = request
            showTranslationPlaceholders(for: paragraphs)
            if case .ollama(let model) = backend {
                ollamaTask = Task { [weak self] in await self?.translateUsingOllama(request, model: model) }
            }
        }
    }

    private func translateUsingOllama(_ request: Request, model: OllamaTranslation.LocalModel) async {
        do {
            let translated = try await ollama.translate(
                request.paragraphs, source: request.source, target: request.target, model: model
            ) { [weak self] index, text, isComplete in
                self?.showTranslatedParagraph(text, at: index, for: request, isComplete: isComplete)
            }
            guard self.request?.id == request.id, !Task.isCancelled else { return }
            cacheAndShow(translated, for: request)
        } catch {
            guard self.request?.id == request.id, !Task.isCancelled else { return }
            let message: String
            switch error as? OllamaTranslation.Failure {
            case .httpStatus(404):
                message = String(localized: "Ollama couldn’t find \(model.name). Choose another model in the Translation menu or install it in Ollama.")
            case .httpStatus(let status):
                message = String(localized: "Ollama returned HTTP \(status). Check Ollama before retrying.")
            case .incompleteResponse:
                message = String(localized: "Ollama didn’t return a complete translation for this page.")
            case nil:
                if (error as? URLError)?.code == .timedOut {
                    message = String(localized: "Ollama took too long to translate this page.")
                } else {
                    message = String(localized: "Couldn’t reach Ollama at 127.0.0.1:11434. Start Ollama, then retry.")
                }
            }
            output = .translationUnavailable(message)
        }
    }

    func selectMode(_ mode: BooksSidebarMode) {
        guard self.mode != mode else { return }
        self.mode = mode
        if mode == .summary, selectedOllamaModel == nil { refreshOllamaModels() }
        prepareRequest()
    }

    private func prepareSummary(_ paragraphs: [String]) {
#if DEBUG
        if usesFixtureTranslation {
            output = .summary("Summary fixture")
            return
        }
#endif
        guard let model = selectedOllamaModel else {
            output = ollamaModelFailure ?? .summarizing
            return
        }
        let target = target
        let backend = Backend.ollama(model)
        let key = ("summary\n" + (Self.cacheKey(paragraphs: paragraphs, target: target, backend: backend) as String)) as NSString
        if let summary = translatedPages.object(forKey: key)?.firstObject as? String {
            output = .summary(summary)
            return
        }
        output = .summarizing
        ollamaTask = Task { [weak self, ollama] in
            do {
                let summary = try await ollama.summarize(paragraphs, target: target, model: model) { [weak self] partial in
                    guard let self, !Task.isCancelled, mode == .summary else { return }
                    let content = BooksPageContent.summary(partial)
                    if output != content { output = content }
                }
                guard let self, !Task.isCancelled else { return }
                translatedPages.setObject([summary] as NSArray, forKey: key, cost: (key.length + summary.utf16.count) * 2)
                if output != .summary(summary) { output = .summary(summary) }
            } catch {
                guard let self, !Task.isCancelled else { return }
                output = .translationUnavailable(String(localized: "Ollama couldn’t summarize this page. Check that the selected model is available, then retry."))
            }
        }
    }

    func translate(_ request: Request, using session: TranslationSession) async {
        guard self.request?.id == request.id, !Task.isCancelled else { return }
        let paragraphs = request.paragraphs
        let completed = pageProgress?.completed ?? [:]
        var translated = paragraphs.indices.map { completed[$0] ?? paragraphs[$0] }
        let indices = paragraphs.indices.filter {
            completed[$0] == nil && paragraphs[$0].rangeOfCharacter(from: .letters) != nil
        }
        guard !indices.isEmpty else {
            cacheAndShow(translated, for: request)
            return
        }
        do {
            let responses = session.translate(batch: indices.map {
                TranslationSession.Request(sourceText: paragraphs[$0], clientIdentifier: String($0))
            })
            var pending = Set(indices)
            for try await response in responses {
                guard self.request?.id == request.id, !Task.isCancelled else { return }
                guard let identifier = response.clientIdentifier, let index = Int(identifier),
                      pending.remove(index) != nil else { throw TranslationError.internalError }
                translated[index] = response.targetText
                showTranslatedParagraph(response.targetText, at: index, for: request)
            }
            guard self.request?.id == request.id, !Task.isCancelled else { return }
            guard pending.isEmpty else { throw TranslationError.internalError }
            cacheAndShow(translated, for: request)
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

    private func showTranslationPlaceholders(for paragraphs: [BooksParagraph]) {
        let progress = PageProgress()
        pageProgress = progress
        output = .paragraphs(progress.displayParagraphs(from: paragraphs))
    }

    private func showTranslatedParagraph(_ text: String, at index: Int, for request: Request, isComplete: Bool = true) {
        guard self.request?.id == request.id, !Task.isCancelled,
              var progress = pageProgress, case .paragraphs(let paragraphs) = input else { return }
        if isComplete {
            progress.completed[index] = text
            progress.prefixes.removeValue(forKey: index)
        } else {
            progress.prefixes[index] = text
        }
        pageProgress = progress
        let partial = BooksPageContent.paragraphs(progress.displayParagraphs(from: paragraphs))
        if output != partial { output = partial }
    }

    private func showParagraphs(_ translated: [String]) {
        pageProgress = nil
        guard case .paragraphs(let paragraphs) = input, paragraphs.count == translated.count else { return }
        output = .paragraphs(zip(paragraphs, translated).map { paragraph, text in
            var translation = paragraph
            translation.text = text
            return translation
        })
    }

    private func cacheAndShow(_ translated: [String], for request: Request) {
        let key = Self.cacheKey(paragraphs: request.paragraphs, target: request.target, backend: request.backend)
        let characters = translated.reduce(key.length) { $0 + $1.utf16.count }
        translatedPages.setObject(translated as NSArray, forKey: key, cost: characters * 2)
        self.request = nil
        showParagraphs(translated)
    }

    private static func cacheKey(paragraphs: [String], target: Locale.Language, backend: Backend) -> NSString {
        let text = paragraphs.map { "\($0.utf16.count):\($0)" }.joined()
        return "\(backend.cacheIdentifier)\n\(target.maximalIdentifier)\n\(text)" as NSString
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
            return String(localized: "The language packs needed for \(target) aren’t ready. Retry to reopen the download prompt, or wait if the packs are already downloading.")
        }
        if wasCanceled {
            return String(localized: "Translation was canceled.")
        }
        return String(localized: "The macOS translation service couldn’t finish translating into \(target).")
    }

    private func languageName(_ language: Locale.Language) -> String {
        let identifier = language.script?.identifier == "Hans" && language.minimalIdentifier == "zh"
            ? "zh-Hans" : language.minimalIdentifier
        return Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }

    private var availableTargets: [Locale.Language]? {
        guard engine == .ollama else { return languages }
        let fallback = ["en", "zh-Hans", "zh-Hant", "ja", "ko", "de", "es", "fr", "it", "pt", "ru"]
        var targets = languages.flatMap { $0.isEmpty ? nil : $0 }
            ?? fallback.map { Locale.Language(identifier: $0) }
        if !targets.contains(where: { $0.maximalIdentifier == target.maximalIdentifier }) {
            targets.append(target)
        }
        return targets.sorted { languageName($0).localizedStandardCompare(languageName($1)) == .orderedAscending }
    }

    private func matchSystemTarget() {
        guard let languages else { return }
        let identifier = target.maximalIdentifier
        target = languages.first { $0.maximalIdentifier == identifier } ?? languages.first ?? target
    }

    private var selectedOllamaModel: OllamaTranslation.LocalModel? {
        guard case .loaded(let models) = modelList else { return nil }
        return models.first { $0.name == preferredOllamaModel }
            ?? models.first { $0.name == OllamaTranslation.defaultModel }
            ?? models.first
    }

    private var ollamaModelFailure: BooksPageContent? {
        switch modelList {
        case .loading:
            nil
        case .loaded:
            .translationUnavailable(String(localized: "Install a local text model in Ollama, then retry."))
        case .unavailable:
            .translationUnavailable(String(localized: "Couldn’t load local Ollama models. Check that Ollama is running, then retry."))
        }
    }

    private func refreshOllamaModels() {
        guard (engine == .ollama || mode == .summary), modelListTask == nil else { return }
#if DEBUG
        if usesFixtureTranslation { return }
#endif
        if selectedOllamaModel == nil, modelList != .loading {
            modelList = .loading
            updateModelMenu()
        }
        modelListTask = Task { [weak self, ollama] in
            let refreshed: ModelList
            do {
                refreshed = .loaded(try await ollama.listModels())
            } catch {
                refreshed = .unavailable
            }
            guard let self, !Task.isCancelled else { return }
            modelListTask = nil
            let previousModel = selectedOllamaModel
            if refreshed == .unavailable, previousModel != nil { return }
            if modelList != refreshed {
                modelList = refreshed
                updateModelMenu()
                if (engine == .ollama || mode == .summary), (previousModel == nil || previousModel != selectedOllamaModel) {
                    prepareRequest()
                }
            }
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        if menu === modelMenu { refreshOllamaModels() }
    }

    private func updateMenu() {
        menu.removeAllItems()
        let targetMenu = NSMenu(title: String(localized: "Translate To"))
        let targets = availableTargets
        for language in targets ?? [] {
            let item = targetMenu.addItem(
                withTitle: languageName(language), action: #selector(selectTarget(_:)), keyEquivalent: ""
            )
            item.target = self
            item.representedObject = language.minimalIdentifier
            item.state = language.maximalIdentifier == target.maximalIdentifier ? .on : .off
        }
        if targetMenu.items.isEmpty {
            let title = targets == nil ? String(localized: "Loading Translation Languages…")
                : String(localized: "No Translation Languages Available")
            targetMenu.addItem(withTitle: title, action: nil, keyEquivalent: "").isEnabled = false
        }
        menu.addItem(withTitle: targetMenu.title, action: nil, keyEquivalent: "").submenu = targetMenu

        let engineMenu = NSMenu(title: String(localized: "Engine"))
        for choice in Engine.allCases {
            let item = engineMenu.addItem(withTitle: choice.title, action: #selector(selectEngine(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = choice.rawValue
            item.state = choice == engine ? .on : .off
        }
        menu.addItem(withTitle: engineMenu.title, action: nil, keyEquivalent: "").submenu = engineMenu

        modelMenu = nil
        if engine == .ollama {
            let models = NSMenu(title: String(localized: "Model"))
            models.delegate = self
            modelMenu = models
            updateModelMenu()
            menu.addItem(withTitle: models.title, action: nil, keyEquivalent: "").submenu = models
        }
    }

    private func updateModelMenu() {
        guard let modelMenu else { return }
        modelMenu.removeAllItems()
        if case .loaded(let models) = modelList {
            for model in models {
                let item = modelMenu.addItem(withTitle: model.name, action: #selector(selectModel(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = model.name
                item.state = model == selectedOllamaModel ? .on : .off
            }
        }
        if modelMenu.items.isEmpty {
            let title: String
            switch modelList {
            case .loading: title = String(localized: "Loading Models…")
            case .loaded: title = String(localized: "No Local Models")
            case .unavailable: title = String(localized: "Couldn’t Load Models")
            }
            modelMenu.addItem(withTitle: title, action: nil, keyEquivalent: "").isEnabled = false
        }
    }

    func retryTranslation() {
        guard case .translationUnavailable = output else { return }
        if engine == .system, languages?.isEmpty == true {
            languages = nil
            updateMenu()
            loadSystemLanguages()
        }
        if (engine == .ollama || mode == .summary), selectedOllamaModel == nil { refreshOllamaModels() }
        prepareRequest()
    }

    @objc private func selectTarget(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? String,
              let language = availableTargets?.first(where: { $0.minimalIdentifier == identifier }),
              language.maximalIdentifier != target.maximalIdentifier else { return }
        target = language
        savePreference(identifier, for: Self.targetKey)
        updateMenu()
        prepareRequest()
    }

    @objc private func selectEngine(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? String,
              let selection = Engine(rawValue: identifier), selection != engine else { return }
        engine = selection
        savePreference(selection.rawValue, for: Self.engineKey)
        if engine == .system {
            modelListTask?.cancel()
            modelListTask = nil
            matchSystemTarget()
        }
        updateMenu()
        refreshOllamaModels()
        prepareRequest()
    }

    @objc private func selectModel(_ sender: NSMenuItem) {
        guard engine == .ollama, let name = sender.representedObject as? String,
              name != selectedOllamaModel?.name,
              case .loaded(let models) = modelList,
              models.contains(where: { $0.name == name }) else { return }
        preferredOllamaModel = name
        savePreference(name, for: Self.modelKey)
        updateModelMenu()
        prepareRequest()
    }

    private func savePreference(_ value: String, for key: String) {
#if DEBUG
        if usesFixtureTranslation { return }
#endif
        defaults.set(value, forKey: key)
    }
}

private struct BooksTranslationHost: View {
    let model: BooksTranslation

    var body: some View {
        if let request = model.request, request.backend == .system {
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
