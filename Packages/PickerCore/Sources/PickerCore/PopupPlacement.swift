import CoreGraphics

/// Computes popup window frames in AppKit screen coordinates (origin at bottom-left, `+y` upward,
/// matching `NSScreen.visibleFrame` and `NSWindow`).
public enum PopupPlacement {
    public static let gap: CGFloat = 6

    /// Places a popup of `popupSize` relative to `selectionBounds` inside `screenVisible`.
    ///
    /// When `preferAbove` is `true`, the popup is positioned 6 points above `selectionBounds.maxY`,
    /// flipping 6 points below `selectionBounds.minY` if placing it above would leave `screenVisible`.
    /// When `preferAbove` is `false`, the popup prefers below and flips above if needed.
    /// Finally, the frame is clamped inside `screenVisible`.
    public static func place(
        selectionBounds: CGRect,
        screenVisible: CGRect,
        preferAbove: Bool = true,
        popupSize: CGSize
    ) -> CGRect {
        let visible = screenVisible.isNull || screenVisible.isInfinite
            ? .zero
            : screenVisible.standardized
        let selection: CGRect
        if selectionBounds.isNull || selectionBounds.isInfinite {
            selection = CGRect(x: visible.midX, y: visible.midY, width: 0, height: 0)
        } else {
            selection = selectionBounds.standardized
        }

        let width = visible.width > 0 ? min(max(0, popupSize.width), visible.width) : max(0, popupSize.width)
        let height = visible.height > 0 ? min(max(0, popupSize.height), visible.height) : max(0, popupSize.height)

        let idealX = selection.midX - (width / 2)
        let aboveY = selection.maxY + gap
        let belowY = selection.minY - gap - height

        let preferredY = preferAbove ? aboveY : belowY
        let alternateY = preferAbove ? belowY : aboveY

        let preferredFits = preferredY >= visible.minY && (preferredY + height) <= visible.maxY
        let alternateFits = alternateY >= visible.minY && (alternateY + height) <= visible.maxY

        let unclampedY: CGFloat
        if preferredFits {
            unclampedY = preferredY
        } else if alternateFits {
            unclampedY = alternateY
        } else {
            let roomAbove = visible.maxY - selection.maxY
            let roomBelow = selection.minY - visible.minY
            if preferAbove {
                unclampedY = roomBelow > roomAbove ? belowY : aboveY
            } else {
                unclampedY = roomAbove > roomBelow ? aboveY : belowY
            }
        }

        let maxX = max(visible.minX, visible.maxX - width)
        let maxY = max(visible.minY, visible.maxY - height)

        let clampedX = min(max(idealX, visible.minX), maxX)
        let clampedY = min(max(unclampedY, visible.minY), maxY)

        return CGRect(x: clampedX, y: clampedY, width: width, height: height)
    }

    /// Converts a top-left Quartz/Accessibility screen rect into AppKit bottom-left screen coordinates.
    public static func convertFromQuartzScreen(
        _ quartzRect: CGRect,
        primaryScreenHeight: CGFloat
    ) -> CGRect {
        let rect = quartzRect.standardized
        return CGRect(
            x: rect.origin.x,
            y: primaryScreenHeight - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }
}
