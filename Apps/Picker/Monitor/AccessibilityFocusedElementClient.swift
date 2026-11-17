import AppKit
import ApplicationServices
import Foundation

struct FocusedElementSelection: Equatable, Sendable {
    let text: String
    let bounds: CGRect
    let bundleID: String
    let processIdentifier: pid_t
}

enum FocusedSelectionPollOutcome: Equatable, Sendable {
    case noSelection(bundleID: String?, processIdentifier: pid_t?)
    case selection(FocusedElementSelection)
}

protocol FocusedSelectionReading {
    func readFocusedSelection() -> FocusedSelectionPollOutcome
}

protocol FocusedTextEditing {
    func captureFocusedTarget() -> AnyObject?
    func copySelectedAttributedText(from target: AnyObject?) -> NSAttributedString?
    func setSelectedText(_ text: String, in target: AnyObject?) -> Bool
    func insertAtFocusedPosition(_ text: String, in target: AnyObject?) -> Bool
}

struct AccessibilityFocusedElementClient: FocusedSelectionReading, FocusedTextEditing {
    private static let axBoundsAttribute = "AXBounds"
    private static let axFrameAttribute = "AXFrame"
    private static let axSelectedTextMarkerRangeAttribute = "AXSelectedTextMarkerRange"
    private static let axStringForTextMarkerRangeAttribute = "AXStringForTextMarkerRange"
    private static let axBoundsForTextMarkerRangeAttribute = "AXBoundsForTextMarkerRange"

    func readFocusedSelection() -> FocusedSelectionPollOutcome {
        let frontmostApp = NSWorkspace.shared.frontmostApplication
        let fallbackBundleID = frontmostApp?.bundleIdentifier
        let fallbackPID = frontmostApp?.processIdentifier

        guard let focusedElement = copyFocusedElement(frontmostPID: fallbackPID) else {
            return .noSelection(bundleID: fallbackBundleID, processIdentifier: fallbackPID)
        }

        var elementPID: pid_t = 0
        AXUIElementGetPid(focusedElement, &elementPID)
        let effectivePID = elementPID != 0 ? elementPID : (fallbackPID ?? 0)
        let bundleID = NSRunningApplication(processIdentifier: effectivePID)?.bundleIdentifier
            ?? fallbackBundleID
            ?? ""

        guard let selectedText = readSelectedText(from: focusedElement), !selectedText.isEmpty else {
            return .noSelection(bundleID: bundleID, processIdentifier: effectivePID)
        }

        let bounds = readSelectionBounds(from: focusedElement)
        return .selection(
            FocusedElementSelection(
                text: selectedText,
                bounds: bounds,
                bundleID: bundleID,
                processIdentifier: effectivePID
            )
        )
    }

    func captureFocusedTarget() -> AnyObject? {
        copyFocusedElement(frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier)
    }

    func copySelectedAttributedText(from target: AnyObject?) -> NSAttributedString? {
        guard let element = resolveElement(from: target),
              let rangeAX = copySelectedRangeAXValue(from: element) else {
            return nil
        }

        var attributedRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXAttributedStringForRangeParameterizedAttribute as CFString,
            rangeAX,
            &attributedRef
        ) == .success else {
            return nil
        }
        return attributedRef as? NSAttributedString
    }

    func setSelectedText(_ text: String, in target: AnyObject?) -> Bool {
        guard let element = resolveElement(from: target) else {
            return false
        }

        var isSettable = DarwinBoolean(false)
        let settableStatus = AXUIElementIsAttributeSettable(
            element,
            kAXSelectedTextAttribute as CFString,
            &isSettable
        )
        if settableStatus == .success && !isSettable.boolValue {
            return false
        }

        return AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        ) == .success
    }

    func insertAtFocusedPosition(_ text: String, in target: AnyObject?) -> Bool {
        guard let element = resolveElement(from: target) else {
            return false
        }

        var valueSettable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(
            element,
            kAXValueAttribute as CFString,
            &valueSettable
        ) == .success, valueSettable.boolValue else {
            return false
        }

        var currentValueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXValueAttribute as CFString,
            &currentValueRef
        ) == .success, let currentValue = currentValueRef as? String,
              let rangeAX = copySelectedRangeAXValue(from: element) else {
            return false
        }

        var cfRange = CFRange(location: 0, length: 0)
        guard AXValueGetValue(rangeAX, .cfRange, &cfRange),
              cfRange.location >= 0,
              cfRange.length >= 0 else {
            return false
        }

        let nsCurrent = currentValue as NSString
        guard cfRange.location + cfRange.length <= nsCurrent.length else {
            return false
        }

        let replaceRange = NSRange(location: cfRange.location, length: cfRange.length)
        let updatedValue = nsCurrent.replacingCharacters(in: replaceRange, with: text)
        guard AXUIElementSetAttributeValue(
            element,
            kAXValueAttribute as CFString,
            updatedValue as CFTypeRef
        ) == .success else {
            return false
        }

        var newCaret = CFRange(location: cfRange.location + (text as NSString).length, length: 0)
        if let caretAX = AXValueCreate(.cfRange, &newCaret) {
            _ = AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, caretAX)
        }
        return true
    }

    private func resolveElement(from target: AnyObject?) -> AXUIElement? {
        if let target, CFGetTypeID(target) == AXUIElementGetTypeID() {
            return unsafeBitCast(target, to: AXUIElement.self)
        }
        return copyFocusedElement(frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier)
    }

    private func copyFocusedElement(frontmostPID: pid_t?) -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        ) == .success, let element = asAXUIElement(focusedRef) {
            return element
        }

        guard let pid = frontmostPID, pid != 0 else { return nil }
        let appElement = AXUIElementCreateApplication(pid)
        var appFocusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &appFocusedRef
        ) == .success else {
            return nil
        }
        return asAXUIElement(appFocusedRef)
    }

    private func readSelectedText(from element: AXUIElement) -> String? {
        var textRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &textRef) == .success {
            if let text = textRef as? String, !text.isEmpty { return text }
            if let attributed = textRef as? NSAttributedString, !attributed.string.isEmpty {
                return attributed.string
            }
        }

        if let rangeValue = copySelectedRangeAXValue(from: element) {
            var range = CFRange(location: 0, length: 0)
            if AXValueGetValue(rangeValue, .cfRange, &range), range.length > 0 {
                var parameterizedTextRef: CFTypeRef?
                if AXUIElementCopyParameterizedAttributeValue(
                    element,
                    kAXStringForRangeParameterizedAttribute as CFString,
                    rangeValue,
                    &parameterizedTextRef
                ) == .success, let text = parameterizedTextRef as? String, !text.isEmpty {
                    return text
                }
            }
        }

        if let markerRange = copySelectedTextMarkerRange(from: element) {
            var markerTextRef: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(
                element,
                Self.axStringForTextMarkerRangeAttribute as CFString,
                markerRange,
                &markerTextRef
            ) == .success, let text = markerTextRef as? String {
                return text
            }
        }
        return nil
    }

    private func readSelectionBounds(from element: AXUIElement) -> CGRect {
        if let rangeValue = copySelectedRangeAXValue(from: element) {
            var boundsRef: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(
                element,
                kAXBoundsForRangeParameterizedAttribute as CFString,
                rangeValue,
                &boundsRef
            ) == .success, let quartzRect = extractNonEmptyRect(from: boundsRef) {
                return convertQuartzToAppKitScreen(quartzRect)
            }
        }

        if let markerRange = copySelectedTextMarkerRange(from: element) {
            var markerBoundsRef: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(
                element,
                Self.axBoundsForTextMarkerRangeAttribute as CFString,
                markerRange,
                &markerBoundsRef
            ) == .success, let quartzRect = extractNonEmptyRect(from: markerBoundsRef) {
                return convertQuartzToAppKitScreen(quartzRect)
            }
        }

        for attribute in [Self.axBoundsAttribute, Self.axFrameAttribute] {
            var rectRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, attribute as CFString, &rectRef) == .success,
               let quartzRect = extractNonEmptyRect(from: rectRef) {
                return convertQuartzToAppKitScreen(quartzRect)
            }
        }

        if let elementRect = readPositionAndSize(from: element) {
            return convertQuartzToAppKitScreen(elementRect)
        }
        return CGRect(origin: NSEvent.mouseLocation, size: .zero)
    }

    private func copySelectedTextMarkerRange(from element: AXUIElement) -> CFTypeRef? {
        var markerRangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            Self.axSelectedTextMarkerRangeAttribute as CFString,
            &markerRangeRef
        ) == .success else {
            return nil
        }
        return markerRangeRef
    }

    private func copySelectedRangeAXValue(from element: AXUIElement) -> AXValue? {
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeRef
        ) == .success, let axValue = asAXValue(rangeRef), AXValueGetType(axValue) == .cfRange else {
            return nil
        }
        return axValue
    }

    private func readPositionAndSize(from element: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionAX = asAXValue(positionRef),
              let sizeAX = asAXValue(sizeRef) else {
            return nil
        }

        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionAX, .cgPoint, &origin),
              AXValueGetValue(sizeAX, .cgSize, &size),
              size.width > 0 || size.height > 0 else {
            return nil
        }
        return CGRect(origin: origin, size: size)
    }

    private func extractNonEmptyRect(from ref: CFTypeRef?) -> CGRect? {
        guard let axValue = asAXValue(ref), AXValueGetType(axValue) == .cgRect else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(axValue, .cgRect, &rect),
              !rect.isNull,
              !rect.isInfinite,
              rect.width > 0 || rect.height > 0 else {
            return nil
        }
        return rect.standardized
    }

    private func convertQuartzToAppKitScreen(_ quartzRect: CGRect) -> CGRect {
        let standardized = quartzRect.standardized
        guard let primaryHeight = NSScreen.screens.first?.frame.height, primaryHeight > 0 else {
            return standardized
        }
        return CGRect(
            x: standardized.origin.x,
            y: primaryHeight - standardized.maxY,
            width: standardized.width,
            height: standardized.height
        )
    }

    private func asAXUIElement(_ ref: CFTypeRef?) -> AXUIElement? {
        guard let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(ref, to: AXUIElement.self)
    }

    private func asAXValue(_ ref: CFTypeRef?) -> AXValue? {
        guard let ref, CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        return unsafeBitCast(ref, to: AXValue.self)
    }
}
