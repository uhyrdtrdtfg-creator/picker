import CoreGraphics
import XCTest
@testable import PickerCore

final class PopupPlacementTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 25, width: 1440, height: 850)
    private let popupSize = CGSize(width: 180, height: 36)

    func testPlacesAboveSelectionWithSixPointGapWhenPreferredAndRoomExists() {
        let selection = CGRect(x: 400, y: 300, width: 100, height: 20)

        let placed = PopupPlacement.place(
            selectionBounds: selection,
            screenVisible: screen,
            preferAbove: true,
            popupSize: popupSize
        )

        XCTAssertEqual(placed.origin.x, 360)
        XCTAssertEqual(placed.origin.y, selection.maxY + 6)
        XCTAssertEqual(placed.size, popupSize)
        XCTAssertTrue(screen.contains(placed))
    }

    func testFlipsBelowSelectionWhenAboveWouldLeaveVisibleFrame() {
        // screen.maxY is 875; selection.maxY is 860, so above (866..902) exceeds 875.
        let selection = CGRect(x: 400, y: 840, width: 100, height: 20)

        let placed = PopupPlacement.place(
            selectionBounds: selection,
            screenVisible: screen,
            preferAbove: true,
            popupSize: popupSize
        )

        XCTAssertEqual(placed.origin.x, 360)
        XCTAssertEqual(placed.origin.y, selection.minY - 6 - popupSize.height)
        XCTAssertEqual(selection.minY - placed.maxY, 6)
        XCTAssertTrue(screen.contains(placed))
    }

    func testPlacesBelowWhenPreferAboveIsFalseAndFlipsAboveNearBottom() {
        let middleSelection = CGRect(x: 400, y: 300, width: 100, height: 20)
        let placedBelow = PopupPlacement.place(
            selectionBounds: middleSelection,
            screenVisible: screen,
            preferAbove: false,
            popupSize: popupSize
        )
        XCTAssertEqual(placedBelow.origin.y, middleSelection.minY - 6 - popupSize.height)

        // Near bottom (screen.minY is 25): below would be 35 - 6 - 36 = -7 < 25, so flip above.
        let bottomSelection = CGRect(x: 400, y: 35, width: 100, height: 20)
        let flippedAbove = PopupPlacement.place(
            selectionBounds: bottomSelection,
            screenVisible: screen,
            preferAbove: false,
            popupSize: popupSize
        )
        XCTAssertEqual(flippedAbove.origin.y, bottomSelection.maxY + 6)
        XCTAssertTrue(screen.contains(flippedAbove))
    }

    func testClampsHorizontallyAndVerticallyInsideVisibleFrame() {
        // Near left edge on a secondary display with negative coordinates.
        let secondaryScreen = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let leftSelection = CGRect(x: -1915, y: 500, width: 20, height: 18)
        let clampedLeft = PopupPlacement.place(
            selectionBounds: leftSelection,
            screenVisible: secondaryScreen,
            preferAbove: true,
            popupSize: popupSize
        )
        XCTAssertEqual(clampedLeft.minX, secondaryScreen.minX)
        XCTAssertTrue(secondaryScreen.contains(clampedLeft))

        // Near right edge of primary screen.
        let rightSelection = CGRect(x: 1420, y: 500, width: 15, height: 18)
        let clampedRight = PopupPlacement.place(
            selectionBounds: rightSelection,
            screenVisible: screen,
            preferAbove: true,
            popupSize: popupSize
        )
        XCTAssertEqual(clampedRight.maxX, screen.maxX)
        XCTAssertTrue(screen.contains(clampedRight))

        // Full-height selection where neither above nor below fits without clamping.
        let tallSelection = CGRect(x: 500, y: 30, width: 100, height: 840)
        let clampedTall = PopupPlacement.place(
            selectionBounds: tallSelection,
            screenVisible: screen,
            preferAbove: true,
            popupSize: popupSize
        )
        XCTAssertTrue(screen.contains(clampedTall))
    }

    func testConvertsQuartzTopLeftScreenCoordinatesToAppKit() {
        let quartz = CGRect(x: 120, y: 100, width: 80, height: 20)
        let converted = PopupPlacement.convertFromQuartzScreen(quartz, primaryScreenHeight: 900)
        XCTAssertEqual(converted, CGRect(x: 120, y: 780, width: 80, height: 20))
    }

    func testHandlesNullSelectionBoundsInsideVisibleFrame() {
        let placed = PopupPlacement.place(
            selectionBounds: .null,
            screenVisible: screen,
            preferAbove: true,
            popupSize: popupSize
        )
        XCTAssertTrue(screen.contains(placed))
        XCTAssertFalse(placed.origin.x.isNaN || placed.origin.y.isNaN)
    }

    func testZeroSelectionBoundsDoesNotClampToBottomOfVisibleFrame() {
        let dockScreen = CGRect(x: 0, y: 54, width: 1728, height: 1030)
        let placed = PopupPlacement.place(
            selectionBounds: .zero,
            screenVisible: dockScreen,
            preferAbove: true,
            popupSize: CGSize(width: 335, height: 32)
        )
        XCTAssertTrue(dockScreen.contains(placed))
        XCTAssertEqual(placed.midX, dockScreen.midX, accuracy: 0.5)
        XCTAssertEqual(placed.minY, dockScreen.midY + PopupPlacement.gap, accuracy: 0.5)
        XCTAssertGreaterThan(placed.minY, dockScreen.minY + 200)
    }
}
