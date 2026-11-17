import CoreGraphics
import Foundation

/// Immutable snapshot of a user text selection and its source context.
///
/// `bounds` is expressed in AppKit screen points (origin at the bottom-left of the primary
/// display, matching `NSScreen.visibleFrame` and `NSWindow`).
public struct SelectionSnapshot: Equatable, Sendable {
    public static let maxDetectedURLs = 8
    public static let maxDetectedFilePaths = 4
    private static let maxScanCharacters = 65_536

    public let text: String
    public let range: NSRange?
    public let bounds: CGRect
    public let frontAppBundleID: String
    public let frontAppName: String
    public let detectedURLs: [URL]
    public let detectedFilePaths: [String]

    public init(
        text: String,
        range: NSRange? = nil,
        bounds: CGRect = .zero,
        frontAppBundleID: String = "",
        frontAppName: String = "",
        detectedURLs: [URL]? = nil,
        detectedFilePaths: [String]? = nil
    ) {
        self.text = text
        self.range = range
        self.bounds = bounds
        self.frontAppBundleID = frontAppBundleID
        self.frontAppName = frontAppName
        self.detectedURLs = detectedURLs ?? Self.extractURLs(from: text)
        self.detectedFilePaths = detectedFilePaths ?? Self.extractFilePaths(from: text)
    }

    public var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var isEmpty: Bool {
        trimmedText.isEmpty
    }

    public var urls: [URL] {
        detectedURLs
    }

    public var filePaths: [String] {
        detectedFilePaths
    }

    /// Extracts distinct `http` and `https` URLs from `text`, preserving order and capping at `limit`.
    public static func extractURLs(from text: String, limit: Int = maxDetectedURLs) -> [URL] {
        guard limit > 0, !text.isEmpty else { return [] }
        let scanned = scanPrefix(of: text)
        guard let regex = try? NSRegularExpression(
            pattern: #"(?i)\bhttps?://(?:\[[0-9a-f:.]+\]|[^\s<>"`\[\]/]+)(?:[^\s<>"`\[\]]*)"#
        ) else {
            return []
        }

        let nsRange = NSRange(scanned.startIndex..<scanned.endIndex, in: scanned)
        let matches = regex.matches(in: scanned, range: nsRange)

        var results: [URL] = []
        var seen: Set<String> = []

        for match in matches {
            guard let swiftRange = Range(match.range, in: scanned) else { continue }
            let cleaned = trimTrailingURLPunctuation(String(scanned[swiftRange]))
            guard
                let components = URLComponents(string: cleaned),
                let scheme = components.scheme?.lowercased(),
                scheme == "http" || scheme == "https",
                let host = components.host,
                !host.isEmpty,
                let url = components.url
            else {
                continue
            }

            let canonical = url.absoluteString
            if seen.insert(canonical).inserted {
                results.append(url)
                if results.count >= limit {
                    break
                }
            }
        }

        return results
    }

    /// Extracts absolute POSIX paths rooted at `/Users`, `/Applications`, or `/tmp`,
    /// preserving order and capping at `limit` without accessing the filesystem.
    public static func extractFilePaths(from text: String, limit: Int = maxDetectedFilePaths) -> [String] {
        guard limit > 0, !text.isEmpty else { return [] }
        let scanned = scanPrefix(of: text)

        if let standalone = standaloneSpacedFilePath(in: scanned) {
            return [standalone]
        }

        let excludedRanges = urlLikeRanges(in: scanned)
        guard let regex = try? NSRegularExpression(
            pattern: #"(?:"(/(?:Users|Applications|tmp)/[^"\r\n]+)"|'(/(?:Users|Applications|tmp)/[^'\r\n]+)'|`(/(?:Users|Applications|tmp)/[^`\r\n]+)`|(?:^|(?<=[\s(\[{<="'`]))(/(?:Users|Applications|tmp)/(?:\\ |[^\s"'`<>\[\]])+))"#
        ) else {
            return []
        }

        let fullNSRange = NSRange(scanned.startIndex..<scanned.endIndex, in: scanned)
        let matches = regex.matches(in: scanned, range: fullNSRange)

        var results: [String] = []
        var seen: Set<String> = []

        for match in matches {
            if excludedRanges.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) {
                continue
            }

            let candidate: String
            if let quotedDouble = Range(match.range(at: 1), in: scanned) {
                candidate = String(scanned[quotedDouble])
            } else if let quotedSingle = Range(match.range(at: 2), in: scanned) {
                candidate = String(scanned[quotedSingle])
            } else if let quotedBacktick = Range(match.range(at: 3), in: scanned) {
                candidate = String(scanned[quotedBacktick])
            } else if let unquoted = Range(match.range(at: 4), in: scanned) {
                let raw = String(scanned[unquoted]).replacingOccurrences(of: #"\ "#, with: " ")
                candidate = trimTrailingPathPunctuation(raw)
            } else {
                continue
            }

            guard isAllowedAbsolutePath(candidate) else { continue }

            if seen.insert(candidate).inserted {
                results.append(candidate)
                if results.count >= limit {
                    break
                }
            }
        }

        return results
    }

    private static func scanPrefix(of text: String) -> String {
        guard text.count > maxScanCharacters else { return text }
        let endIndex = text.index(text.startIndex, offsetBy: maxScanCharacters)
        return String(text[..<endIndex])
    }

    private static func standaloneSpacedFilePath(in text: String) -> String? {
        let trimmed = trimTrailingPathPunctuation(
            text.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        guard
            !trimmed.contains("\n"),
            !trimmed.contains("\r"),
            trimmed.contains(" "),
            !trimmed.contains(#"\ "#),
            isAllowedAbsolutePath(trimmed)
        else {
            return nil
        }

        let secondRootMarkers = [" /Users/", " /Applications/", " /tmp/"]
        if secondRootMarkers.contains(where: { trimmed.contains($0) }) {
            return nil
        }

        guard let firstSpace = trimmed.firstIndex(of: " ") else { return nil }
        let afterFirstSpace = trimmed[firstSpace...]
        if afterFirstSpace.contains("/") {
            return trimmed
        }

        let lastComponent = (trimmed as NSString).lastPathComponent
        let ext = (lastComponent as NSString).pathExtension
        if !ext.isEmpty && ext.count <= 12 && ext.allSatisfy({ $0.isLetter || $0.isNumber }) {
            return trimmed
        }

        return nil
    }

    private static func urlLikeRanges(in text: String) -> [NSRange] {
        guard let regex = try? NSRegularExpression(pattern: #"(?i)[a-z][a-z0-9+.\-]*://[^\s<>"`]+"#) else {
            return []
        }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: nsRange).map(\.range)
    }

    private static func isAllowedAbsolutePath(_ path: String) -> Bool {
        let allowedPrefixes = ["/Users/", "/Applications/", "/tmp/"]
        for prefix in allowedPrefixes where path.hasPrefix(prefix) {
            let remainder = path.dropFirst(prefix.count)
            let stripped = remainder.trimmingCharacters(
                in: CharacterSet(charactersIn: "/").union(.whitespacesAndNewlines)
            )
            return !stripped.isEmpty && !path.contains("\0")
        }
        return false
    }

    private static func trimTrailingURLPunctuation(_ raw: String) -> String {
        var current = raw
        while let last = current.last {
            switch last {
            case ".", ",", ";", ":", "!", "?", "'":
                current.removeLast()
            case ")":
                if count(of: "(", in: current) < count(of: ")", in: current) {
                    current.removeLast()
                } else {
                    return current
                }
            case "]":
                if count(of: "[", in: current) < count(of: "]", in: current) {
                    current.removeLast()
                } else {
                    return current
                }
            case "}":
                if count(of: "{", in: current) < count(of: "}", in: current) {
                    current.removeLast()
                } else {
                    return current
                }
            default:
                return current
            }
        }
        return current
    }

    private static func trimTrailingPathPunctuation(_ raw: String) -> String {
        var current = raw
        while let last = current.last {
            switch last {
            case ".", ",", ";", ":", "!", "?":
                current.removeLast()
            case ")":
                if count(of: "(", in: current) < count(of: ")", in: current) {
                    current.removeLast()
                } else {
                    return current
                }
            case "]":
                if count(of: "[", in: current) < count(of: "]", in: current) {
                    current.removeLast()
                } else {
                    return current
                }
            case "}":
                if count(of: "{", in: current) < count(of: "}", in: current) {
                    current.removeLast()
                } else {
                    return current
                }
            default:
                return current
            }
        }
        return current
    }

    private static func count(of target: Character, in text: String) -> Int {
        text.reduce(into: 0) { acc, ch in
            if ch == target { acc += 1 }
        }
    }
}
