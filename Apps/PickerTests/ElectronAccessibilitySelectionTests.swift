import AppKit
import ApplicationServices
import Foundation
import XCTest

private final class MockMarkerRangeToken: NSObject {
    let id: String

    init(_ id: String) {
        self.id = id
    }
}

private final class MockAXNode: NSObject {
    let pid: pid_t
    var role: String
    weak var parent: MockAXNode?
    var children: [MockAXNode] = []
    var attributes: [String: AnyObject] = [:]
    var settableAttributes: Set<String> = []
    var attributeSetterHook: ((String, AnyObject) -> Void)?
    var parameterizedAttributes: [String: (CFTypeRef) -> (AXError, AnyObject?)] = [:]
    var writtenValues: [String: AnyObject] = [:]

    init(pid: pid_t, role: String) {
        self.pid = pid
        self.role = role
        super.init()
        self.attributes[kAXRoleAttribute as String] = role as NSString
    }

    func addChild(_ child: MockAXNode) {
        child.parent = self
        children.append(child)
        attributes[kAXChildrenAttribute as String] = children as NSArray
    }
}

private final class FakeAccessibilityQueryClient: AccessibilityQuerying {
    var ownProcessIdentifier: pid_t = 9999
    var currentFrontmostApp: AccessibilityFrontmostApplication?
    var bundleIDsByPID: [pid_t: String] = [:]
    var appElementsByPID: [pid_t: MockAXNode] = [:]
    var systemWideElement = MockAXNode(pid: 0, role: "AXSystemWide")
    var hitElement: MockAXNode?
    var helperPIDsForAppPID: [pid_t: Set<pid_t>] = [:]
    var leftMousePressed = false
    var currentMouseLocation = NSPoint(x: 420, y: 520)
    var screenHeight: CGFloat? = 1080

    func frontmostApplication() -> AccessibilityFrontmostApplication? {
        currentFrontmostApp
    }

    func bundleIdentifier(for pid: pid_t) -> String? {
        bundleIDsByPID[pid]
    }

    func belongsToApplication(elementPID: pid_t, appPID: pid_t, appBundleURL: URL?) -> Bool {
        if appPID == 0 || elementPID == 0 || elementPID == appPID {
            return true
        }
        return helperPIDsForAppPID[appPID]?.contains(elementPID) ?? false
    }

    func isValidElement(_ target: AnyObject) -> Bool {
        target is MockAXNode
    }

    func createApplicationElement(pid: pid_t) -> AnyObject {
        if let existing = appElementsByPID[pid] {
            return existing
        }
        let created = MockAXNode(pid: pid, role: kAXApplicationRole as String)
        appElementsByPID[pid] = created
        return created
    }

    func createSystemWideElement() -> AnyObject {
        systemWideElement
    }

    func pid(of element: AnyObject) -> pid_t {
        (element as? MockAXNode)?.pid ?? 0
    }

    func areElementsEqual(_ lhs: AnyObject, _ rhs: AnyObject) -> Bool {
        lhs === rhs
    }

    func isAttributeSettable(_ attribute: String, on element: AnyObject) -> Bool {
        guard let node = element as? MockAXNode else { return false }
        return node.settableAttributes.contains(attribute)
    }

    func setAttributeValue(_ value: CFTypeRef, forAttribute attribute: String, on element: AnyObject) -> AXError {
        guard let node = element as? MockAXNode, node.settableAttributes.contains(attribute) else {
            return .attributeUnsupported
        }
        node.writtenValues[attribute] = value
        if let hook = node.attributeSetterHook {
            hook(attribute, value)
        } else {
            node.attributes[attribute] = value
        }
        return .success
    }

    func copyAttributeValue(_ attribute: String, from element: AnyObject) -> (AXError, AnyObject?) {
        guard let node = element as? MockAXNode else { return (.illegalArgument, nil) }
        if attribute == (kAXParentAttribute as String) {
            if let parent = node.parent {
                return (.success, parent)
            }
            return (.noValue, nil)
        }
        if attribute == (kAXChildrenAttribute as String) {
            return (.success, node.children as NSArray)
        }
        if let value = node.attributes[attribute] {
            return (.success, value)
        }
        return (.noValue, nil)
    }

    func copyParameterizedAttributeValue(
        _ attribute: String,
        parameter: CFTypeRef,
        from element: AnyObject
    ) -> (AXError, AnyObject?) {
        guard let node = element as? MockAXNode,
              let handler = node.parameterizedAttributes[attribute] else {
            return (.attributeUnsupported, nil)
        }
        return handler(parameter)
    }

    func copyElementAtPosition(x: Float, y: Float) -> AnyObject? {
        hitElement
    }

    func isLeftMouseButtonPressed() -> Bool {
        leftMousePressed
    }

    func mouseLocation() -> NSPoint {
        currentMouseLocation
    }

    func primaryScreenHeight() -> CGFloat? {
        screenHeight
    }
}

private final class SequenceSelectionReader: FocusedSelectionReading {
    var outcomes: [FocusedSelectionPollOutcome]
    private(set) var prepareCallCount = 0
    private(set) var readCallCount = 0

    init(outcomes: [FocusedSelectionPollOutcome]) {
        self.outcomes = outcomes
    }

    func prepareFrontmostApplication() {
        prepareCallCount += 1
    }

    func readFocusedSelection() -> FocusedSelectionPollOutcome {
        readCallCount += 1
        if outcomes.count > 1 {
            return outcomes.removeFirst()
        }
        return outcomes.first ?? .noSelection(bundleID: nil, processIdentifier: nil)
    }
}

final class ElectronAccessibilitySelectionTests: XCTestCase {
    private func makeAXRect(_ rect: CGRect) -> AXValue {
        var mutable = rect
        return AXValueCreate(.cgRect, &mutable)!
    }

    private func createTemporaryElectronBundle() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PickerElectronTest-\(UUID().uuidString).app", isDirectory: true)
        let resourcesURL = root.appendingPathComponent("Contents/Resources", isDirectory: true)
        let librariesURL = root.appendingPathComponent(
            "Contents/Frameworks/Electron Framework.framework/Versions/Current/Libraries",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: resourcesURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: librariesURL, withIntermediateDirectories: true)
        try Data("asar".utf8).write(to: resourcesURL.appendingPathComponent("app.asar"))
        try Data().write(to: librariesURL.appendingPathComponent("libEGL.dylib"))
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return root
    }

    func testPrepareApplicationSetsBothManualAccessibilityAndEnhancedUIForElectronBundle() throws {
        let electronBundleURL = try createTemporaryElectronBundle()
        let queryClient = FakeAccessibilityQueryClient()
        let electronPID: pid_t = 34348
        let appNode = MockAXNode(pid: electronPID, role: kAXApplicationRole as String)
        appNode.settableAttributes = [
            AccessibilityApplicationSupport.manualAccessibilityAttribute,
            AccessibilityApplicationSupport.enhancedUserInterfaceAttribute
        ]
        appNode.attributes[AccessibilityApplicationSupport.manualAccessibilityAttribute] = kCFBooleanFalse
        appNode.attributes[AccessibilityApplicationSupport.enhancedUserInterfaceAttribute] = kCFBooleanFalse
        // Match Electron AtomApplication's getter quirk: AXManualAccessibility continues reading false
        // after kAXModeComplete is enabled, while AXEnhancedUserInterface updates to true when set.
        appNode.attributeSetterHook = { attr, value in
            if attr == AccessibilityApplicationSupport.manualAccessibilityAttribute {
                appNode.attributes[attr] = kCFBooleanFalse
            } else {
                appNode.attributes[attr] = value
            }
        }
        queryClient.appElementsByPID[electronPID] = appNode

        let support = AccessibilityApplicationSupport(refreshInterval: 0)
        let wrote = support.prepareApplicationIfNeeded(
            pid: electronPID,
            bundleID: "com.stablyai.orca",
            bundleURL: electronBundleURL,
            using: queryClient
        )

        XCTAssertTrue(wrote)
        XCTAssertEqual(
            appNode.writtenValues[AccessibilityApplicationSupport.manualAccessibilityAttribute] as? Bool,
            true
        )
        XCTAssertEqual(
            appNode.writtenValues[AccessibilityApplicationSupport.enhancedUserInterfaceAttribute] as? Bool,
            true
        )
    }

    func testDeepElectronDOMFocusedLeafReachesAncestorWebAreaMarkerSelection() throws {
        let electronBundleURL = try createTemporaryElectronBundle()
        let queryClient = FakeAccessibilityQueryClient()
        let orcaPID: pid_t = 34348
        queryClient.bundleIDsByPID[orcaPID] = "com.stablyai.orca"
        queryClient.currentFrontmostApp = AccessibilityFrontmostApplication(
            processIdentifier: orcaPID,
            bundleIdentifier: "com.stablyai.orca",
            bundleURL: electronBundleURL
        )
        // Simulate system-wide focus returning CannotComplete (-25204), as observed in Electron.
        queryClient.systemWideElement.attributes.removeValue(forKey: kAXFocusedUIElementAttribute as String)

        let appNode = MockAXNode(pid: orcaPID, role: kAXApplicationRole as String)
        let windowNode = MockAXNode(pid: orcaPID, role: kAXWindowRole as String)
        appNode.addChild(windowNode)
        appNode.attributes[kAXFocusedWindowAttribute as String] = windowNode
        appNode.attributes[kAXWindowsAttribute as String] = [windowNode] as NSArray

        // Build 7 native Views/ScrollArea containers between AXWindow and AXWebArea (depth 8).
        var nativeParent = windowNode
        for idx in 0..<7 {
            let role = idx == 6 ? (kAXScrollAreaRole as String) : (kAXGroupRole as String)
            let wrapper = MockAXNode(pid: orcaPID, role: role)
            nativeParent.addChild(wrapper)
            nativeParent = wrapper
        }

        let webArea = MockAXNode(pid: orcaPID, role: "AXWebArea")
        nativeParent.addChild(webArea)

        let markerToken = MockMarkerRangeToken("orca-chat-selection")
        webArea.attributes["AXSelectedTextMarkerRange"] = markerToken
        let quartzRect = CGRect(x: 300, y: 200, width: 140, height: 22)
        webArea.parameterizedAttributes["AXStringForTextMarkerRange"] = { param in
            guard (param as? MockMarkerRangeToken)?.id == markerToken.id else {
                return (.noValue, nil)
            }
            return (.success, "selected in Orca chat" as NSString)
        }
        webArea.parameterizedAttributes["AXBoundsForTextMarkerRange"] = { [self] param in
            guard (param as? MockMarkerRangeToken)?.id == markerToken.id else {
                return (.noValue, nil)
            }
            return (.success, self.makeAXRect(quartzRect))
        }

        // Nest focused DOM container 16 levels below AXWebArea (>10 old ancestor limit).
        var domCurrent = webArea
        for _ in 0..<16 {
            let group = MockAXNode(pid: orcaPID, role: kAXGroupRole as String)
            domCurrent.addChild(group)
            domCurrent = group
        }
        appNode.attributes[kAXFocusedUIElementAttribute as String] = domCurrent
        queryClient.appElementsByPID[orcaPID] = appNode

        let client = AccessibilityFocusedElementClient(
            queryClient: queryClient,
            applicationSupport: AccessibilityApplicationSupport(refreshInterval: 0)
        )
        let outcome = client.readFocusedSelection()

        // Quartz y=200, h=22 on 1080px screen -> AppKit y = 1080 - 222 = 858.
        XCTAssertEqual(
            outcome,
            .selection(
                FocusedElementSelection(
                    text: "selected in Orca chat",
                    bounds: CGRect(x: 300, y: 858, width: 140, height: 22),
                    bundleID: "com.stablyai.orca",
                    processIdentifier: orcaPID
                )
            )
        )
    }

    func testWindowSearchFindsDeepPortalWebAreaWhenOuterWebAreaIsFocusedWithoutSelection() throws {
        let electronBundleURL = try createTemporaryElectronBundle()
        let queryClient = FakeAccessibilityQueryClient()
        let orcaPID: pid_t = 34348
        queryClient.bundleIDsByPID[orcaPID] = "com.stablyai.orca"
        queryClient.currentFrontmostApp = AccessibilityFrontmostApplication(
            processIdentifier: orcaPID,
            bundleIdentifier: "com.stablyai.orca",
            bundleURL: electronBundleURL
        )

        let appNode = MockAXNode(pid: orcaPID, role: kAXApplicationRole as String)
        let windowNode = MockAXNode(pid: orcaPID, role: kAXWindowRole as String)
        appNode.addChild(windowNode)
        appNode.attributes[kAXFocusedWindowAttribute as String] = windowNode
        appNode.attributes[kAXWindowsAttribute as String] = [windowNode] as NSArray

        // Outer shell AXWebArea at depth 7 has focus, but no selection of its own.
        var cursor = windowNode
        for _ in 0..<6 {
            let viewGroup = MockAXNode(pid: orcaPID, role: kAXGroupRole as String)
            cursor.addChild(viewGroup)
            cursor = viewGroup
        }
        let outerWebArea = MockAXNode(pid: orcaPID, role: "AXWebArea")
        cursor.addChild(outerWebArea)
        appNode.attributes[kAXFocusedUIElementAttribute as String] = outerWebArea

        // Nested portal/iframe AXWebArea sits at depth 11 inside the window.
        var portalHost = outerWebArea
        for _ in 0..<3 {
            let container = MockAXNode(pid: orcaPID, role: kAXGroupRole as String)
            portalHost.addChild(container)
            portalHost = container
        }
        let innerWebArea = MockAXNode(pid: orcaPID, role: "AXWebArea")
        innerWebArea.attributes[kAXSelectedTextAttribute as String] = "portal selection" as NSString
        innerWebArea.attributes["AXBounds"] = makeAXRect(CGRect(x: 500, y: 300, width: 90, height: 18))
        portalHost.addChild(innerWebArea)

        queryClient.appElementsByPID[orcaPID] = appNode

        let client = AccessibilityFocusedElementClient(
            queryClient: queryClient,
            applicationSupport: AccessibilityApplicationSupport(refreshInterval: 0)
        )
        let outcome = client.readFocusedSelection()

        XCTAssertEqual(
            outcome,
            .selection(
                FocusedElementSelection(
                    text: "portal selection",
                    bounds: CGRect(x: 500, y: 762, width: 90, height: 18),
                    bundleID: "com.stablyai.orca",
                    processIdentifier: orcaPID
                )
            )
        )
    }

    func testAcceptsHelperProcessElementBundledInsideFrontmostAppAndRejectsForeignPID() {
        let queryClient = FakeAccessibilityQueryClient()
        let hostPID: pid_t = 74158
        let helperPID: pid_t = 74171
        let foreignPID: pid_t = 88888
        queryClient.bundleIDsByPID[hostPID] = "com.example.host"
        queryClient.helperPIDsForAppPID[hostPID] = [helperPID]
        queryClient.currentFrontmostApp = AccessibilityFrontmostApplication(
            processIdentifier: hostPID,
            bundleIdentifier: "com.example.host",
            bundleURL: URL(fileURLWithPath: "/Applications/ExampleHost.app")
        )

        let helperElement = MockAXNode(pid: helperPID, role: "AXWebArea")
        helperElement.attributes[kAXSelectedTextAttribute as String] = "helper web selection" as NSString
        queryClient.hitElement = helperElement

        let client = AccessibilityFocusedElementClient(
            queryClient: queryClient,
            applicationSupport: AccessibilityApplicationSupport(refreshInterval: 0)
        )
        let helperOutcome = client.readFocusedSelection()
        if case .selection(let selection) = helperOutcome {
            XCTAssertEqual(selection.text, "helper web selection")
            XCTAssertEqual(selection.bundleID, "com.example.host")
            XCTAssertEqual(selection.processIdentifier, hostPID)
        } else {
            XCTFail("Expected helper-process selection to be accepted, got \(helperOutcome)")
        }

        let foreignElement = MockAXNode(pid: foreignPID, role: "AXWebArea")
        foreignElement.attributes[kAXSelectedTextAttribute as String] = "foreign selection" as NSString
        queryClient.hitElement = foreignElement

        let foreignOutcome = client.readFocusedSelection()
        XCTAssertEqual(
            foreignOutcome,
            .noSelection(bundleID: "com.example.host", processIdentifier: hostPID)
        )
    }

    func testReturnsNoSelectionWhenXtermCanvasOrCustomChatViewPublishesNoAXSelection() {
        let queryClient = FakeAccessibilityQueryClient()
        let wechatPID: pid_t = 74158
        queryClient.bundleIDsByPID[wechatPID] = "com.tencent.xinWeChat"
        queryClient.currentFrontmostApp = AccessibilityFrontmostApplication(
            processIdentifier: wechatPID,
            bundleIdentifier: "com.tencent.xinWeChat",
            bundleURL: URL(fileURLWithPath: "/Applications/WeChat.app")
        )

        let wechatApp = MockAXNode(pid: wechatPID, role: kAXApplicationRole as String)
        let chatWindow = MockAXNode(pid: wechatPID, role: kAXWindowRole as String)
        let customChatBubble = MockAXNode(pid: wechatPID, role: kAXGroupRole as String)
        chatWindow.addChild(customChatBubble)
        wechatApp.addChild(chatWindow)
        wechatApp.attributes[kAXFocusedWindowAttribute as String] = chatWindow
        wechatApp.attributes[kAXFocusedUIElementAttribute as String] = customChatBubble
        queryClient.appElementsByPID[wechatPID] = wechatApp

        let client = AccessibilityFocusedElementClient(
            queryClient: queryClient,
            applicationSupport: AccessibilityApplicationSupport(refreshInterval: 0)
        )
        XCTAssertEqual(
            client.readFocusedSelection(),
            .noSelection(bundleID: "com.tencent.xinWeChat", processIdentifier: wechatPID)
        )
    }

    func testSelectionMonitorPreparesOnActivationAndRetriesAfterMouseUpWhenElectronCommitsSelectionLate() {
        let suiteName = "PickerMonitorTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let workspaceCenter = NotificationCenter()
        let reader = SequenceSelectionReader(outcomes: [
            // Initial 60ms poll after mouse-up happens while Electron is still building its AXTree.
            .noSelection(bundleID: "com.stablyai.orca", processIdentifier: 34348),
            // Retry poll observes the selection once AXWebArea is ready.
            .selection(
                FocusedElementSelection(
                    text: "async electron selection",
                    bounds: CGRect(x: 200, y: 400, width: 120, height: 20),
                    bundleID: "com.stablyai.orca",
                    processIdentifier: 34348
                )
            )
        ])

        let selectionExpectation = expectation(description: "Observed delayed Electron selection")
        var observedSelections: [(String, String)] = []

        let monitor = SelectionMonitor(
            userDefaults: defaults,
            selectionReader: reader,
            isAccessibilityTrusted: { true },
            ownBundleID: "app.picker.mac",
            ownProcessIdentifier: 9999,
            workspaceNotificationCenter: workspaceCenter,
            onSelection: { text, _, bundleID in
                observedSelections.append((text, bundleID))
                selectionExpectation.fulfill()
            }
        )

        monitor.start()
        defer { monitor.stop() }
        XCTAssertEqual(reader.prepareCallCount, 1)

        workspaceCenter.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        XCTAssertEqual(reader.prepareCallCount, 2)

        monitor.handleMouseSelectionRelease(
            clickCount: 1,
            dragDistance: 24,
            initialDelay: 0.01,
            retryDelay: 0.02,
            isLeftMousePressed: { false }
        )

        wait(for: [selectionExpectation], timeout: 1.0)
        XCTAssertEqual(observedSelections.count, 1)
        XCTAssertEqual(observedSelections.first?.0, "async electron selection")
        XCTAssertEqual(observedSelections.first?.1, "com.stablyai.orca")
    }
}
