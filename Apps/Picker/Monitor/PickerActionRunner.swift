import AppKit
import CoreServices
import Foundation

typealias PickerRunnableAction = PickerActionRunner.Action

enum PickerActionError: Error, Equatable, Sendable, LocalizedError {
    case emptySelection
    case emptyClipboard
    case pasteboardWriteFailed
    case accessibilityWriteFailed
    case invalidSearchQuery
    case noLinksFound
    case urlOpenFailed
    case missingFile(String)
    case noSpellingGuesses

    var errorDescription: String? {
        switch self {
        case .emptySelection: return "No text is selected."
        case .emptyClipboard: return "The clipboard is empty."
        case .pasteboardWriteFailed: return "Could not write to the clipboard."
        case .accessibilityWriteFailed: return "Could not modify text in the focused element."
        case .invalidSearchQuery: return "The search query is empty."
        case .noLinksFound: return "No HTTP or HTTPS links were found in the selection."
        case .urlOpenFailed: return "Could not open the URL."
        case .missingFile(let path): return "File does not exist at path: \(path)"
        case .noSpellingGuesses: return "No spelling suggestions are available."
        }
    }
}

enum PickerActionResult: Equatable, Sendable {
    case success
    case failure(PickerActionError)

    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}

protocol ActionWorkspacePerforming {
    func open(_ url: URL) -> Bool
    func canOpen(_ url: URL) -> Bool
    func systemDictionaryApplicationURL() -> URL?
    func activateFileViewerSelecting(_ fileURLs: [URL])
}

struct SystemActionWorkspace: ActionWorkspacePerforming {
    private static let dictionaryBundleID = "com.apple.Dictionary"
    private static let dictionaryAppPaths = [
        "/System/Applications/Dictionary.app",
        "/Applications/Dictionary.app"
    ]

    func open(_ url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }

    func canOpen(_ url: URL) -> Bool {
        NSWorkspace.shared.urlForApplication(toOpen: url) != nil
    }

    func systemDictionaryApplicationURL() -> URL? {
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.dictionaryBundleID) {
            return appURL
        }
        for path in Self.dictionaryAppPaths where FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    func activateFileViewerSelecting(_ fileURLs: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(fileURLs)
    }
}

protocol SpellGuessProviding {
    func guesses(forWord word: String) -> [String]
}

struct SystemSpellGuessProvider: SpellGuessProviding {
    func guesses(forWord word: String) -> [String] {
        let checker = NSSpellChecker.shared
        let range = NSRange(location: 0, length: (word as NSString).length)
        return checker.guesses(forWordRange: range, in: word, language: nil, inSpellDocumentWithTag: 0) ?? []
    }
}

private final class SpellingMenuTarget: NSObject {
    var selectedGuess: String?

    @objc func chooseGuess(_ sender: NSMenuItem) {
        selectedGuess = (sender.representedObject as? String) ?? sender.title
    }
}

final class PickerActionRunner {
    enum Action: String, CaseIterable, Sendable, Hashable {
        case copy
        case cut
        case paste
        case search
        case openLink
        case dictionary
        case revealFile
        case spelling

        init?(actionID: String) {
            switch actionID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "copy", "app.popclip.builtin.copy":
                self = .copy
            case "cut", "app.popclip.builtin.cut":
                self = .cut
            case "paste", "app.popclip.builtin.paste":
                self = .paste
            case "search", "app.popclip.builtin.search":
                self = .search
            case "openlink", "open-link", "open_link", "app.popclip.builtin.openlink":
                self = .openLink
            case "dictionary", "lookup", "app.popclip.builtin.lookup", "app.popclip.builtin.dictionary":
                self = .dictionary
            case "reveal", "revealfile", "revealinfinder", "reveal-in-finder", "reveal_in_finder", "app.popclip.builtin.revealfile":
                self = .revealFile
            case "spelling", "app.popclip.builtin.spelling":
                self = .spelling
            default:
                return nil
            }
        }
    }

    static let maxLinksToOpen = 8
    static let maxSpellingGuesses = 5
    private static let googleSearchBaseURL = "https://www.google.com/search?q="

    private let pasteboard: NSPasteboard
    private let textEditor: FocusedTextEditing
    private let workspace: ActionWorkspacePerforming
    private let spellChecker: SpellGuessProviding
    private let fileManager: FileManager
    private let dictionaryAlertPresenter: (String, String?) -> Void
    private let spellingMenuPresenter: ([String], NSPoint) -> String?
    private var capturedSelectionTarget: AnyObject?

    init(
        pasteboard: NSPasteboard = .general,
        textEditor: FocusedTextEditing = AccessibilityFocusedElementClient(),
        workspace: ActionWorkspacePerforming = SystemActionWorkspace(),
        spellChecker: SpellGuessProviding = SystemSpellGuessProvider(),
        fileManager: FileManager = .default,
        dictionaryAlertPresenter: @escaping (String, String?) -> Void = PickerActionRunner.presentDictionaryAlert,
        spellingMenuPresenter: @escaping ([String], NSPoint) -> String? = PickerActionRunner.presentSpellingMenu
    ) {
        self.pasteboard = pasteboard
        self.textEditor = textEditor
        self.workspace = workspace
        self.spellChecker = spellChecker
        self.fileManager = fileManager
        self.dictionaryAlertPresenter = dictionaryAlertPresenter
        self.spellingMenuPresenter = spellingMenuPresenter
    }

    func captureSelectionTarget() {
        capturedSelectionTarget = textEditor.captureFocusedTarget()
    }

    func hasExistingFile(in selection: String) -> Bool {
        let resolvedPath = resolveCandidatePath(from: selection)
        return !resolvedPath.isEmpty && fileManager.fileExists(atPath: resolvedPath)
    }

    func run(
        actionID: String,
        selection: String,
        modifiers: NSEvent.ModifierFlags = NSEvent.modifierFlags,
        anchorPoint: NSPoint? = nil
    ) -> PickerActionResult? {
        guard let action = Action(actionID: actionID) else { return nil }
        return run(action, selection: selection, modifiers: modifiers, anchorPoint: anchorPoint)
    }

    func run(
        _ action: Action,
        selection: String,
        modifiers: NSEvent.ModifierFlags = NSEvent.modifierFlags,
        anchorPoint: NSPoint? = nil
    ) -> PickerActionResult {
        switch action {
        case .copy: return copy(selection, modifiers: modifiers)
        case .cut: return cut(selection, modifiers: modifiers)
        case .paste: return paste(modifiers: modifiers)
        case .search: return search(selection)
        case .openLink: return openLink(selection, modifiers: modifiers)
        case .dictionary: return dictionary(selection)
        case .revealFile: return revealFile(selection)
        case .spelling: return spelling(selection, anchorPoint: anchorPoint)
        }
    }

    func copy(_ selection: String, modifiers: NSEvent.ModifierFlags = []) -> PickerActionResult {
        guard !selection.isEmpty else { return .failure(.emptySelection) }

        let plainTextOnly = modifiers.contains(.shift)
        pasteboard.clearContents()

        if !plainTextOnly,
           let attributed = textEditor.copySelectedAttributedText(from: capturedSelectionTarget),
           attributed.string == selection {
            let fullRange = NSRange(location: 0, length: attributed.length)
            if let rtfData = try? attributed.data(
                from: fullRange,
                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
            ) {
                pasteboard.setData(rtfData, forType: .rtf)
            }
        }

        return pasteboard.setString(selection, forType: .string)
            ? .success
            : .failure(.pasteboardWriteFailed)
    }

    func cut(_ selection: String, modifiers: NSEvent.ModifierFlags = []) -> PickerActionResult {
        let copyResult = copy(selection, modifiers: modifiers)
        guard copyResult.isSuccess else { return copyResult }
        return textEditor.setSelectedText("", in: capturedSelectionTarget)
            ? .success
            : .failure(.accessibilityWriteFailed)
    }

    func paste(modifiers: NSEvent.ModifierFlags = []) -> PickerActionResult {
        let clipboardString = readClipboardString(plainTextOnly: modifiers.contains(.shift))
        guard let clipboardString, !clipboardString.isEmpty else {
            return .failure(.emptyClipboard)
        }

        if textEditor.setSelectedText(clipboardString, in: capturedSelectionTarget) {
            return .success
        }
        if textEditor.insertAtFocusedPosition(clipboardString, in: capturedSelectionTarget) {
            return .success
        }
        return .failure(.accessibilityWriteFailed)
    }

    func search(_ selection: String) -> PickerActionResult {
        let query = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty,
              let encodedQuery = Self.percentEncodeQueryValue(query),
              let googleURL = URL(string: Self.googleSearchBaseURL + encodedQuery) else {
            return .failure(.invalidSearchQuery)
        }
        return workspace.open(googleURL) ? .success : .failure(.urlOpenFailed)
    }

    func openLink(_ selection: String, modifiers: NSEvent.ModifierFlags = []) -> PickerActionResult {
        let urls = Self.extractHTTPURLs(from: selection, limit: Self.maxLinksToOpen)
        guard !urls.isEmpty else { return .failure(.noLinksFound) }

        if modifiers.contains(.option) {
            let joined = urls.map(\.absoluteString).joined(separator: "\n")
            pasteboard.clearContents()
            return pasteboard.setString(joined, forType: .string)
                ? .success
                : .failure(.pasteboardWriteFailed)
        }

        for url in urls where !workspace.open(url) {
            return .failure(.urlOpenFailed)
        }
        return .success
    }

    func dictionary(_ selection: String) -> PickerActionResult {
        let term = Self.dictionaryTerm(from: selection)
        guard !term.isEmpty else { return .failure(.emptySelection) }

        if let encodedTerm = Self.percentEncodePathSegment(term),
           let dictURL = URL(string: "dict:///\(encodedTerm)"),
           workspace.canOpen(dictURL),
           workspace.open(dictURL) {
            return .success
        }

        if let dictionaryAppURL = workspace.systemDictionaryApplicationURL(),
           workspace.open(dictionaryAppURL) {
            return .success
        }

        dictionaryAlertPresenter(term, Self.lookupSystemDefinition(for: term))
        return .success
    }

    func revealFile(_ selection: String) -> PickerActionResult {
        let resolvedPath = resolveCandidatePath(from: selection)
        guard !resolvedPath.isEmpty, fileManager.fileExists(atPath: resolvedPath) else {
            return .failure(.missingFile(resolvedPath))
        }
        workspace.activateFileViewerSelecting([URL(fileURLWithPath: resolvedPath)])
        return .success
    }

    func spellingGuesses(for selection: String) -> [String] {
        let word = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { return [] }
        return Array(spellChecker.guesses(forWord: word).prefix(Self.maxSpellingGuesses))
    }

    func spelling(_ selection: String, anchorPoint: NSPoint? = nil) -> PickerActionResult {
        let word = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { return .failure(.emptySelection) }

        let target = capturedSelectionTarget ?? textEditor.captureFocusedTarget()
        let guesses = Array(spellChecker.guesses(forWord: word).prefix(Self.maxSpellingGuesses))
        guard !guesses.isEmpty else { return .failure(.noSpellingGuesses) }

        let menuPoint = anchorPoint ?? NSEvent.mouseLocation
        guard let chosenGuess = spellingMenuPresenter(guesses, menuPoint) else {
            return .success
        }

        let replacement: String
        if let wordRange = selection.range(of: word) {
            replacement = selection.replacingCharacters(in: wordRange, with: chosenGuess)
        } else {
            replacement = chosenGuess
        }

        if textEditor.setSelectedText(replacement, in: target) { return .success }
        if textEditor.insertAtFocusedPosition(replacement, in: target) { return .success }
        return .failure(.accessibilityWriteFailed)
    }

    static func extractHTTPURLs(from text: String, limit: Int = maxLinksToOpen) -> [URL] {
        guard limit > 0, !text.isEmpty,
              let regex = try? NSRegularExpression(pattern: #"(?i)\bhttps?://[^\s<>"`]+"#) else {
            return []
        }

        let matches = regex.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text))
        var urls: [URL] = []
        var seen = Set<String>()

        for match in matches {
            guard let range = Range(match.range, in: text) else { continue }
            let cleaned = trimTrailingURLPunctuation(String(text[range]))
            guard let components = URLComponents(string: cleaned),
                  let scheme = components.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  let host = components.host, !host.isEmpty,
                  let url = components.url else {
                continue
            }
            if seen.insert(url.absoluteString).inserted {
                urls.append(url)
                if urls.count >= limit { break }
            }
        }
        return urls
    }

    private func readClipboardString(plainTextOnly: Bool) -> String? {
        if let plain = pasteboard.string(forType: .string) { return plain }
        guard !plainTextOnly else { return nil }
        let objects = pasteboard.readObjects(forClasses: [NSAttributedString.self], options: nil) as? [NSAttributedString]
        return objects?.first?.string
    }

    private func resolveCandidatePath(from selection: String) -> String {
        var candidate = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return "" }
        candidate = Self.stripMatchingQuotes(candidate)

        if candidate.lowercased().hasPrefix("file://"), let url = URL(string: candidate), url.isFileURL {
            return url.path
        }

        let expanded = (candidate as NSString).expandingTildeInPath
        if fileManager.fileExists(atPath: expanded) { return expanded }

        if let extracted = Self.extractFirstPOSIXPath(from: selection) {
            return (extracted as NSString).expandingTildeInPath
        }
        return expanded
    }

    private static func stripMatchingQuotes(_ value: String) -> String {
        guard value.count >= 2 else { return value }
        for (open, close) in [("\"", "\""), ("'", "'"), ("`", "`")] as [(Character, Character)]
        where value.first == open && value.last == close {
            return String(value.dropFirst().dropLast())
        }
        return value
    }

    private static func extractFirstPOSIXPath(from text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"(?:~|/)(?:\\ |[^\s"'`<>])+"#),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)),
              let range = Range(match.range, in: text) else {
            return nil
        }
        return trimTrailingURLPunctuation(String(text[range]).replacingOccurrences(of: #"\ "#, with: " "))
    }

    private static func dictionaryTerm(from selection: String) -> String {
        let trimmed = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let stripped = trimmed.trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines))
        return stripped.isEmpty ? trimmed : stripped
    }

    private static func lookupSystemDefinition(for term: String) -> String? {
        let range = CFRange(location: 0, length: term.utf16.count)
        return DCSCopyTextDefinition(nil, term as CFString, range).map { $0.takeRetainedValue() as String }
    }

    private static func percentEncodeQueryValue(_ value: String) -> String? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=#?;:/")
        return value.addingPercentEncoding(withAllowedCharacters: allowed)
    }

    private static func percentEncodePathSegment(_ value: String) -> String? {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        return value.addingPercentEncoding(withAllowedCharacters: allowed)
    }

    private static func trimTrailingURLPunctuation(_ raw: String) -> String {
        var current = raw
        while let last = current.last {
            switch last {
            case ".", ",", ";", ":", "!", "?", "'": current.removeLast()
            case ")":
                guard characterCount("(", in: current) < characterCount(")", in: current) else { return current }
                current.removeLast()
            case "]":
                guard characterCount("[", in: current) < characterCount("]", in: current) else { return current }
                current.removeLast()
            case "}":
                guard characterCount("{", in: current) < characterCount("}", in: current) else { return current }
                current.removeLast()
            default:
                return current
            }
        }
        return current
    }

    private static func characterCount(_ target: Character, in text: String) -> Int {
        text.reduce(into: 0) { count, character in if character == target { count += 1 } }
    }

    private static func presentDictionaryAlert(term: String, definition: String?) {
        let present = {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = term
            alert.informativeText = (definition?.isEmpty == false) ? definition! : "System Dictionary is not available."
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
        Thread.isMainThread ? present() : DispatchQueue.main.sync(execute: present)
    }

    private static func presentSpellingMenu(guesses: [String], screenPoint: NSPoint) -> String? {
        let present: () -> String? = {
            let target = SpellingMenuTarget()
            let menu = NSMenu(title: "Spelling")
            menu.autoenablesItems = false
            menu.font = NSFont.menuFont(ofSize: NSFont.smallSystemFontSize)
            for guess in guesses {
                let item = NSMenuItem(title: guess, action: #selector(SpellingMenuTarget.chooseGuess(_:)), keyEquivalent: "")
                item.target = target
                item.representedObject = guess
                item.isEnabled = true
                menu.addItem(item)
            }
            _ = menu.popUp(positioning: nil, at: screenPoint, in: nil)
            return target.selectedGuess
        }
        return Thread.isMainThread ? present() : DispatchQueue.main.sync(execute: present)
    }
}
