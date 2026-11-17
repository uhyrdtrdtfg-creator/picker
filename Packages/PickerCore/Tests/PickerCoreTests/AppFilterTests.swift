import Foundation
import XCTest
@testable import PickerCore

final class AppFilterTests: XCTestCase {
    func testReturnsFalseWhenAppearAutomaticallyIsFalse() {
        let filter = AppFilter(
            appearAutomatically: false,
            excludedBundleIDs: [],
            includedBundleIDs: ["com.apple.TextEdit"]
        )

        XCTAssertFalse(filter.shouldAppear(bundleID: "com.apple.TextEdit", websiteHost: nil))
        XCTAssertFalse(filter.shouldAppear(bundleID: "", websiteHost: nil))
    }

    func testExcludedBundleOrWebsiteHostHidesPopup() {
        let filter = AppFilter(
            appearAutomatically: true,
            excludedBundleIDs: ["com.apple.Terminal", "com.googlecode.iterm2"],
            includedBundleIDs: [],
            excludedWebsiteHosts: ["google.com", "https://Figma.com/file", "*.notion.so"]
        )

        XCTAssertFalse(filter.shouldAppear(bundleID: "com.apple.Terminal", websiteHost: nil))
        XCTAssertFalse(filter.shouldAppear(bundleID: "COM.APPLE.TERMINAL", websiteHost: nil))
        XCTAssertTrue(filter.shouldAppear(bundleID: "com.apple.Safari", websiteHost: "apple.com"))
        XCTAssertFalse(filter.shouldAppear(bundleID: "com.apple.Safari", websiteHost: "google.com"))
        XCTAssertFalse(filter.shouldAppear(bundleID: "com.apple.Safari", websiteHost: "docs.google.com"))
        XCTAssertTrue(filter.shouldAppear(bundleID: "com.apple.Safari", websiteHost: "notgoogle.com"))
        XCTAssertFalse(filter.shouldAppear(bundleID: "com.apple.Safari", websiteHost: "www.figma.com"))
        XCTAssertFalse(filter.shouldAppear(bundleID: "com.apple.Safari", websiteHost: "www.notion.so"))
        XCTAssertFalse(filter.shouldAppear(bundleID: "com.apple.Safari", websiteHost: "notion.so"))
    }

    func testIncludedBundleIDsRestrictsAppearanceAndExclusionStillWins() {
        let filter = AppFilter(
            appearAutomatically: true,
            excludedBundleIDs: ["com.apple.Terminal"],
            includedBundleIDs: ["com.apple.Notes", "com.apple.Terminal"]
        )

        XCTAssertTrue(filter.shouldAppear(bundleID: "com.apple.Notes", websiteHost: nil))
        XCTAssertFalse(filter.shouldAppear(bundleID: "com.apple.TextEdit", websiteHost: nil))
        XCTAssertFalse(filter.shouldAppear(bundleID: "com.apple.Terminal", websiteHost: nil))
        XCTAssertFalse(filter.shouldAppear(bundleID: "", websiteHost: nil))
        XCTAssertFalse(filter.shouldAppear(bundleID: nil, websiteHost: nil))
    }

    func testEmptyBundleIDStillAppearsWhenNoIncludeListIsSet() {
        let filter = AppFilter(
            appearAutomatically: true,
            excludedBundleIDs: ["com.apple.Terminal"],
            includedBundleIDs: []
        )

        XCTAssertTrue(filter.shouldAppear(bundleID: "", websiteHost: nil))
        XCTAssertTrue(filter.shouldAppear(bundleID: "   ", websiteHost: nil))
        XCTAssertTrue(filter.shouldAppear(bundleID: nil, websiteHost: nil))
        XCTAssertFalse(
            AppFilter(
                appearAutomatically: true,
                excludedBundleIDs: [],
                includedBundleIDs: [],
                excludedHosts: ["example.com"]
            ).shouldAppear(bundleID: "", websiteHost: "sub.example.com")
        )
    }

    func testCodableRoundTrip() throws {
        let original = AppFilter(
            appearAutomatically: true,
            excludedBundleIDs: ["com.apple.Terminal"],
            includedBundleIDs: ["com.apple.Safari"],
            excludedWebsiteHosts: ["docs.google.com"]
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AppFilter.self, from: data)
        XCTAssertEqual(decoded, original)
    }
}
