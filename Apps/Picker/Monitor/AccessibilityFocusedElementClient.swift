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
    func readFrontmostDocumentPath() -> String?
}

extension FocusedSelectionReading {
    func readFrontmostDocumentPath() -> String? {
        nil
    }
}

protocol FocusedTextEditing {
    func captureFocusedTarget() -> AnyObject?
    func copySelectedAttributedText(from target: AnyObject?) -> NSAttributedString?
    func setSelectedText(_ text: String, in target: AnyObject?) -> Bool
    func insertAtFocusedPosition(_ text: String, in target: AnyObject?) -> Bool
}

private final class AccessibilityApplicationSupport: @unchecked Sendable {
    static let shared = AccessibilityApplicationSupport()

    private static let manualAccessibilityAttribute = "AXManualAccessibility"
    private static let enhancedUserInterfaceAttribute = "AXEnhancedUserInterface"
    private static let refreshInterval: CFAbsoluteTime = 5.0
    private static let browserBundlePrefixes = [
        "com.google.chrome",
        "org.chromium.",
        "com.brave.browser",
        "com.microsoft.edgemac",
        "company.thebrowser.",
        "com.operasoftware.",
        "com.vivaldi.",
        "com.citrolabs.ego",
        "org.mozilla.",
        "app.zen-browser.",
        "ai.perplexity.comet",
        "com.kagi.",
        "com.duckduckgo.",
        "com.sigmaos.",
        "org.waterfoxproject.",
        "io.gitlab.librewolf"
    ]

    private let lock = NSLock()
    private var preparedTimestamps: [pid_t: CFAbsoluteTime] = [:]
    private var browserBundleCache: [String: Bool] = [:]

    func prepareApplicationIfNeeded(pid: pid_t, bundleID: String?, bundleURL: URL?) {
        guard pid != 0, pid != ProcessInfo.processInfo.processIdentifier else { return }

        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        if let last = preparedTimestamps[pid], now - last < Self.refreshInterval {
            lock.unlock()
            return
        }
        preparedTimestamps[pid] = now
        if preparedTimestamps.count > 128 {
            preparedTimestamps = preparedTimestamps.filter { now - $0.value < 60.0 }
        }
        lock.unlock()

        let appElement = AXUIElementCreateApplication(pid)

        var manualSettable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(
            appElement,
            Self.manualAccessibilityAttribute as CFString,
            &manualSettable
        ) == .success, manualSettable.boolValue {
            if !readBoolAttribute(Self.manualAccessibilityAttribute, from: appElement) {
                _ = AXUIElementSetAttributeValue(
                    appElement,
                    Self.manualAccessibilityAttribute as CFString,
                    kCFBooleanTrue
                )
            }
            return
        }

        guard requiresEnhancedUserInterface(bundleID: bundleID, bundleURL: bundleURL) else {
            return
        }

        var enhancedSettable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(
            appElement,
            Self.enhancedUserInterfaceAttribute as CFString,
            &enhancedSettable
        ) == .success, enhancedSettable.boolValue {
            if !readBoolAttribute(Self.enhancedUserInterfaceAttribute, from: appElement) {
                _ = AXUIElementSetAttributeValue(
                    appElement,
                    Self.enhancedUserInterfaceAttribute as CFString,
                    kCFBooleanTrue
                )
            }
        }
    }

    private func readBoolAttribute(_ attribute: String, from element: AXUIElement) -> Bool {
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &valueRef) == .success else {
            return false
        }
        return (valueRef as? Bool) ?? false
    }

    private func requiresEnhancedUserInterface(bundleID: String?, bundleURL: URL?) -> Bool {
        let normalizedBundleID = (bundleID ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if Self.browserBundlePrefixes.contains(where: { normalizedBundleID.hasPrefix($0) }) {
            return true
        }

        let cacheKey = bundleURL?.path ?? normalizedBundleID
        guard !cacheKey.isEmpty else { return false }

        lock.lock()
        if let cached = browserBundleCache[cacheKey] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let detected = Self.detectChromiumOrGeckoBundle(at: bundleURL)
        lock.lock()
        browserBundleCache[cacheKey] = detected
        lock.unlock()
        return detected
    }

    private static func detectChromiumOrGeckoBundle(at bundleURL: URL?) -> Bool {
        guard let bundleURL else { return false }
        let fm = FileManager.default
        let contentsURL = bundleURL.appendingPathComponent("Contents", isDirectory: true)

        let geckoMarkers = [
            contentsURL.appendingPathComponent("MacOS/XUL").path,
            contentsURL.appendingPathComponent("MacOS/libmozglue.dylib").path
        ]
        if geckoMarkers.contains(where: { fm.fileExists(atPath: $0) }) {
            return true
        }

        let frameworksURL = contentsURL.appendingPathComponent("Frameworks", isDirectory: true)
        guard let entries = try? fm.contentsOfDirectory(
            at: frameworksURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }

        for entry in entries where entry.pathExtension == "framework" {
            let candidates = [
                entry.appendingPathComponent("Libraries/libEGL.dylib").path,
                entry.appendingPathComponent("Versions/Current/Libraries/libEGL.dylib").path,
                entry.appendingPathComponent("Helpers").path,
                entry.appendingPathComponent("Versions/Current/Helpers").path
            ]
            if candidates.contains(where: { fm.fileExists(atPath: $0) }) {
                return true
            }
        }
        return false
    }
}

struct AccessibilityFocusedElementClient: FocusedSelectionReading, FocusedTextEditing {
    private static let axBoundsAttribute = "AXBounds"
    private static let axFrameAttribute = "AXFrame"
    private static let axSelectedTextMarkerRangeAttribute = "AXSelectedTextMarkerRange"
    private static let axStringForTextMarkerRangeAttribute = "AXStringForTextMarkerRange"
    private static let axAttributedStringForTextMarkerRangeAttribute = "AXAttributedStringForTextMarkerRange"
    private static let axBoundsForTextMarkerRangeAttribute = "AXBoundsForTextMarkerRange"
    private static let containerRoles: Set<String> = [
        kAXWindowRole as String,
        kAXSplitGroupRole as String,
        kAXTabGroupRole as String,
        kAXScrollAreaRole as String,
        kAXGroupRole as String,
        kAXLayoutAreaRole as String,
        kAXBrowserRole as String,
        kAXSheetRole as String,
        "AXWebArea",
        "AXDocument"
    ]
    private static let documentSelectionRoles: Set<String> = [
        "AXWebArea",
        "AXDocument",
        kAXTextAreaRole as String
    ]

    func readFocusedSelection() -> FocusedSelectionPollOutcome {
        let frontmostApp = NSWorkspace.shared.frontmostApplication
        let fallbackBundleID = frontmostApp?.bundleIdentifier
        let fallbackPID = frontmostApp?.processIdentifier

        if let pid = fallbackPID, pid != 0 {
            AccessibilityApplicationSupport.shared.prepareApplicationIfNeeded(
                pid: pid,
                bundleID: fallbackBundleID,
                bundleURL: frontmostApp?.bundleURL
            )
        }

        guard let match = findSelectionElement(frontmostPID: fallbackPID) else {
            return .noSelection(bundleID: fallbackBundleID, processIdentifier: fallbackPID)
        }

        let elementPID = pid(of: match.element)
        let effectivePID = elementPID != 0 ? elementPID : (fallbackPID ?? 0)
        let bundleID = NSRunningApplication(processIdentifier: effectivePID)?.bundleIdentifier
            ?? fallbackBundleID
            ?? ""

        let bounds = readSelectionBounds(from: match.element)
        return .selection(
            FocusedElementSelection(
                text: match.text,
                bounds: bounds,
                bundleID: bundleID,
                processIdentifier: effectivePID
            )
        )
    }

    func readFrontmostDocumentPath() -> String? {
        guard let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              frontPID != 0 else {
            return nil
        }

        let appElement = AXUIElementCreateApplication(frontPID)

        if let focused = copyFocusedElement(frontmostPID: frontPID),
           let docFromFocused = readDocumentPathFromAncestors(startingAt: focused, expectedPID: frontPID) {
            return docFromFocused
        }

        for windowAttr in [kAXFocusedWindowAttribute as String, kAXMainWindowAttribute as String] {
            var windowRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(appElement, windowAttr as CFString, &windowRef) == .success,
                  let windowElement = asAXUIElement(windowRef) else {
                continue
            }
            if let path = extractLocalPathAttribute(from: windowElement) {
                return path
            }
            var proxyRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(windowElement, kAXProxyAttribute as CFString, &proxyRef) == .success,
               let proxyElement = asAXUIElement(proxyRef),
               let proxyPath = extractLocalPathAttribute(from: proxyElement) {
                return proxyPath
            }
        }

        return nil
    }

    func captureFocusedTarget() -> AnyObject? {
        let frontmostApp = NSWorkspace.shared.frontmostApplication
        let frontmostPID = frontmostApp?.processIdentifier
        if let pid = frontmostPID, pid != 0 {
            AccessibilityApplicationSupport.shared.prepareApplicationIfNeeded(
                pid: pid,
                bundleID: frontmostApp?.bundleIdentifier,
                bundleURL: frontmostApp?.bundleURL
            )
        }
        if let match = findSelectionElement(frontmostPID: frontmostPID) {
            return match.element
        }
        return copyFocusedElement(frontmostPID: frontmostPID)
    }

    func copySelectedAttributedText(from target: AnyObject?) -> NSAttributedString? {
        guard let element = resolveElement(from: target) else {
            return nil
        }

        if let rangeAX = copySelectedRangeAXValue(from: element) {
            var range = CFRange(location: 0, length: 0)
            if AXValueGetValue(rangeAX, .cfRange, &range), range.length > 0 {
                var attributedRef: CFTypeRef?
                if AXUIElementCopyParameterizedAttributeValue(
                    element,
                    kAXAttributedStringForRangeParameterizedAttribute as CFString,
                    rangeAX,
                    &attributedRef
                ) == .success, let attributed = attributedRef as? NSAttributedString, attributed.length > 0 {
                    return attributed
                }
            }
        }

        if let markerRange = copySelectedTextMarkerRange(from: element) {
            var markerAttrRef: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(
                element,
                Self.axAttributedStringForTextMarkerRangeAttribute as CFString,
                markerRange,
                &markerAttrRef
            ) == .success, let attributed = markerAttrRef as? NSAttributedString, attributed.length > 0 {
                return attributed
            }
        }

        return nil
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
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if let match = findSelectionElement(frontmostPID: frontmostPID) {
            return match.element
        }
        return copyFocusedElement(frontmostPID: frontmostPID)
    }

    private func findSelectionElement(frontmostPID: pid_t?) -> (element: AXUIElement, text: String)? {
        var visited: [AXUIElement] = []
        var focusedCandidates: [AXUIElement] = []

        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        ) == .success, let element = asAXUIElement(focusedRef) {
            let elemPID = pid(of: element)
            if frontmostPID == nil || frontmostPID == 0 || elemPID == 0 || elemPID == frontmostPID {
                focusedCandidates.append(element)
            }
        }

        if let frontPID = frontmostPID, frontPID != 0 {
            let appElement = AXUIElementCreateApplication(frontPID)
            var appFocusedRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                appElement,
                kAXFocusedUIElementAttribute as CFString,
                &appFocusedRef
            ) == .success, let appFocused = asAXUIElement(appFocusedRef),
               !focusedCandidates.contains(where: { CFEqual($0, appFocused) }) {
                focusedCandidates.append(appFocused)
            }
        }

        for candidate in focusedCandidates {
            if let match = checkElementAndAncestors(
                candidate,
                expectedPID: frontmostPID,
                visited: &visited
            ) {
                return match
            }
        }

        if let frontPID = frontmostPID, frontPID != 0, (NSEvent.pressedMouseButtons & 1) == 0 {
            let quartzMouse = convertAppKitPointToQuartz(NSEvent.mouseLocation)
            var hitRef: AXUIElement?
            if AXUIElementCopyElementAtPosition(
                systemWide,
                Float(quartzMouse.x),
                Float(quartzMouse.y),
                &hitRef
            ) == .success, let hitElement = hitRef, pid(of: hitElement) == frontPID {
                if let match = checkElementAndAncestors(
                    hitElement,
                    expectedPID: frontPID,
                    visited: &visited
                ) {
                    return match
                }
            }
        }

        if let frontPID = frontmostPID, frontPID != 0, shouldSearchFocusedWindow(focusedCandidates: focusedCandidates) {
            let appElement = AXUIElementCreateApplication(frontPID)
            if let windowMatch = searchWindowSelection(in: appElement, visited: &visited) {
                return windowMatch
            }
        }

        return nil
    }

    private func shouldSearchFocusedWindow(focusedCandidates: [AXUIElement]) -> Bool {
        guard let first = focusedCandidates.first else { return true }
        guard let role = copyRole(of: first) else { return true }
        if role == (kAXTextAreaRole as String) || role == "AXWebArea" {
            return false
        }
        return true
    }

    private func checkElementAndAncestors(
        _ startElement: AXUIElement,
        expectedPID: pid_t?,
        visited: inout [AXUIElement]
    ) -> (element: AXUIElement, text: String)? {
        var current: AXUIElement? = startElement
        var steps = 0

        while let element = current, steps < 10 {
            steps += 1

            if let expectedPID, expectedPID != 0 {
                let currentPID = pid(of: element)
                if currentPID != 0 && currentPID != expectedPID {
                    break
                }
            }

            if visited.contains(where: { CFEqual($0, element) }) {
                break
            }
            visited.append(element)

            let role = copyRole(of: element)
            if role == (kAXApplicationRole as String) {
                break
            }

            if role != "AXSecureTextField",
               let text = readSelectedText(from: element),
               !text.isEmpty {
                return (element, text)
            }

            if role == (kAXWindowRole as String) {
                break
            }

            var parentRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                element,
                kAXParentAttribute as CFString,
                &parentRef
            ) == .success, let parent = asAXUIElement(parentRef) else {
                break
            }
            current = parent
        }

        return nil
    }

    private func searchWindowSelection(
        in appElement: AXUIElement,
        visited: inout [AXUIElement]
    ) -> (element: AXUIElement, text: String)? {
        var windowElement: AXUIElement?
        for attr in [kAXFocusedWindowAttribute as String, kAXMainWindowAttribute as String] {
            var windowRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(appElement, attr as CFString, &windowRef) == .success,
               let resolved = asAXUIElement(windowRef) {
                windowElement = resolved
                break
            }
        }
        guard let rootWindow = windowElement else { return nil }

        var queue: [(element: AXUIElement, depth: Int)] = [(rootWindow, 0)]
        var index = 0
        var inspectedContainers = 0

        while index < queue.count && inspectedContainers < 45 {
            let (node, depth) = queue[index]
            index += 1
            inspectedContainers += 1

            let role = copyRole(of: node) ?? ""
            if Self.documentSelectionRoles.contains(role),
               !visited.contains(where: { CFEqual($0, node) }) {
                visited.append(node)
                if let text = readSelectedText(from: node), !text.isEmpty {
                    return (node, text)
                }
            }

            guard depth < 7, Self.containerRoles.contains(role) else { continue }

            var childrenRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                node,
                kAXChildrenAttribute as CFString,
                &childrenRef
            ) == .success, let children = childrenRef as? [AXUIElement] else {
                continue
            }

            for child in children.prefix(20) {
                queue.append((child, depth + 1))
            }
        }

        return nil
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
                ) == .success {
                    if let text = parameterizedTextRef as? String, !text.isEmpty {
                        return text
                    }
                    if let attributed = parameterizedTextRef as? NSAttributedString, !attributed.string.isEmpty {
                        return attributed.string
                    }
                }

                var attrRangeRef: CFTypeRef?
                if AXUIElementCopyParameterizedAttributeValue(
                    element,
                    kAXAttributedStringForRangeParameterizedAttribute as CFString,
                    rangeValue,
                    &attrRangeRef
                ) == .success, let attributed = attrRangeRef as? NSAttributedString, !attributed.string.isEmpty {
                    return attributed.string
                }
            }
        }

        var rangesRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangesAttribute as CFString,
            &rangesRef
        ) == .success, let rangeValues = rangesRef as? [AXValue], !rangeValues.isEmpty {
            var pieces: [String] = []
            for rangeVal in rangeValues where AXValueGetType(rangeVal) == .cfRange {
                var range = CFRange(location: 0, length: 0)
                guard AXValueGetValue(rangeVal, .cfRange, &range), range.length > 0 else { continue }
                var pieceRef: CFTypeRef?
                if AXUIElementCopyParameterizedAttributeValue(
                    element,
                    kAXStringForRangeParameterizedAttribute as CFString,
                    rangeVal,
                    &pieceRef
                ) == .success, let piece = pieceRef as? String, !piece.isEmpty {
                    pieces.append(piece)
                }
            }
            if !pieces.isEmpty {
                return pieces.joined(separator: "\n")
            }
        }

        if let markerRange = copySelectedTextMarkerRange(from: element) {
            var markerTextRef: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(
                element,
                Self.axStringForTextMarkerRangeAttribute as CFString,
                markerRange,
                &markerTextRef
            ) == .success {
                if let text = markerTextRef as? String, !text.isEmpty {
                    return text
                }
                if let attributed = markerTextRef as? NSAttributedString, !attributed.string.isEmpty {
                    return attributed.string
                }
            }

            var markerAttrRef: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(
                element,
                Self.axAttributedStringForTextMarkerRangeAttribute as CFString,
                markerRange,
                &markerAttrRef
            ) == .success {
                if let attributed = markerAttrRef as? NSAttributedString, !attributed.string.isEmpty {
                    return attributed.string
                }
                if let text = markerAttrRef as? String, !text.isEmpty {
                    return text
                }
            }
        }
        return nil
    }

    private func readSelectionBounds(from element: AXUIElement) -> CGRect {
        if let rangeValue = copySelectedRangeAXValue(from: element) {
            var range = CFRange(location: 0, length: 0)
            if AXValueGetValue(rangeValue, .cfRange, &range), range.length > 0 {
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
                return anchorWithinElementRect(convertQuartzToAppKitScreen(quartzRect))
            }
        }

        if let elementRect = readPositionAndSize(from: element) {
            return anchorWithinElementRect(convertQuartzToAppKitScreen(elementRect))
        }

        let mouse = NSEvent.mouseLocation
        return CGRect(x: mouse.x, y: mouse.y - 10, width: 1, height: 20)
    }

    private func anchorWithinElementRect(_ appKitRect: CGRect) -> CGRect {
        guard appKitRect.height > 80 else {
            return appKitRect
        }
        let mouse = NSEvent.mouseLocation
        if appKitRect.insetBy(dx: -20, dy: -20).contains(mouse) {
            return CGRect(x: mouse.x, y: mouse.y - 10, width: 1, height: 20)
        }
        return CGRect(x: appKitRect.midX, y: appKitRect.midY - 10, width: 1, height: 20)
    }

    private func pid(of element: AXUIElement) -> pid_t {
        var elementPID: pid_t = 0
        AXUIElementGetPid(element, &elementPID)
        return elementPID
    }

    private func copyRole(of element: AXUIElement) -> String? {
        var roleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success else {
            return nil
        }
        return roleRef as? String
    }

    private func convertAppKitPointToQuartz(_ appKitPoint: NSPoint) -> CGPoint {
        guard let primaryHeight = NSScreen.screens.first?.frame.height, primaryHeight > 0 else {
            return appKitPoint
        }
        return CGPoint(x: appKitPoint.x, y: primaryHeight - appKitPoint.y)
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

    private func readDocumentPathFromAncestors(
        startingAt element: AXUIElement,
        expectedPID: pid_t
    ) -> String? {
        var current: AXUIElement? = element
        var steps = 0
        while let node = current, steps < 12 {
            steps += 1
            let nodePID = pid(of: node)
            if nodePID != 0 && nodePID != expectedPID {
                break
            }
            if let path = extractLocalPathAttribute(from: node) {
                return path
            }
            if copyRole(of: node) == (kAXApplicationRole as String) {
                break
            }
            var parentRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(node, kAXParentAttribute as CFString, &parentRef) == .success,
                  let parent = asAXUIElement(parentRef) else {
                break
            }
            current = parent
        }
        return nil
    }

    private func extractLocalPathAttribute(from element: AXUIElement) -> String? {
        for attr in [kAXDocumentAttribute as String, kAXURLAttribute as String, kAXFilenameAttribute as String] {
            var valueRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attr as CFString, &valueRef) == .success,
                  let valueRef else {
                continue
            }
            if let stringVal = valueRef as? String {
                let trimmed = stringVal.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.lowercased().hasPrefix("file://"),
                   let url = URL(string: trimmed),
                   url.isFileURL {
                    return url.path
                }
                if trimmed.hasPrefix("/") && !trimmed.hasPrefix("//") {
                    return trimmed
                }
            } else if CFGetTypeID(valueRef) == CFURLGetTypeID() {
                let url = unsafeBitCast(valueRef, to: CFURL.self) as URL
                if url.isFileURL {
                    return url.path
                }
            }
        }
        return nil
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
