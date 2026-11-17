import CoreGraphics
import Foundation
import XCTest
@testable import PickerCore

final class SelectionSnapshotTests: XCTestCase {
    func testIsEmptyAfterTrim() {
        XCTAssertTrue(SelectionSnapshot(text: "").isEmpty)
        XCTAssertTrue(SelectionSnapshot(text: "   ").isEmpty)
        XCTAssertTrue(SelectionSnapshot(text: "\n\t \r\n").isEmpty)
        XCTAssertTrue(SelectionSnapshot(text: "\u{00A0}").isEmpty)

        let nonEmpty = SelectionSnapshot(
            text: "  hello world  ",
            range: NSRange(location: 4, length: 15),
            bounds: CGRect(x: 100, y: 200, width: 120, height: 22),
            frontAppBundleID: "com.apple.TextEdit",
            frontAppName: "TextEdit"
        )
        XCTAssertFalse(nonEmpty.isEmpty)
        XCTAssertEqual(nonEmpty.trimmedText, "hello world")
        XCTAssertEqual(nonEmpty.range, NSRange(location: 4, length: 15))
        XCTAssertEqual(nonEmpty.bounds, CGRect(x: 100, y: 200, width: 120, height: 22))
        XCTAssertEqual(nonEmpty.frontAppBundleID, "com.apple.TextEdit")
        XCTAssertEqual(nonEmpty.frontAppName, "TextEdit")
    }

    func testExtractsHttpAndHttpsURLsOnly() {
        let text = """
        Visit https://apple.com/macos, http://localhost:8080/health?ready=1#top,
        and HTTPS://Example.ORG/docs! Ignore ftp://files.example.com/archive.zip,
        mailto:support@example.com, file:///Users/alice/notes.txt, and bare example.com.
        """

        let snapshot = SelectionSnapshot(text: text)
        XCTAssertEqual(
            snapshot.detectedURLs.map(\.absoluteString),
            [
                "https://apple.com/macos",
                "http://localhost:8080/health?ready=1#top",
                "HTTPS://Example.ORG/docs"
            ]
        )
        XCTAssertEqual(snapshot.urls, snapshot.detectedURLs)
    }

    func testStripsSurroundingMarkdownAndBalancedParenthesesInURLs() {
        let text = """
        Read ([Swift](https://en.wikipedia.org/wiki/Swift_(programming_language))).
        Also check <https://example.com/feed.xml> and 'https://example.com/quoted'.
        Duplicate [https://example.com/feed.xml](https://example.com/feed.xml) counts once.
        """

        let urls = SelectionSnapshot.extractURLs(from: text)
        XCTAssertEqual(
            urls.map(\.absoluteString),
            [
                "https://en.wikipedia.org/wiki/Swift_(programming_language)",
                "https://example.com/feed.xml",
                "https://example.com/quoted"
            ]
        )

        let ipv6AndInvalid = "Check [http://[::1]:8080/status] and broken http:// or https://."
        XCTAssertEqual(
            SelectionSnapshot.extractURLs(from: ipv6AndInvalid).map(\.absoluteString),
            ["http://[::1]:8080/status"]
        )
    }

    func testCapsExtractedURLsAtEight() {
        let text = (1...12)
            .map { "https://example.com/items/\($0)" }
            .joined(separator: "\n")

        let snapshot = SelectionSnapshot(text: text)
        XCTAssertEqual(snapshot.detectedURLs.count, 8)
        XCTAssertEqual(snapshot.detectedURLs.first?.absoluteString, "https://example.com/items/1")
        XCTAssertEqual(snapshot.detectedURLs.last?.absoluteString, "https://example.com/items/8")
    }

    func testExtractsAllowedAbsolutePosixFilePathsWithoutTouchingDisk() {
        let text = """
        Inspect /Users/nonexistent_picker_user_999/Documents/spec.md,
        open "/Applications/Nonexistent Picker Studio.app",
        and check (/tmp/picker-nonexistent-12345.log).
        """

        let snapshot = SelectionSnapshot(text: text)
        XCTAssertEqual(
            snapshot.detectedFilePaths,
            [
                "/Users/nonexistent_picker_user_999/Documents/spec.md",
                "/Applications/Nonexistent Picker Studio.app",
                "/tmp/picker-nonexistent-12345.log"
            ]
        )
        XCTAssertEqual(snapshot.filePaths, snapshot.detectedFilePaths)
    }

    func testIgnoresDisallowedRootsRelativePathsAndURLPaths() {
        let text = """
        Ignore /etc/hosts, /var/log/system.log, /usr/bin/swift, /UsersFake/file.txt,
        Users/alice/relative.txt, ./tmp/local.txt,
        https://example.com/Users/alice/profile, and file:///tmp/url-only.txt.
        Keep --log=/tmp/actual-output.txt and /Applications/System\\ Settings.app.
        """

        let paths = SelectionSnapshot.extractFilePaths(from: text)
        XCTAssertEqual(
            paths,
            [
                "/tmp/actual-output.txt",
                "/Applications/System Settings.app"
            ]
        )
    }

    func testCapsExtractedFilePathsAtFour() {
        let text = (1...7)
            .map { "/tmp/sample-file-\($0).txt" }
            .joined(separator: " ")

        let snapshot = SelectionSnapshot(text: text)
        XCTAssertEqual(
            snapshot.detectedFilePaths,
            [
                "/tmp/sample-file-1.txt",
                "/tmp/sample-file-2.txt",
                "/tmp/sample-file-3.txt",
                "/tmp/sample-file-4.txt"
            ]
        )
    }

    func testExtractsStandaloneUnquotedPathsWithSpacesWithoutMatchingProse() {
        XCTAssertEqual(
            SelectionSnapshot.extractFilePaths(from: "/Applications/System Settings.app"),
            ["/Applications/System Settings.app"]
        )
        XCTAssertEqual(
            SelectionSnapshot.extractFilePaths(from: "/Users/alice/Library/Application Support/Picker"),
            ["/Users/alice/Library/Application Support/Picker"]
        )
        XCTAssertEqual(
            SelectionSnapshot.extractFilePaths(from: "/tmp/output.log was deleted yesterday"),
            ["/tmp/output.log"]
        )
    }
}
