import Foundation

/// Identifiers for Picker's built-in selection actions in popup display order.
public enum PickerActionID: String, CaseIterable, Codable, Hashable, Sendable {
    case copy
    case cut
    case paste
    case search
    case openLink
    case dictionary
    case revealFile
    case spelling
}

/// Metadata describing a visible built-in action item in the popup bar.
public struct PickerAction: Identifiable, Equatable, Hashable, Codable, Sendable {
    public let id: PickerActionID
    public let titleEn: String
    public let titleZh: String
    public let symbolName: String

    public init(
        id: PickerActionID,
        titleEn: String,
        titleZh: String,
        symbolName: String
    ) {
        self.id = id
        self.titleEn = titleEn
        self.titleZh = titleZh
        self.symbolName = symbolName
    }
}

/// Keyboard modifier flags that alter built-in action execution behavior.
public struct PickerActionModifiers: OptionSet, Hashable, Codable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public init(shift: Bool = false, option: Bool = false) {
        var bits = 0
        if shift {
            bits |= Self.shift.rawValue
        }
        if option {
            bits |= Self.option.rawValue
        }
        self.rawValue = bits
    }

    public static let none: PickerActionModifiers = []
    public static let shift = PickerActionModifiers(rawValue: 1 << 0)
    public static let option = PickerActionModifiers(rawValue: 1 << 1)

    /// Shift transforms Copy, Cut, and Paste into plain-text operations.
    public var prefersPlainText: Bool {
        contains(.shift)
    }

    /// Option turns Open Link into copying newline-joined URLs instead of opening them.
    public var copiesURLsOnly: Bool {
        contains(.option)
    }
}

/// Built-in web search engines using `***` as the percent-encoded query placeholder.
public enum PickerSearchEngine: String, CaseIterable, Codable, Hashable, Sendable {
    case google
    case bing
    case duckDuckGo
    case baidu

    public static let defaultEngine: PickerSearchEngine = .google
    public static let placeholder = "***"

    private static let rfc3986Unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    public var displayName: String {
        switch self {
        case .google:
            return "Google"
        case .bing:
            return "Bing"
        case .duckDuckGo:
            return "DuckDuckGo"
        case .baidu:
            return "Baidu"
        }
    }

    public var template: String {
        switch self {
        case .google:
            return "https://www.google.com/search?q=***"
        case .bing:
            return "https://www.bing.com/search?q=***"
        case .duckDuckGo:
            return "https://duckduckgo.com/?q=***"
        case .baidu:
            return "https://www.baidu.com/s?wd=***"
        }
    }

    public func searchURL(for query: String) -> URL? {
        Self.searchURL(template: template, for: query)
    }

    public static func percentEncodeQuery(_ query: String) -> String {
        query.addingPercentEncoding(withAllowedCharacters: rfc3986Unreserved) ?? query
    }

    public static func searchURL(
        template: String = PickerSearchEngine.defaultEngine.template,
        for query: String
    ) -> URL? {
        guard template.contains(placeholder) else { return nil }
        let encoded = percentEncodeQuery(query)
        let expanded = template.replacingOccurrences(of: placeholder, with: encoded)
        guard
            let components = URLComponents(string: expanded),
            let scheme = components.scheme,
            !scheme.isEmpty,
            let url = components.url
        else {
            return nil
        }
        return url
    }
}

/// Trims surrounding whitespace and leading/trailing Unicode punctuation from a lookup string.
public func dictionaryTerm(from text: String) -> String {
    let trimmedWhitespace = text.trimmingCharacters(in: .whitespacesAndNewlines)
    var slice = trimmedWhitespace[...]
    while let first = slice.first, first.isPunctuation {
        slice = slice.dropFirst()
    }
    while let last = slice.last, last.isPunctuation {
        slice = slice.dropLast()
    }
    return String(slice)
}

func validDictionaryTerm(from text: String) -> String? {
    let term = dictionaryTerm(from: text)
    guard (1...400).contains(term.count) else { return nil }
    guard !term.allSatisfy({ $0.isPunctuation || $0.isWhitespace }) else { return nil }
    return term
}

func validSpellingWord(from text: String) -> String? {
    let word = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard (3...400).contains(word.count), word.allSatisfy(\.isLetter) else {
        return nil
    }
    return word
}

/// Computes the ordered list of built-in actions visible for `snapshot`.
public func visibleActions(for snapshot: PickerSelectionSnapshot) -> [PickerAction] {
    visibleActionsForProvider(snapshot)
}

/// Computes the ordered list of built-in actions visible for any snapshot provider.
public func visibleActions<Snapshot: PickerSelectionSnapshotProviding>(
    for snapshot: Snapshot
) -> [PickerAction] {
    visibleActionsForProvider(snapshot)
}

private func visibleActionsForProvider<Snapshot: PickerSelectionSnapshotProviding>(
    _ snapshot: Snapshot
) -> [PickerAction] {
    var actions: [PickerAction] = []
    let text = snapshot.text

    if !text.isEmpty {
        actions.append(
            PickerAction(
                id: .copy,
                titleEn: "Copy",
                titleZh: "拷贝",
                symbolName: "doc.on.doc"
            )
        )
        actions.append(
            PickerAction(
                id: .cut,
                titleEn: "Cut",
                titleZh: "剪切",
                symbolName: "scissors"
            )
        )
    }

    actions.append(
        PickerAction(
            id: .paste,
            titleEn: "Paste",
            titleZh: "粘贴",
            symbolName: "doc.on.clipboard"
        )
    )

    if (1...200).contains(text.count) {
        actions.append(
            PickerAction(
                id: .search,
                titleEn: "Search",
                titleZh: "搜索",
                symbolName: "magnifyingglass"
            )
        )
    }

    let httpURLs = PickerSelectionSnapshot.filterAndDeduplicateHTTPURLs(snapshot.urls)
    if !httpURLs.isEmpty {
        let englishTitle = httpURLs.count == 1 ? "Open Link" : "Open Links"
        actions.append(
            PickerAction(
                id: .openLink,
                titleEn: englishTitle,
                titleZh: "打开链接",
                symbolName: "link"
            )
        )
    }

    if validDictionaryTerm(from: text) != nil {
        actions.append(
            PickerAction(
                id: .dictionary,
                titleEn: "Dictionary",
                titleZh: "词典",
                symbolName: "book"
            )
        )
    }

    let absolutePaths = PickerSelectionSnapshot.filterAndDeduplicateAbsolutePaths(snapshot.filePaths)
    if absolutePaths.count == 1 {
        actions.append(
            PickerAction(
                id: .revealFile,
                titleEn: "Reveal in Finder",
                titleZh: "在 Finder 中显示",
                symbolName: "folder"
            )
        )
    }

    if validSpellingWord(from: text) != nil {
        actions.append(
            PickerAction(
                id: .spelling,
                titleEn: "Spelling",
                titleZh: "拼写",
                symbolName: "textformat.abc.dottedunderline"
            )
        )
    }

    return actions
}
