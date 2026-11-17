import Foundation
import XCTest
@testable import PickerActions

final class PickerActionsTests: XCTestCase {
    func testVisibilityMatrixAcrossInputsAndLengthBoundaries() {
        let empty = PickerSelectionSnapshot(text: "")
        XCTAssertEqual(visibleActions(for: empty).map(\.id), [.paste])

        let twoLetters = PickerSelectionSnapshot(text: "hi")
        XCTAssertEqual(
            visibleActions(for: twoLetters).map(\.id),
            [.copy, .cut, .paste, .search, .dictionary]
        )

        let threeLetters = PickerSelectionSnapshot(text: "cat")
        XCTAssertEqual(
            visibleActions(for: threeLetters).map(\.id),
            [.copy, .cut, .paste, .search, .dictionary, .spelling]
        )

        let twoHundredLetters = PickerSelectionSnapshot(text: String(repeating: "a", count: 200))
        XCTAssertEqual(
            visibleActions(for: twoHundredLetters).map(\.id),
            [.copy, .cut, .paste, .search, .dictionary, .spelling]
        )

        let twoHundredOneLetters = PickerSelectionSnapshot(text: String(repeating: "a", count: 201))
        XCTAssertEqual(
            visibleActions(for: twoHundredOneLetters).map(\.id),
            [.copy, .cut, .paste, .dictionary, .spelling]
        )

        let fourHundredLetters = PickerSelectionSnapshot(text: String(repeating: "b", count: 400))
        XCTAssertEqual(
            visibleActions(for: fourHundredLetters).map(\.id),
            [.copy, .cut, .paste, .dictionary, .spelling]
        )

        let fourHundredOneLetters = PickerSelectionSnapshot(text: String(repeating: "b", count: 401))
        XCTAssertEqual(
            visibleActions(for: fourHundredOneLetters).map(\.id),
            [.copy, .cut, .paste]
        )

        let multiWord = PickerSelectionSnapshot(text: "hello world")
        XCTAssertEqual(
            visibleActions(for: multiWord).map(\.id),
            [.copy, .cut, .paste, .search, .dictionary]
        )

        let singleLink = PickerSelectionSnapshot(text: "Visit https://example.com today.")
        let singleLinkActions = visibleActions(for: singleLink)
        XCTAssertEqual(
            singleLinkActions.map(\.id),
            [.copy, .cut, .paste, .search, .openLink, .dictionary]
        )
        XCTAssertEqual(
            singleLinkActions.first(where: { $0.id == .openLink })?.titleEn,
            "Open Link"
        )

        let multiLinks = PickerSelectionSnapshot(
            text: "Links: https://example.com and http://swift.org"
        )
        let multiLinkActions = visibleActions(for: multiLinks)
        XCTAssertEqual(
            multiLinkActions.first(where: { $0.id == .openLink })?.titleEn,
            "Open Links"
        )

        let duplicateLinks = PickerSelectionSnapshot(
            text: "https://example.com https://example.com"
        )
        XCTAssertEqual(
            visibleActions(for: duplicateLinks).first(where: { $0.id == .openLink })?.titleEn,
            "Open Link"
        )

        let nonHTTP = PickerSelectionSnapshot(
            text: "ftp://files.example.com",
            urls: [URL(string: "ftp://files.example.com")!, URL(string: "mailto:a@b.com")!]
        )
        XCTAssertFalse(visibleActions(for: nonHTTP).map(\.id).contains(.openLink))
    }

    func testGoogleDefaultAndAlternateSearchTemplatesPercentEncodeQuery() {
        XCTAssertEqual(PickerSearchEngine.defaultEngine, .google)
        XCTAssertEqual(
            PickerSearchEngine.allCases,
            [.google, .bing, .duckDuckGo, .baidu]
        )

        let querySnapshot = PickerSelectionSnapshot(text: "C++ & Swift 100%? #1 你好")
        let searchPlan = plan(id: .search, snapshot: querySnapshot)
        let expectedGoogle = URL(
            string: "https://www.google.com/search?q=C%2B%2B%20%26%20Swift%20100%25%3F%20%231%20%E4%BD%A0%E5%A5%BD"
        )!
        XCTAssertEqual(searchPlan, .openURL(expectedGoogle))

        XCTAssertEqual(
            PickerSearchEngine.bing.searchURL(for: "hello world"),
            URL(string: "https://www.bing.com/search?q=hello%20world")
        )
        XCTAssertEqual(
            PickerSearchEngine.duckDuckGo.searchURL(for: "hello world"),
            URL(string: "https://duckduckgo.com/?q=hello%20world")
        )
        XCTAssertEqual(
            PickerSearchEngine.baidu.searchURL(for: "中文 搜索"),
            URL(string: "https://www.baidu.com/s?wd=%E4%B8%AD%E6%96%87%20%E6%90%9C%E7%B4%A2")
        )

        let baiduPlan = plan(
            id: .search,
            snapshot: PickerSelectionSnapshot(text: "a=1&b=2"),
            modifiers: .none,
            searchTemplate: PickerSearchEngine.baidu.template
        )
        XCTAssertEqual(
            baiduPlan,
            .openURL(URL(string: "https://www.baidu.com/s?wd=a%3D1%26b%3D2")!)
        )
    }

    func testShiftAndOptionModifiersControlPlainTextAndOptionOpenCopiesURLs() {
        let textSnapshot = PickerSelectionSnapshot(text: "Rich text")
        XCTAssertEqual(
            plan(id: .copy, snapshot: textSnapshot, modifiers: .none),
            .copyText("Rich text", plainText: false)
        )
        XCTAssertEqual(
            plan(id: .copy, snapshot: textSnapshot, modifiers: .shift),
            .copyText("Rich text", plainText: true)
        )
        XCTAssertEqual(
            plan(id: .cut, snapshot: textSnapshot, modifiers: .none),
            .cutSelection(plainText: false)
        )
        XCTAssertEqual(
            plan(id: .cut, snapshot: textSnapshot, modifiers: .shift),
            .cutSelection(plainText: true)
        )
        XCTAssertEqual(
            plan(id: .paste, snapshot: textSnapshot, modifiers: .none),
            .pasteClipboard(plainText: false)
        )
        XCTAssertEqual(
            plan(id: .paste, snapshot: textSnapshot, modifiers: PickerActionModifiers(shift: true)),
            .pasteClipboard(plainText: true)
        )

        let linksSnapshot = PickerSelectionSnapshot(
            text: "See (https://apple.com/macos), https://swift.org/blog, and https://apple.com/macos."
        )
        let expectedURLs = [
            URL(string: "https://apple.com/macos")!,
            URL(string: "https://swift.org/blog")!
        ]
        XCTAssertEqual(
            plan(id: .openLink, snapshot: linksSnapshot, modifiers: .none),
            .openURL(expectedURLs)
        )
        XCTAssertEqual(
            plan(id: .openLink, snapshot: linksSnapshot, modifiers: .option),
            .copyURLs("https://apple.com/macos\nhttps://swift.org/blog")
        )
    }

    func testDictionaryTrimsSurroundingUnicodePunctuationAndRejectsPunctuationOnly() {
        XCTAssertEqual(dictionaryTerm(from: "  (cat)  "), "cat")
        XCTAssertEqual(dictionaryTerm(from: "\"hello,\""), "hello")
        XCTAssertEqual(dictionaryTerm(from: "“world”?!"), "world")
        XCTAssertEqual(dictionaryTerm(from: "「词典」。"), "词典")
        XCTAssertEqual(dictionaryTerm(from: "don't"), "don't")
        XCTAssertEqual(dictionaryTerm(from: "well-known"), "well-known")
        XCTAssertEqual(dictionaryTerm(from: "..."), "")

        let wrappedSnapshot = PickerSelectionSnapshot(text: "  “serendipity,”  ")
        XCTAssertTrue(visibleActions(for: wrappedSnapshot).map(\.id).contains(.dictionary))
        XCTAssertEqual(
            plan(id: .dictionary, snapshot: wrappedSnapshot),
            .lookupTerm("serendipity")
        )

        for nonWord in ["...", "---?!---", "  , ,  ", "“   ”"] {
            let snapshot = PickerSelectionSnapshot(text: nonWord)
            XCTAssertFalse(
                visibleActions(for: snapshot).map(\.id).contains(.dictionary),
                "Expected dictionary to be hidden for \(String(reflecting: nonWord))"
            )
        }
    }

    func testRevealFileRequiresExactlyOneAbsolutePath() {
        let noPath = PickerSelectionSnapshot(text: "plain selection")
        XCTAssertFalse(visibleActions(for: noPath).map(\.id).contains(.revealFile))
        XCTAssertEqual(plan(id: .revealFile, snapshot: noPath), .revealPath(""))

        let relativePath = PickerSelectionSnapshot(text: "Packages/PickerActions/Package.swift")
        XCTAssertFalse(visibleActions(for: relativePath).map(\.id).contains(.revealFile))

        let tildePath = PickerSelectionSnapshot(text: "~/Desktop/notes.md")
        XCTAssertFalse(visibleActions(for: tildePath).map(\.id).contains(.revealFile))

        let singlePath = PickerSelectionSnapshot(text: "/Users/alice/My Documents/report.pdf")
        let singleActions = visibleActions(for: singlePath)
        XCTAssertTrue(singleActions.map(\.id).contains(.revealFile))
        XCTAssertEqual(
            plan(id: .revealFile, snapshot: singlePath),
            .revealPath("/Users/alice/My Documents/report.pdf")
        )

        let escapedSpacePath = PickerSelectionSnapshot(text: #"/Users/alice/My\ Documents/report.pdf"#)
        XCTAssertTrue(visibleActions(for: escapedSpacePath).map(\.id).contains(.revealFile))
        XCTAssertEqual(
            plan(id: .revealFile, snapshot: escapedSpacePath),
            .revealPath("/Users/alice/My Documents/report.pdf")
        )

        let fileURLSnapshot = PickerSelectionSnapshot(
            text: "file:///Users/alice/My%20Documents/report.pdf"
        )
        XCTAssertTrue(visibleActions(for: fileURLSnapshot).map(\.id).contains(.revealFile))
        XCTAssertFalse(visibleActions(for: fileURLSnapshot).map(\.id).contains(.openLink))
        XCTAssertEqual(
            plan(id: .revealFile, snapshot: fileURLSnapshot),
            .revealPath("/Users/alice/My Documents/report.pdf")
        )

        let twoLines = PickerSelectionSnapshot(text: "/tmp/first.txt\n/tmp/second.txt")
        XCTAssertFalse(visibleActions(for: twoLines).map(\.id).contains(.revealFile))
        XCTAssertEqual(plan(id: .revealFile, snapshot: twoLines), .revealPath(""))

        let twoInline = PickerSelectionSnapshot(text: "/tmp/first.txt /tmp/second.txt")
        XCTAssertFalse(visibleActions(for: twoInline).map(\.id).contains(.revealFile))
        XCTAssertEqual(plan(id: .revealFile, snapshot: twoInline), .revealPath(""))

        let explicitTwo = PickerSelectionSnapshot(
            text: "selected files",
            filePaths: ["/Users/alice/a.txt", "/Users/alice/b.txt"]
        )
        XCTAssertFalse(visibleActions(for: explicitTwo).map(\.id).contains(.revealFile))
        XCTAssertEqual(plan(id: .revealFile, snapshot: explicitTwo), .revealPath(""))
    }

    func testSpellingGuessesReturnsPlaceholderListWithOriginalWordOnly() {
        let wordSnapshot = PickerSelectionSnapshot(text: "  recieve  ")
        XCTAssertTrue(visibleActions(for: wordSnapshot).map(\.id).contains(.spelling))
        XCTAssertEqual(
            plan(id: .spelling, snapshot: wordSnapshot),
            .spellingGuesses(["recieve"])
        )

        let wordWithDigits = PickerSelectionSnapshot(text: "swift6")
        XCTAssertFalse(visibleActions(for: wordWithDigits).map(\.id).contains(.spelling))
    }
}
