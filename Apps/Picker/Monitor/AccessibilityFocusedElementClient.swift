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
    func prepareFrontmostApplication()
    func readFocusedSelection() -> FocusedSelectionPollOutcome
    func readFrontmostDocumentPath() -> String?
}

extension FocusedSelectionReading {
    func prepareFrontmostApplication() {}

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

struct AccessibilityFrontmostApplication: Equatable, Sendable {
    let processIdentifier: pid_t
    let bundleIdentifier: String?
    let bundleURL: URL?
}

protocol AccessibilityQuerying {
    var ownProcessIdentifier: pid_t { get }
    func frontmostApplication() -> AccessibilityFrontmostApplication?
    func bundleIdentifier(for pid: pid_t) -> String?
    func belongsToApplication(elementPID: pid_t, appPID: pid_t, appBundleURL: URL?) -> Bool
    func isValidElement(_ target: AnyObject) -> Bool
    func createApplicationElement(pid: pid_t) -> AnyObject
    func createSystemWideElement() -> AnyObject
    func pid(of element: AnyObject) -> pid_t
    func areElementsEqual(_ lhs: AnyObject, _ rhs: AnyObject) -> Bool
    func isAttributeSettable(_ attribute: String, on element: AnyObject) -> Bool
    func setAttributeValue(_ value: CFTypeRef, forAttribute attribute: String, on element: AnyObject) -> AXError
    func copyAttributeValue(_ attribute: String, from element: AnyObject) -> (AXError, AnyObject?)
    func copyParameterizedAttributeValue(
        _ attribute: String,
        parameter: CFTypeRef,
        from element: AnyObject
    ) -> (AXError, AnyObject?)
    func copyElementAtPosition(x: Float, y: Float) -> AnyObject?
    func isLeftMouseButtonPressed() -> Bool
    func mouseLocation() -> NSPoint
    func primaryScreenHeight() -> CGFloat?
}

struct SystemAccessibilityQueryClient: AccessibilityQuerying {
    var ownProcessIdentifier: pid_t {
        ProcessInfo.processInfo.processIdentifier
    }

    func frontmostApplication() -> AccessibilityFrontmostApplication? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return AccessibilityFrontmostApplication(
            processIdentifier: app.processIdentifier,
            bundleIdentifier: app.bundleIdentifier,
            bundleURL: app.bundleURL
        )
    }

    func bundleIdentifier(for pid: pid_t) -> String? {
        NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }

    func belongsToApplication(elementPID: pid_t, appPID: pid_t, appBundleURL: URL?) -> Bool {
        if appPID == 0 || elementPID == 0 || elementPID == appPID {
            return true
        }
        guard let rootPath = appBundleURL?.standardizedFileURL.path, !rootPath.isEmpty,
              let elementApp = NSRunningApplication(processIdentifier: elementPID) else {
            return false
        }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        if let childBundlePath = elementApp.bundleURL?.standardizedFileURL.path,
           childBundlePath == rootPath || childBundlePath.hasPrefix(prefix) {
            return true
        }
        if let execPath = elementApp.executableURL?.standardizedFileURL.path,
           execPath.hasPrefix(prefix) {
            return true
        }
        return false
    }

    func isValidElement(_ target: AnyObject) -> Bool {
        CFGetTypeID(target) == AXUIElementGetTypeID()
    }

    func createApplicationElement(pid: pid_t) -> AnyObject {
        AXUIElementCreateApplication(pid)
    }

    func createSystemWideElement() -> AnyObject {
        AXUIElementCreateSystemWide()
    }

    func pid(of element: AnyObject) -> pid_t {
        guard let axElement = asAXUIElement(element) else { return 0 }
        var elementPID: pid_t = 0
        AXUIElementGetPid(axElement, &elementPID)
        return elementPID
    }

    func areElementsEqual(_ lhs: AnyObject, _ rhs: AnyObject) -> Bool {
        CFEqual(lhs, rhs)
    }

    func isAttributeSettable(_ attribute: String, on element: AnyObject) -> Bool {
        guard let axElement = asAXUIElement(element) else { return false }
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(axElement, attribute as CFString, &settable) == .success else {
            return false
        }
        return settable.boolValue
    }

    func setAttributeValue(_ value: CFTypeRef, forAttribute attribute: String, on element: AnyObject) -> AXError {
        guard let axElement = asAXUIElement(element) else { return .illegalArgument }
        return AXUIElementSetAttributeValue(axElement, attribute as CFString, value)
    }

    func copyAttributeValue(_ attribute: String, from element: AnyObject) -> (AXError, AnyObject?) {
        guard let axElement = asAXUIElement(element) else { return (.illegalArgument, nil) }
        var valueRef: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(axElement, attribute as CFString, &valueRef)
        return (status, valueRef)
    }

    func copyParameterizedAttributeValue(
        _ attribute: String,
        parameter: CFTypeRef,
        from element: AnyObject
    ) -> (AXError, AnyObject?) {
        guard let axElement = asAXUIElement(element) else { return (.illegalArgument, nil) }
        var valueRef: CFTypeRef?
        let status = AXUIElementCopyParameterizedAttributeValue(
            axElement,
            attribute as CFString,
            parameter,
            &valueRef
        )
        return (status, valueRef)
    }

    func copyElementAtPosition(x: Float, y: Float) -> AnyObject? {
        let systemWide = AXUIElementCreateSystemWide()
        var hitRef: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, x, y, &hitRef) == .success else {
            return nil
        }
        return hitRef
    }

    func isLeftMouseButtonPressed() -> Bool {
        (NSEvent.pressedMouseButtons & 1) != 0
    }

    func mouseLocation() -> NSPoint {
        NSEvent.mouseLocation
    }

    func primaryScreenHeight() -> CGFloat? {
        NSScreen.screens.first?.frame.height
    }

    private func asAXUIElement(_ ref: AnyObject?) -> AXUIElement? {
        guard let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(ref, to: AXUIElement.self)
    }
}

final class AccessibilityApplicationSupport: @unchecked Sendable {
    static let shared = AccessibilityApplicationSupport()

    static let manualAccessibilityAttribute = "AXManualAccessibility"
    static let enhancedUserInterfaceAttribute = "AXEnhancedUserInterface"
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

    private let refreshWindow: CFAbsoluteTime
    private let lock = NSLock()
    private var preparedTimestamps: [pid_t: CFAbsoluteTime] = [:]
    private var browserBundleCache: [String: Bool] = [:]

    init(refreshInterval: CFAbsoluteTime = AccessibilityApplicationSupport.refreshInterval) {
        self.refreshWindow = refreshInterval
    }

    @discardableResult
    func prepareApplicationIfNeeded(
        pid: pid_t,
        bundleID: String?,
        bundleURL: URL?,
        using queryClient: AccessibilityQuerying = SystemAccessibilityQueryClient()
    ) -> Bool {
        guard pid != 0, pid != queryClient.ownProcessIdentifier else { return false }

        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        if let last = preparedTimestamps[pid], now - last < refreshWindow {
            lock.unlock()
            return false
        }
        preparedTimestamps[pid] = now
        if preparedTimestamps.count > 128 {
            preparedTimestamps = preparedTimestamps.filter { now - $0.value < 60.0 }
        }
        lock.unlock()

        let appElement = queryClient.createApplicationElement(pid: pid)
        var didWriteAttribute = false

        if queryClient.isAttributeSettable(Self.manualAccessibilityAttribute, on: appElement) {
            if !readBoolAttribute(Self.manualAccessibilityAttribute, from: appElement, using: queryClient) {
                if queryClient.setAttributeValue(
                    kCFBooleanTrue,
                    forAttribute: Self.manualAccessibilityAttribute,
                    on: appElement
                ) == .success {
                    didWriteAttribute = true
                }
            }
        }

        // Electron's AtomApplication exposes settable AXManualAccessibility (whose getter
        // can still read back false because it compares mode == kAXModeBasic rather than
        // kAXModeComplete) and skips forwarding AXEnhancedUserInterface to BrowserCrApplication
        // unless AXEnhancedUserInterface is also set explicitly. Do not return early above.
        if requiresEnhancedUserInterface(bundleID: bundleID, bundleURL: bundleURL),
           queryClient.isAttributeSettable(Self.enhancedUserInterfaceAttribute, on: appElement),
           !readBoolAttribute(Self.enhancedUserInterfaceAttribute, from: appElement, using: queryClient) {
            if queryClient.setAttributeValue(
                kCFBooleanTrue,
                forAttribute: Self.enhancedUserInterfaceAttribute,
                on: appElement
            ) == .success {
                didWriteAttribute = true
            }
        }

        return didWriteAttribute
    }

    private func readBoolAttribute(
        _ attribute: String,
        from element: AnyObject,
        using queryClient: AccessibilityQuerying
    ) -> Bool {
        let (status, valueRef) = queryClient.copyAttributeValue(attribute, from: element)
        guard status == .success else { return false }
        return (valueRef as? Bool) ?? false
    }

    func requiresEnhancedUserInterface(bundleID: String?, bundleURL: URL?) -> Bool {
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

    static func detectChromiumOrGeckoBundle(at bundleURL: URL?) -> Bool {
        guard let bundleURL else { return false }
        let fm = FileManager.default
        let contentsURL = bundleURL.appendingPathComponent("Contents", isDirectory: true)

        let directMarkers = [
            contentsURL.appendingPathComponent("MacOS/XUL").path,
            contentsURL.appendingPathComponent("MacOS/libmozglue.dylib").path,
            contentsURL.appendingPathComponent("Resources/app.asar").path,
            contentsURL.appendingPathComponent("Resources/app.asar.unpacked").path,
            contentsURL.appendingPathComponent("Frameworks/Electron Framework.framework").path,
            contentsURL.appendingPathComponent("Frameworks/libEGL.dylib").path
        ]
        if directMarkers.contains(where: { fm.fileExists(atPath: $0) }) {
            return true
        }

        let frameworksURL = contentsURL.appendingPathComponent("Frameworks", isDirectory: true)
        if containsChromiumFramework(in: frameworksURL, fileManager: fm) {
            return true
        }

        let macOSURL = contentsURL.appendingPathComponent("MacOS", isDirectory: true)
        if let helperEntries = try? fm.contentsOfDirectory(
            at: macOSURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            for helper in helperEntries where helper.pathExtension == "app" {
                let helperFrameworks = helper
                    .appendingPathComponent("Contents", isDirectory: true)
                    .appendingPathComponent("Frameworks", isDirectory: true)
                if containsChromiumFramework(in: helperFrameworks, fileManager: fm) {
                    return true
                }
            }
        }

        return false
    }

    private static func containsChromiumFramework(in frameworksURL: URL, fileManager fm: FileManager) -> Bool {
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

    // Deep Electron/React trees (such as Orca) commonly nest focused leaf controls 16-25+
    // levels inside AXWebArea and place AXWebArea 7-10+ native Views levels below AXWindow.
    private static let maxAncestorSteps = 48
    private static let maxWindowSearchDepth = 16
    private static let maxInspectedContainers = 240
    private static let maxChildrenPerContainer = 60
    private static let maxSearchedWindows = 4

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
    private static let markerDocumentRoles: Set<String> = [
        "AXWebArea",
        "AXDocument"
    ]
    private static let textInputRoles: Set<String> = [
        kAXTextFieldRole as String,
        kAXTextAreaRole as String,
        kAXComboBoxRole as String,
        "AXSearchField"
    ]
    private static let nonLeafMarkerElementRoles: Set<String> = [
        kAXApplicationRole as String,
        kAXWindowRole as String,
        kAXScrollAreaRole as String,
        "AXWebArea",
        "AXDocument"
    ]
    private static let axUIElementForTextMarkerAttribute = "AXUIElementForTextMarker"
    private static let axStartTextMarkerForTextMarkerRangeAttribute = "AXStartTextMarkerForTextMarkerRange"
    private static let axEndTextMarkerForTextMarkerRangeAttribute = "AXEndTextMarkerForTextMarkerRange"

    private struct SelectionMatch {
        let element: AnyObject
        let text: String
        let markerRange: CFTypeRef?
        let allowsElementBoundsFallback: Bool
    }

    private let queryClient: AccessibilityQuerying
    private let applicationSupport: AccessibilityApplicationSupport

    init(
        queryClient: AccessibilityQuerying = SystemAccessibilityQueryClient(),
        applicationSupport: AccessibilityApplicationSupport = .shared
    ) {
        self.queryClient = queryClient
        self.applicationSupport = applicationSupport
    }

    func prepareFrontmostApplication() {
        guard let frontmostApp = queryClient.frontmostApplication(),
              frontmostApp.processIdentifier != 0 else {
            return
        }
        _ = applicationSupport.prepareApplicationIfNeeded(
            pid: frontmostApp.processIdentifier,
            bundleID: frontmostApp.bundleIdentifier,
            bundleURL: frontmostApp.bundleURL,
            using: queryClient
        )
    }

    func readFocusedSelection() -> FocusedSelectionPollOutcome {
        let frontmostApp = queryClient.frontmostApplication()
        let fallbackBundleID = frontmostApp?.bundleIdentifier
        let fallbackPID = frontmostApp?.processIdentifier
        let fallbackBundleURL = frontmostApp?.bundleURL

        if let pid = fallbackPID, pid != 0 {
            _ = applicationSupport.prepareApplicationIfNeeded(
                pid: pid,
                bundleID: fallbackBundleID,
                bundleURL: fallbackBundleURL,
                using: queryClient
            )
        }

        guard let match = findSelectionElement(
            frontmostPID: fallbackPID,
            frontmostBundleURL: fallbackBundleURL
        ) else {
            return .noSelection(bundleID: fallbackBundleID, processIdentifier: fallbackPID)
        }

        let elementPID = queryClient.pid(of: match.element)
        let effectivePID: pid_t
        if let fallbackPID, fallbackPID != 0,
           elementPID != fallbackPID,
           queryClient.belongsToApplication(
               elementPID: elementPID,
               appPID: fallbackPID,
               appBundleURL: fallbackBundleURL
           ) {
            effectivePID = fallbackPID
        } else {
            effectivePID = elementPID != 0 ? elementPID : (fallbackPID ?? 0)
        }

        let bundleID = queryClient.bundleIdentifier(for: effectivePID)
            ?? fallbackBundleID
            ?? ""

        let bounds = readSelectionBounds(
            from: match,
            expectedPID: effectivePID,
            expectedBundleURL: fallbackBundleURL
        )
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
        guard let frontmostApp = queryClient.frontmostApplication(),
              frontmostApp.processIdentifier != 0 else {
            return nil
        }

        let frontPID = frontmostApp.processIdentifier
        let frontBundleURL = frontmostApp.bundleURL
        let appElement = queryClient.createApplicationElement(pid: frontPID)

        if let focused = copyFocusedElement(frontmostPID: frontPID),
           let docFromFocused = readDocumentPathFromAncestors(
               startingAt: focused,
               expectedPID: frontPID,
               expectedBundleURL: frontBundleURL
           ) {
            return docFromFocused
        }

        for windowAttr in [kAXFocusedWindowAttribute as String, kAXMainWindowAttribute as String] {
            let (winStatus, windowElement) = queryClient.copyAttributeValue(windowAttr, from: appElement)
            guard winStatus == .success,
                  let windowElement,
                  queryClient.isValidElement(windowElement) else {
                continue
            }
            if let path = extractLocalPathAttribute(from: windowElement) {
                return path
            }
            let (proxyStatus, proxyElement) = queryClient.copyAttributeValue(
                kAXProxyAttribute as String,
                from: windowElement
            )
            if proxyStatus == .success,
               let proxyElement,
               queryClient.isValidElement(proxyElement),
               let proxyPath = extractLocalPathAttribute(from: proxyElement) {
                return proxyPath
            }
        }

        return nil
    }

    func captureFocusedTarget() -> AnyObject? {
        let frontmostApp = queryClient.frontmostApplication()
        let frontmostPID = frontmostApp?.processIdentifier
        let frontmostBundleURL = frontmostApp?.bundleURL
        if let pid = frontmostPID, pid != 0 {
            _ = applicationSupport.prepareApplicationIfNeeded(
                pid: pid,
                bundleID: frontmostApp?.bundleIdentifier,
                bundleURL: frontmostBundleURL,
                using: queryClient
            )
        }
        if let match = findSelectionElement(
            frontmostPID: frontmostPID,
            frontmostBundleURL: frontmostBundleURL
        ) {
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
                let (status, attributedRef) = queryClient.copyParameterizedAttributeValue(
                    kAXAttributedStringForRangeParameterizedAttribute as String,
                    parameter: rangeAX,
                    from: element
                )
                if status == .success,
                   let attributed = attributedRef as? NSAttributedString,
                   attributed.length > 0 {
                    return attributed
                }
            }
        }

        if let markerRange = copySelectedTextMarkerRange(from: element) {
            let (status, markerAttrRef) = queryClient.copyParameterizedAttributeValue(
                Self.axAttributedStringForTextMarkerRangeAttribute,
                parameter: markerRange,
                from: element
            )
            if status == .success,
               let attributed = markerAttrRef as? NSAttributedString,
               attributed.length > 0 {
                return attributed
            }
        }

        return nil
    }

    func setSelectedText(_ text: String, in target: AnyObject?) -> Bool {
        guard let element = resolveElement(from: target) else {
            return false
        }

        if !queryClient.isAttributeSettable(kAXSelectedTextAttribute as String, on: element) {
            return false
        }

        return queryClient.setAttributeValue(
            text as CFTypeRef,
            forAttribute: kAXSelectedTextAttribute as String,
            on: element
        ) == .success
    }

    func insertAtFocusedPosition(_ text: String, in target: AnyObject?) -> Bool {
        guard let element = resolveElement(from: target) else {
            return false
        }

        guard queryClient.isAttributeSettable(kAXValueAttribute as String, on: element) else {
            return false
        }

        let (valueStatus, currentValueRef) = queryClient.copyAttributeValue(
            kAXValueAttribute as String,
            from: element
        )
        guard valueStatus == .success,
              let currentValue = currentValueRef as? String,
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
        guard queryClient.setAttributeValue(
            updatedValue as CFTypeRef,
            forAttribute: kAXValueAttribute as String,
            on: element
        ) == .success else {
            return false
        }

        var newCaret = CFRange(location: cfRange.location + (text as NSString).length, length: 0)
        if let caretAX = AXValueCreate(.cfRange, &newCaret) {
            _ = queryClient.setAttributeValue(
                caretAX,
                forAttribute: kAXSelectedTextRangeAttribute as String,
                on: element
            )
        }
        return true
    }

    private func resolveElement(from target: AnyObject?) -> AnyObject? {
        if let target, queryClient.isValidElement(target) {
            return target
        }
        let frontmostApp = queryClient.frontmostApplication()
        let frontmostPID = frontmostApp?.processIdentifier
        if let match = findSelectionElement(
            frontmostPID: frontmostPID,
            frontmostBundleURL: frontmostApp?.bundleURL
        ) {
            return match.element
        }
        return copyFocusedElement(frontmostPID: frontmostPID)
    }

    private func findSelectionElement(
        frontmostPID: pid_t?,
        frontmostBundleURL: URL?
    ) -> SelectionMatch? {
        var visited: [AnyObject] = []
        var focusedCandidates: [AnyObject] = []

        func appendCandidateIfMatching(_ candidate: AnyObject?) {
            guard let candidate, queryClient.isValidElement(candidate) else { return }
            let elemPID = queryClient.pid(of: candidate)
            if let frontPID = frontmostPID, frontPID != 0 {
                guard queryClient.belongsToApplication(
                    elementPID: elemPID,
                    appPID: frontPID,
                    appBundleURL: frontmostBundleURL
                ) else {
                    return
                }
            }
            if !focusedCandidates.contains(where: { queryClient.areElementsEqual($0, candidate) }) {
                focusedCandidates.append(candidate)
            }
        }

        let systemWide = queryClient.createSystemWideElement()
        let (sysStatus, sysFocused) = queryClient.copyAttributeValue(
            kAXFocusedUIElementAttribute as String,
            from: systemWide
        )
        if sysStatus == .success {
            appendCandidateIfMatching(sysFocused)
        }

        let appElement: AnyObject? = (frontmostPID != nil && frontmostPID != 0)
            ? queryClient.createApplicationElement(pid: frontmostPID!)
            : nil

        if let appElement {
            let (appStatus, appFocused) = queryClient.copyAttributeValue(
                kAXFocusedUIElementAttribute as String,
                from: appElement
            )
            if appStatus == .success {
                appendCandidateIfMatching(appFocused)
            }

            let (winStatus, focusedWindow) = queryClient.copyAttributeValue(
                kAXFocusedWindowAttribute as String,
                from: appElement
            )
            if winStatus == .success, let focusedWindow, queryClient.isValidElement(focusedWindow) {
                let (winFocusStatus, winFocused) = queryClient.copyAttributeValue(
                    kAXFocusedUIElementAttribute as String,
                    from: focusedWindow
                )
                if winFocusStatus == .success {
                    appendCandidateIfMatching(winFocused)
                }
            }
        }

        for candidate in focusedCandidates {
            if let match = checkElementAndAncestors(
                candidate,
                expectedPID: frontmostPID,
                expectedBundleURL: frontmostBundleURL,
                visited: &visited
            ) {
                return match
            }
        }

        if let frontPID = frontmostPID, frontPID != 0, !queryClient.isLeftMouseButtonPressed() {
            let quartzMouse = convertAppKitPointToQuartz(queryClient.mouseLocation())
            if let hitElement = queryClient.copyElementAtPosition(
                x: Float(quartzMouse.x),
                y: Float(quartzMouse.y)
            ), queryClient.belongsToApplication(
                elementPID: queryClient.pid(of: hitElement),
                appPID: frontPID,
                appBundleURL: frontmostBundleURL
            ) {
                if let match = checkElementAndAncestors(
                    hitElement,
                    expectedPID: frontPID,
                    expectedBundleURL: frontmostBundleURL,
                    visited: &visited
                ) {
                    return match
                }
            }
        }

        // Always search the frontmost application's windows when focused candidates and
        // pointer hit-testing returned no selection. In Electron apps (such as Orca),
        // focus may sit on an outer shell AXWebArea or split-pane input while the real
        // selection lives inside a deeper AXWebArea (e.g. behind AXScrollArea at depth 8+
        // or inside a child WebContentsView / iframe).
        if let appElement {
            if let windowMatch = searchWindowSelection(in: appElement, visited: &visited) {
                return windowMatch
            }
        }

        return nil
    }

    private func checkElementAndAncestors(
        _ startElement: AnyObject,
        expectedPID: pid_t?,
        expectedBundleURL: URL?,
        visited: inout [AnyObject]
    ) -> SelectionMatch? {
        var current: AnyObject? = startElement
        var steps = 0
        var pendingMarkerMatch: SelectionMatch?

        while let element = current, steps < Self.maxAncestorSteps {
            steps += 1

            if let expectedPID, expectedPID != 0 {
                let currentPID = queryClient.pid(of: element)
                if !queryClient.belongsToApplication(
                    elementPID: currentPID,
                    appPID: expectedPID,
                    appBundleURL: expectedBundleURL
                ) {
                    break
                }
            }

            if visited.contains(where: { queryClient.areElementsEqual($0, element) }) {
                break
            }
            visited.append(element)

            let role = copyRole(of: element)
            if role == (kAXApplicationRole as String) {
                break
            }

            if role != "AXSecureTextField" {
                if let directText = readDirectSelectedText(from: element),
                   !directText.isEmpty {
                    return SelectionMatch(
                        element: element,
                        text: directText,
                        markerRange: nil,
                        allowsElementBoundsFallback: true
                    )
                }

                // Chromium/Electron exposes the document-wide AXSelectedTextMarkerRange on
                // every DOM node in the tree, including a focused composer AXTextField or
                // AXTextArea whose own selection is empty (range.length == 0). Keep walking
                // up to the owning AXWebArea / AXDocument instead of anchoring to the
                // focused input control or an intermediate wrapper group.
                if let markerMatch = readMarkerSelectedText(from: element),
                   !markerMatch.text.isEmpty {
                    if let role, Self.markerDocumentRoles.contains(role) {
                        return SelectionMatch(
                            element: element,
                            text: markerMatch.text,
                            markerRange: markerMatch.markerRange,
                            allowsElementBoundsFallback: true
                        )
                    }
                    if pendingMarkerMatch == nil {
                        pendingMarkerMatch = SelectionMatch(
                            element: element,
                            text: markerMatch.text,
                            markerRange: markerMatch.markerRange,
                            allowsElementBoundsFallback: false
                        )
                    }
                }
            }

            if role == (kAXWindowRole as String) {
                break
            }

            let (parentStatus, parentRef) = queryClient.copyAttributeValue(
                kAXParentAttribute as String,
                from: element
            )
            guard parentStatus == .success,
                  let parent = parentRef,
                  queryClient.isValidElement(parent) else {
                break
            }
            current = parent
        }

        return pendingMarkerMatch
    }

    private func searchWindowSelection(
        in appElement: AnyObject,
        visited: inout [AnyObject]
    ) -> SelectionMatch? {
        var candidateWindows: [AnyObject] = []
        func addWindow(_ window: AnyObject?) {
            guard let window, queryClient.isValidElement(window) else { return }
            if !candidateWindows.contains(where: { queryClient.areElementsEqual($0, window) }) {
                candidateWindows.append(window)
            }
        }

        for attr in [kAXFocusedWindowAttribute as String, kAXMainWindowAttribute as String] {
            let (status, windowRef) = queryClient.copyAttributeValue(attr, from: appElement)
            if status == .success {
                addWindow(windowRef)
            }
        }

        let (windowsStatus, windowsRef) = queryClient.copyAttributeValue(
            kAXWindowsAttribute as String,
            from: appElement
        )
        if windowsStatus == .success, let windows = windowsRef as? [AnyObject] {
            for window in windows.prefix(Self.maxSearchedWindows) {
                addWindow(window)
            }
        }

        guard !candidateWindows.isEmpty else { return nil }

        var inspectedContainers = 0
        for rootWindow in candidateWindows {
            var queue: [(element: AnyObject, depth: Int)] = [(rootWindow, 0)]
            var index = 0

            while index < queue.count && inspectedContainers < Self.maxInspectedContainers {
                let (node, depth) = queue[index]
                index += 1
                inspectedContainers += 1

                let role = copyRole(of: node) ?? ""
                if Self.documentSelectionRoles.contains(role),
                   !visited.contains(where: { queryClient.areElementsEqual($0, node) }) {
                    visited.append(node)
                    if let directText = readDirectSelectedText(from: node), !directText.isEmpty {
                        return SelectionMatch(
                            element: node,
                            text: directText,
                            markerRange: nil,
                            allowsElementBoundsFallback: true
                        )
                    }
                    if Self.markerDocumentRoles.contains(role),
                       let markerMatch = readMarkerSelectedText(from: node),
                       !markerMatch.text.isEmpty {
                        return SelectionMatch(
                            element: node,
                            text: markerMatch.text,
                            markerRange: markerMatch.markerRange,
                            allowsElementBoundsFallback: true
                        )
                    }
                }

                guard depth < Self.maxWindowSearchDepth, Self.containerRoles.contains(role) else {
                    continue
                }

                let (childrenStatus, childrenRef) = queryClient.copyAttributeValue(
                    kAXChildrenAttribute as String,
                    from: node
                )
                guard childrenStatus == .success, let children = childrenRef as? [AnyObject] else {
                    continue
                }

                for child in children.prefix(Self.maxChildrenPerContainer) where queryClient.isValidElement(child) {
                    queue.append((child, depth + 1))
                }
            }
        }

        return nil
    }

    private func copyFocusedElement(frontmostPID: pid_t?) -> AnyObject? {
        let systemWide = queryClient.createSystemWideElement()
        let (sysStatus, focusedRef) = queryClient.copyAttributeValue(
            kAXFocusedUIElementAttribute as String,
            from: systemWide
        )
        if sysStatus == .success, let focusedRef, queryClient.isValidElement(focusedRef) {
            return focusedRef
        }

        guard let pid = frontmostPID, pid != 0 else { return nil }
        let appElement = queryClient.createApplicationElement(pid: pid)
        let (appStatus, appFocusedRef) = queryClient.copyAttributeValue(
            kAXFocusedUIElementAttribute as String,
            from: appElement
        )
        guard appStatus == .success, let appFocusedRef, queryClient.isValidElement(appFocusedRef) else {
            return nil
        }
        return appFocusedRef
    }

    private func hasExplicitEmptyRangeSelection(on element: AnyObject) -> Bool {
        let (rangesStatus, rangesRef) = queryClient.copyAttributeValue(
            kAXSelectedTextRangesAttribute as String,
            from: element
        )
        if rangesStatus == .success,
           let rangeValues = rangesRef as? [AXValue],
           rangeValues.contains(where: { rangeVal in
               guard AXValueGetType(rangeVal) == .cfRange else { return false }
               var range = CFRange(location: 0, length: 0)
               return AXValueGetValue(rangeVal, .cfRange, &range) && range.length > 0
           }) {
            return false
        }

        guard let rangeValue = copySelectedRangeAXValue(from: element) else {
            return false
        }
        var range = CFRange(location: 0, length: 0)
        return AXValueGetValue(rangeValue, .cfRange, &range) && range.length == 0
    }

    private func readDirectSelectedText(from element: AnyObject) -> String? {
        if let role = copyRole(of: element),
           Self.textInputRoles.contains(role),
           hasExplicitEmptyRangeSelection(on: element) {
            return nil
        }

        let (textStatus, textRef) = queryClient.copyAttributeValue(
            kAXSelectedTextAttribute as String,
            from: element
        )
        if textStatus == .success {
            if let text = textRef as? String, !text.isEmpty { return text }
            if let attributed = textRef as? NSAttributedString, !attributed.string.isEmpty {
                return attributed.string
            }
        }

        if let rangeValue = copySelectedRangeAXValue(from: element) {
            var range = CFRange(location: 0, length: 0)
            if AXValueGetValue(rangeValue, .cfRange, &range), range.length > 0 {
                let (strStatus, parameterizedTextRef) = queryClient.copyParameterizedAttributeValue(
                    kAXStringForRangeParameterizedAttribute as String,
                    parameter: rangeValue,
                    from: element
                )
                if strStatus == .success {
                    if let text = parameterizedTextRef as? String, !text.isEmpty {
                        return text
                    }
                    if let attributed = parameterizedTextRef as? NSAttributedString, !attributed.string.isEmpty {
                        return attributed.string
                    }
                }

                let (attrStatus, attrRangeRef) = queryClient.copyParameterizedAttributeValue(
                    kAXAttributedStringForRangeParameterizedAttribute as String,
                    parameter: rangeValue,
                    from: element
                )
                if attrStatus == .success,
                   let attributed = attrRangeRef as? NSAttributedString,
                   !attributed.string.isEmpty {
                    return attributed.string
                }
            }
        }

        let (rangesStatus, rangesRef) = queryClient.copyAttributeValue(
            kAXSelectedTextRangesAttribute as String,
            from: element
        )
        if rangesStatus == .success,
           let rangeValues = rangesRef as? [AXValue],
           !rangeValues.isEmpty {
            var pieces: [String] = []
            for rangeVal in rangeValues where AXValueGetType(rangeVal) == .cfRange {
                var range = CFRange(location: 0, length: 0)
                guard AXValueGetValue(rangeVal, .cfRange, &range), range.length > 0 else { continue }
                let (pieceStatus, pieceRef) = queryClient.copyParameterizedAttributeValue(
                    kAXStringForRangeParameterizedAttribute as String,
                    parameter: rangeVal,
                    from: element
                )
                if pieceStatus == .success, let piece = pieceRef as? String, !piece.isEmpty {
                    pieces.append(piece)
                }
            }
            if !pieces.isEmpty {
                return pieces.joined(separator: "\n")
            }
        }

        return nil
    }

    private func readMarkerSelectedText(from element: AnyObject) -> (text: String, markerRange: CFTypeRef)? {
        guard let markerRange = copySelectedTextMarkerRange(from: element) else {
            return nil
        }

        let (markerTextStatus, markerTextRef) = queryClient.copyParameterizedAttributeValue(
            Self.axStringForTextMarkerRangeAttribute,
            parameter: markerRange,
            from: element
        )
        if markerTextStatus == .success {
            if let text = markerTextRef as? String, !text.isEmpty {
                return (text, markerRange)
            }
            if let attributed = markerTextRef as? NSAttributedString, !attributed.string.isEmpty {
                return (attributed.string, markerRange)
            }
        }

        let (markerAttrStatus, markerAttrRef) = queryClient.copyParameterizedAttributeValue(
            Self.axAttributedStringForTextMarkerRangeAttribute,
            parameter: markerRange,
            from: element
        )
        if markerAttrStatus == .success {
            if let attributed = markerAttrRef as? NSAttributedString, !attributed.string.isEmpty {
                return (attributed.string, markerRange)
            }
            if let text = markerAttrRef as? String, !text.isEmpty {
                return (text, markerRange)
            }
        }

        return nil
    }

    private func readSelectionBounds(
        from match: SelectionMatch,
        expectedPID: pid_t?,
        expectedBundleURL: URL?
    ) -> CGRect {
        let element = match.element

        if let rangeBounds = readRangeSelectionBounds(from: element) {
            return rangeBounds
        }

        if let markerBounds = readMarkerSelectionBounds(
            startingAt: element,
            fallbackMarkerRange: match.markerRange,
            expectedPID: expectedPID,
            expectedBundleURL: expectedBundleURL
        ) {
            return markerBounds
        }

        let role = copyRole(of: element) ?? ""
        let canUseElementBounds = match.allowsElementBoundsFallback
            && !(Self.textInputRoles.contains(role) && hasExplicitEmptyRangeSelection(on: element))

        if canUseElementBounds {
            if let quartzRect = readElementQuartzRect(from: element) {
                return anchorWithinElementRect(convertQuartzToAppKitScreen(quartzRect))
            }
        }

        let mouse = queryClient.mouseLocation()
        return CGRect(x: mouse.x, y: mouse.y - 10, width: 1, height: 20)
    }

    private func readRangeSelectionBounds(from element: AnyObject) -> CGRect? {
        if let rangeValue = copySelectedRangeAXValue(from: element) {
            var range = CFRange(location: 0, length: 0)
            if AXValueGetValue(rangeValue, .cfRange, &range), range.length > 0 {
                let (boundsStatus, boundsRef) = queryClient.copyParameterizedAttributeValue(
                    kAXBoundsForRangeParameterizedAttribute as String,
                    parameter: rangeValue,
                    from: element
                )
                if boundsStatus == .success, let quartzRect = extractNonEmptyRect(from: boundsRef) {
                    return convertQuartzToAppKitScreen(quartzRect)
                }
            }
        }

        let (rangesStatus, rangesRef) = queryClient.copyAttributeValue(
            kAXSelectedTextRangesAttribute as String,
            from: element
        )
        if rangesStatus == .success,
           let rangeValues = rangesRef as? [AXValue],
           !rangeValues.isEmpty {
            var combined = CGRect.null
            for rangeVal in rangeValues where AXValueGetType(rangeVal) == .cfRange {
                var range = CFRange(location: 0, length: 0)
                guard AXValueGetValue(rangeVal, .cfRange, &range), range.length > 0 else { continue }
                let (boundsStatus, boundsRef) = queryClient.copyParameterizedAttributeValue(
                    kAXBoundsForRangeParameterizedAttribute as String,
                    parameter: rangeVal,
                    from: element
                )
                if boundsStatus == .success, let quartzRect = extractNonEmptyRect(from: boundsRef) {
                    combined = combined.isNull ? quartzRect : combined.union(quartzRect)
                }
            }
            if !combined.isNull, combined.width > 0, combined.height > 0 {
                return convertQuartzToAppKitScreen(combined)
            }
        }

        return nil
    }

    private func readMarkerSelectionBounds(
        startingAt startElement: AnyObject,
        fallbackMarkerRange: CFTypeRef?,
        expectedPID: pid_t?,
        expectedBundleURL: URL?
    ) -> CGRect? {
        var hosts: [AnyObject] = []
        var current: AnyObject? = startElement
        var steps = 0

        while let node = current, steps < Self.maxAncestorSteps {
            steps += 1
            if let expectedPID, expectedPID != 0 {
                let nodePID = queryClient.pid(of: node)
                if !queryClient.belongsToApplication(
                    elementPID: nodePID,
                    appPID: expectedPID,
                    appBundleURL: expectedBundleURL
                ) {
                    break
                }
            }
            let role = copyRole(of: node)
            if role == (kAXApplicationRole as String) || role == (kAXWindowRole as String) {
                break
            }
            if !hosts.contains(where: { queryClient.areElementsEqual($0, node) }) {
                hosts.append(node)
            }
            let (parentStatus, parentRef) = queryClient.copyAttributeValue(
                kAXParentAttribute as String,
                from: node
            )
            guard parentStatus == .success,
                  let parent = parentRef,
                  queryClient.isValidElement(parent) else {
                break
            }
            current = parent
        }

        for host in hosts {
            if let hostMarkerRange = copySelectedTextMarkerRange(from: host) {
                let (status, boundsRef) = queryClient.copyParameterizedAttributeValue(
                    Self.axBoundsForTextMarkerRangeAttribute,
                    parameter: hostMarkerRange,
                    from: host
                )
                if status == .success, let quartzRect = extractNonEmptyRect(from: boundsRef) {
                    return convertQuartzToAppKitScreen(quartzRect)
                }
            }
            if let fallbackMarkerRange {
                let (status, boundsRef) = queryClient.copyParameterizedAttributeValue(
                    Self.axBoundsForTextMarkerRangeAttribute,
                    parameter: fallbackMarkerRange,
                    from: host
                )
                if status == .success, let quartzRect = extractNonEmptyRect(from: boundsRef) {
                    return convertQuartzToAppKitScreen(quartzRect)
                }
            }
        }

        // Fallback when AXBoundsForTextMarkerRange returns an empty/zero rect in
        // Chromium/Electron: resolve the marker range's start and end markers to their
        // concrete DOM AX elements via AXUIElementForTextMarker and union their bounds.
        for host in hosts {
            guard let markerRange = copySelectedTextMarkerRange(from: host) ?? fallbackMarkerRange else {
                continue
            }
            if let endpointQuartzRect = readMarkerEndpointQuartzBounds(markerRange: markerRange, on: host) {
                return convertQuartzToAppKitScreen(endpointQuartzRect)
            }
        }

        return nil
    }

    private func readMarkerEndpointQuartzBounds(markerRange: CFTypeRef, on host: AnyObject) -> CGRect? {
        var markers: [CFTypeRef] = []
        if CFGetTypeID(markerRange) == AXTextMarkerRangeGetTypeID() {
            let typedRange = unsafeBitCast(markerRange, to: AXTextMarkerRange.self)
            markers.append(AXTextMarkerRangeCopyStartMarker(typedRange))
            markers.append(AXTextMarkerRangeCopyEndMarker(typedRange))
        } else {
            for attr in [
                Self.axStartTextMarkerForTextMarkerRangeAttribute,
                Self.axEndTextMarkerForTextMarkerRangeAttribute
            ] {
                let (status, markerRef) = queryClient.copyParameterizedAttributeValue(
                    attr,
                    parameter: markerRange,
                    from: host
                )
                if status == .success, let markerRef {
                    markers.append(markerRef)
                }
            }
        }

        guard !markers.isEmpty else { return nil }

        var combined = CGRect.null
        for marker in markers {
            let (status, elemRef) = queryClient.copyParameterizedAttributeValue(
                Self.axUIElementForTextMarkerAttribute,
                parameter: marker,
                from: host
            )
            guard status == .success,
                  let markerElement = elemRef,
                  queryClient.isValidElement(markerElement) else {
                continue
            }
            let role = copyRole(of: markerElement) ?? ""
            guard !Self.nonLeafMarkerElementRoles.contains(role) else {
                continue
            }
            if let rect = readElementQuartzRect(from: markerElement), rect.height <= 240 {
                combined = combined.isNull ? rect : combined.union(rect)
            }
        }

        guard !combined.isNull, combined.width > 0, combined.height > 0 else {
            return nil
        }
        return combined
    }

    private func readElementQuartzRect(from element: AnyObject) -> CGRect? {
        for attribute in [Self.axBoundsAttribute, Self.axFrameAttribute] {
            let (rectStatus, rectRef) = queryClient.copyAttributeValue(attribute, from: element)
            if rectStatus == .success, let quartzRect = extractNonEmptyRect(from: rectRef) {
                return quartzRect
            }
        }
        return readPositionAndSize(from: element)
    }

    private func anchorWithinElementRect(_ appKitRect: CGRect) -> CGRect {
        guard appKitRect.height > 80 else {
            return appKitRect
        }
        let mouse = queryClient.mouseLocation()
        if appKitRect.insetBy(dx: -20, dy: -20).contains(mouse) {
            return CGRect(x: mouse.x, y: mouse.y - 10, width: 1, height: 20)
        }
        return CGRect(x: appKitRect.midX, y: appKitRect.midY - 10, width: 1, height: 20)
    }

    private func copyRole(of element: AnyObject) -> String? {
        let (status, roleRef) = queryClient.copyAttributeValue(
            kAXRoleAttribute as String,
            from: element
        )
        guard status == .success else { return nil }
        return roleRef as? String
    }

    private func convertAppKitPointToQuartz(_ appKitPoint: NSPoint) -> CGPoint {
        guard let primaryHeight = queryClient.primaryScreenHeight(), primaryHeight > 0 else {
            return appKitPoint
        }
        return CGPoint(x: appKitPoint.x, y: primaryHeight - appKitPoint.y)
    }

    private func copySelectedTextMarkerRange(from element: AnyObject) -> CFTypeRef? {
        let (status, markerRangeRef) = queryClient.copyAttributeValue(
            Self.axSelectedTextMarkerRangeAttribute,
            from: element
        )
        guard status == .success, let markerRangeRef else {
            return nil
        }
        return markerRangeRef
    }

    private func copySelectedRangeAXValue(from element: AnyObject) -> AXValue? {
        let (status, rangeRef) = queryClient.copyAttributeValue(
            kAXSelectedTextRangeAttribute as String,
            from: element
        )
        guard status == .success, let axValue = asAXValue(rangeRef), AXValueGetType(axValue) == .cfRange else {
            return nil
        }
        return axValue
    }

    private func readPositionAndSize(from element: AnyObject) -> CGRect? {
        let (posStatus, positionRef) = queryClient.copyAttributeValue(
            kAXPositionAttribute as String,
            from: element
        )
        let (sizeStatus, sizeRef) = queryClient.copyAttributeValue(
            kAXSizeAttribute as String,
            from: element
        )
        guard posStatus == .success,
              sizeStatus == .success,
              let positionAX = asAXValue(positionRef),
              let sizeAX = asAXValue(sizeRef) else {
            return nil
        }

        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionAX, .cgPoint, &origin),
              AXValueGetValue(sizeAX, .cgSize, &size),
              size.width > 0 && size.height > 0 else {
            return nil
        }
        return CGRect(origin: origin, size: size)
    }

    private func extractNonEmptyRect(from ref: AnyObject?) -> CGRect? {
        guard let axValue = asAXValue(ref), AXValueGetType(axValue) == .cgRect else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(axValue, .cgRect, &rect),
              !rect.isNull,
              !rect.isInfinite else {
            return nil
        }
        let standardized = rect.standardized
        guard standardized.width > 0 && standardized.height > 0 else {
            return nil
        }
        return standardized
    }

    private func convertQuartzToAppKitScreen(_ quartzRect: CGRect) -> CGRect {
        let standardized = quartzRect.standardized
        guard let primaryHeight = queryClient.primaryScreenHeight(), primaryHeight > 0 else {
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
        startingAt element: AnyObject,
        expectedPID: pid_t,
        expectedBundleURL: URL?
    ) -> String? {
        var current: AnyObject? = element
        var steps = 0
        while let node = current, steps < Self.maxAncestorSteps {
            steps += 1
            let nodePID = queryClient.pid(of: node)
            if !queryClient.belongsToApplication(
                elementPID: nodePID,
                appPID: expectedPID,
                appBundleURL: expectedBundleURL
            ) {
                break
            }
            if let path = extractLocalPathAttribute(from: node) {
                return path
            }
            if copyRole(of: node) == (kAXApplicationRole as String) {
                break
            }
            let (parentStatus, parentRef) = queryClient.copyAttributeValue(
                kAXParentAttribute as String,
                from: node
            )
            guard parentStatus == .success,
                  let parent = parentRef,
                  queryClient.isValidElement(parent) else {
                break
            }
            current = parent
        }
        return nil
    }

    private func extractLocalPathAttribute(from element: AnyObject) -> String? {
        for attr in [kAXDocumentAttribute as String, kAXURLAttribute as String, kAXFilenameAttribute as String] {
            let (status, valueRef) = queryClient.copyAttributeValue(attr, from: element)
            guard status == .success, let valueRef else {
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

    private func asAXValue(_ ref: AnyObject?) -> AXValue? {
        guard let ref, CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        return unsafeBitCast(ref, to: AXValue.self)
    }
}
