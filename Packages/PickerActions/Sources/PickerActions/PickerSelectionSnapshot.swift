import Foundation

/// Minimal selection surface needed to determine visible actions and build action plans.
public protocol PickerSelectionSnapshotProviding: Sendable {
    var text: String { get }
    var urls: [URL] { get }
    var filePaths: [String] { get }
}

/// Pure-Foundation snapshot of selected text, detected web URLs, and detected absolute POSIX paths.
public struct PickerSelectionSnapshot: PickerSelectionSnapshotProviding, Equatable, Hashable, Sendable {
    public let text: String
    public let urls: [URL]
    public let filePaths: [String]

    public init(
        text: String = "",
        urls: [URL]? = nil,
        filePaths: [String]? = nil
    ) {
        self.text = text
        if let urls {
            self.urls = Self.filterAndDeduplicateHTTPURLs(urls)
        } else {
            self.urls = Self.detectHTTPURLs(in: text)
        }
        if let filePaths {
            self.filePaths = Self.filterAndDeduplicateAbsolutePaths(filePaths)
        } else {
            self.filePaths = Self.detectAbsolutePaths(in: text)
        }
    }

    public static func filterAndDeduplicateHTTPURLs(_ candidates: [URL]) -> [URL] {
        var unique: [URL] = []
        var seen: Set<String> = []
        for url in candidates {
            guard
                let scheme = url.scheme?.lowercased(),
                scheme == "http" || scheme == "https",
                let host = url.host,
                !host.isEmpty
            else {
                continue
            }
            if seen.insert(url.absoluteString).inserted {
                unique.append(url)
            }
        }
        return unique
    }

    public static func detectHTTPURLs(in text: String) -> [URL] {
        guard !text.isEmpty else { return [] }
        guard let regex = try? NSRegularExpression(pattern: #"(?i)\bhttps?://[^\s<>"`]+"#) else {
            return []
        }

        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, range: fullRange)
        var detected: [URL] = []

        for match in matches {
            guard let range = Range(match.range, in: text) else { continue }
            let cleaned = stripTrailingURLPunctuation(String(text[range]))
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
            detected.append(url)
        }

        return filterAndDeduplicateHTTPURLs(detected)
    }

    public static func filterAndDeduplicateAbsolutePaths(_ candidates: [String]) -> [String] {
        var unique: [String] = []
        var seen: Set<String> = []
        for rawPath in candidates {
            guard isValidAbsolutePath(rawPath) else { continue }
            if seen.insert(rawPath).inserted {
                unique.append(rawPath)
            }
        }
        return unique
    }

    public static func detectAbsolutePaths(in text: String) -> [String] {
        guard !text.isEmpty, !text.contains("\0") else { return [] }
        guard
            let splitRegex = try? NSRegularExpression(pattern: #"(?<!\\)\s+(?=/[^\s/])"#),
            let inlineRegex = try? NSRegularExpression(
                pattern: #""(/[^"\r\n]+)"|'(/[^'\r\n]+)'|`(/[^`\r\n]+)`|(?:^|(?<=[\s(\[{]))(/[A-Za-z0-9._\-](?:\\ |[^\s"'`<>])*)"#
            ),
            let fileURLRegex = try? NSRegularExpression(pattern: #"(?i)\bfile:///[^\s<>"`]+"#),
            let schemeRegex = try? NSRegularExpression(pattern: #"(?i)[a-z][a-z0-9+.\-]*://[^\s<>"`]+"#)
        else {
            return []
        }

        var detected: [String] = []
        let horizontalWhitespace = CharacterSet(charactersIn: " \t")

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: horizontalWhitespace)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("/"), !line.hasPrefix("//"), line.count >= 2 {
                let secondIndex = line.index(after: line.startIndex)
                if !line[secondIndex].isWhitespace {
                    detected.append(contentsOf: splitPathLine(line, using: splitRegex))
                    continue
                }
            }

            let lineRange = NSRange(line.startIndex..<line.endIndex, in: line)
            for fileMatch in fileURLRegex.matches(in: line, range: lineRange) {
                guard let urlRange = Range(fileMatch.range, in: line) else { continue }
                let cleanedURL = stripTrailingURLPunctuation(String(line[urlRange]))
                if let url = URL(string: cleanedURL), url.isFileURL, isValidAbsolutePath(url.path) {
                    detected.append(url.path)
                }
            }

            let urlRanges = schemeRegex.matches(in: line, range: lineRange).map(\.range)

            for match in inlineRegex.matches(in: line, range: lineRange) {
                if urlRanges.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) {
                    continue
                }
                for group in 1...4 {
                    guard let captureRange = Range(match.range(at: group), in: line) else { continue }
                    var candidate = String(line[captureRange])
                    if group == 4 {
                        candidate = stripTrailingPathPunctuation(
                            candidate.replacingOccurrences(of: #"\ "#, with: " ")
                        )
                    }
                    if isValidAbsolutePath(candidate) {
                        detected.append(candidate)
                    }
                    break
                }
            }
        }

        return filterAndDeduplicateAbsolutePaths(detected)
    }

    private static func splitPathLine(_ line: String, using splitRegex: NSRegularExpression) -> [String] {
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        let splits = splitRegex.matches(in: line, range: range)
        guard !splits.isEmpty else {
            let unescaped = line.replacingOccurrences(of: #"\ "#, with: " ")
            return isValidAbsolutePath(unescaped) ? [unescaped] : []
        }

        var segments: [String] = []
        var segmentStart = line.startIndex
        for split in splits {
            guard let splitRange = Range(split.range, in: line) else { continue }
            let segment = String(line[segmentStart..<splitRange.lowerBound])
                .trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: #"\ "#, with: " ")
            if isValidAbsolutePath(segment) {
                segments.append(segment)
            }
            segmentStart = splitRange.upperBound
        }
        let remainder = String(line[segmentStart...])
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: #"\ "#, with: " ")
        if isValidAbsolutePath(remainder) {
            segments.append(remainder)
        }
        return segments
    }

    private static func isValidAbsolutePath(_ candidate: String) -> Bool {
        guard
            candidate.count >= 2,
            candidate.hasPrefix("/"),
            !candidate.hasPrefix("//"),
            !candidate.contains("\0")
        else {
            return false
        }
        let secondIndex = candidate.index(after: candidate.startIndex)
        return !candidate[secondIndex].isWhitespace
    }

    private static func stripTrailingURLPunctuation(_ raw: String) -> String {
        var result = raw
        while let last = result.last {
            switch last {
            case ".", ",", ";", ":", "!", "?", "'":
                result.removeLast()
            case ")":
                if occurrences(of: "(", in: result) < occurrences(of: ")", in: result) {
                    result.removeLast()
                } else {
                    return result
                }
            case "]":
                if occurrences(of: "[", in: result) < occurrences(of: "]", in: result) {
                    result.removeLast()
                } else {
                    return result
                }
            case "}":
                if occurrences(of: "{", in: result) < occurrences(of: "}", in: result) {
                    result.removeLast()
                } else {
                    return result
                }
            default:
                return result
            }
        }
        return result
    }

    private static func stripTrailingPathPunctuation(_ raw: String) -> String {
        var result = raw
        while let last = result.last {
            switch last {
            case ".", ",", ";", ":", "!", "?":
                result.removeLast()
            case ")":
                if occurrences(of: "(", in: result) < occurrences(of: ")", in: result) {
                    result.removeLast()
                } else {
                    return result
                }
            case "]":
                if occurrences(of: "[", in: result) < occurrences(of: "]", in: result) {
                    result.removeLast()
                } else {
                    return result
                }
            case "}":
                if occurrences(of: "{", in: result) < occurrences(of: "}", in: result) {
                    result.removeLast()
                } else {
                    return result
                }
            default:
                return result
            }
        }
        return result
    }

    private static func occurrences(of character: Character, in string: String) -> Int {
        string.reduce(into: 0) { total, current in
            if current == character {
                total += 1
            }
        }
    }
}
