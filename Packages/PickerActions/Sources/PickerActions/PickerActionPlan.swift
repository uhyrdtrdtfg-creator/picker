import Foundation

/// Pure value description of the effect a Mac action runner should perform.
public enum PickerActionPlan: Equatable, Hashable, Sendable {
    case copyText(String, plainText: Bool)
    case cutSelection(plainText: Bool)
    case pasteClipboard(plainText: Bool)
    case openURL([URL])
    case copyURLs(String)
    case lookupTerm(String)
    case revealPath(String)
    case spellingGuesses([String])

    public static let maxLinksToOpen = 25

    public static func openURL(_ url: URL) -> PickerActionPlan {
        .openURL([url])
    }

    public static func copyURLs(_ urls: [URL]) -> PickerActionPlan {
        .copyURLs(urls.map(\.absoluteString).joined(separator: "\n"))
    }
}

/// Builds an execution plan for `id` against `snapshot` using the default Google search template.
public func plan(
    id: PickerActionID,
    snapshot: PickerSelectionSnapshot,
    modifiers: PickerActionModifiers = .none
) -> PickerActionPlan {
    plan(
        id: id,
        snapshot: snapshot,
        modifiers: modifiers,
        searchTemplate: PickerSearchEngine.defaultEngine.template
    )
}

/// Builds an execution plan for `id` against `snapshot` with a configurable search URL template.
public func plan(
    id: PickerActionID,
    snapshot: PickerSelectionSnapshot,
    modifiers: PickerActionModifiers,
    searchTemplate: String
) -> PickerActionPlan {
    buildPlan(
        id: id,
        snapshot: snapshot,
        modifiers: modifiers,
        searchTemplate: searchTemplate
    )
}

/// Builds an execution plan for `id` against any snapshot provider.
public func plan<Snapshot: PickerSelectionSnapshotProviding>(
    id: PickerActionID,
    snapshot: Snapshot,
    modifiers: PickerActionModifiers = .none,
    searchTemplate: String = PickerSearchEngine.defaultEngine.template
) -> PickerActionPlan {
    buildPlan(
        id: id,
        snapshot: snapshot,
        modifiers: modifiers,
        searchTemplate: searchTemplate
    )
}

private func buildPlan<Snapshot: PickerSelectionSnapshotProviding>(
    id: PickerActionID,
    snapshot: Snapshot,
    modifiers: PickerActionModifiers,
    searchTemplate: String
) -> PickerActionPlan {
    let usePlainText = modifiers.prefersPlainText

    switch id {
    case .copy:
        return .copyText(snapshot.text, plainText: usePlainText)

    case .cut:
        return .cutSelection(plainText: usePlainText)

    case .paste:
        return .pasteClipboard(plainText: usePlainText)

    case .search:
        let resolvedURL = PickerSearchEngine.searchURL(template: searchTemplate, for: snapshot.text)
            ?? PickerSearchEngine.defaultEngine.searchURL(for: snapshot.text)
        return .openURL(resolvedURL.map { [$0] } ?? [])

    case .openLink:
        let httpURLs = PickerSelectionSnapshot.filterAndDeduplicateHTTPURLs(snapshot.urls)
        if modifiers.copiesURLsOnly {
            return .copyURLs(httpURLs)
        }
        return .openURL(Array(httpURLs.prefix(PickerActionPlan.maxLinksToOpen)))

    case .dictionary:
        return .lookupTerm(dictionaryTerm(from: snapshot.text))

    case .revealFile:
        let absolutePaths = PickerSelectionSnapshot.filterAndDeduplicateAbsolutePaths(snapshot.filePaths)
        let singlePath = absolutePaths.count == 1 ? absolutePaths[0] : ""
        return .revealPath(singlePath)

    case .spelling:
        let word = snapshot.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return .spellingGuesses(word.isEmpty ? [] : [word])
    }
}
