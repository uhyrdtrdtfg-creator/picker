import AppKit
import ApplicationServices
import Foundation

final class SelectionMonitor {
    static let pollInterval: TimeInterval = 0.4
    static let excludedBundleIDsDefaultsKey = "picker.excludedBundleIDs"
    static let appearAutomaticallyDefaultsKey = "picker.appearAutomatically"
    private static let legacyAppearAutomaticallyKey = "appearAutomatically"
    private static let legacyExcludedBundlesKey = "excludedBundleIdentifiers"
    private static let fallbackOwnBundleID = "app.picker.mac"

    var onSelection: ((String, CGRect, String) -> Void)?
    var onPermissionMissing: (() -> Void)?

    var appearAutomatically: Bool {
        get { storedAppearAutomatically }
        set {
            guard storedAppearAutomatically != newValue else { return }
            storedAppearAutomatically = newValue
            isUpdatingDefaultsInternally = true
            userDefaults.set(newValue, forKey: Self.appearAutomaticallyDefaultsKey)
            userDefaults.set(newValue, forKey: Self.legacyAppearAutomaticallyKey)
            trackedNamespacedAppearValue = newValue
            trackedLegacyAppearValue = newValue
            isUpdatingDefaultsInternally = false
            updatePollingState()
        }
    }

    var isPolling: Bool {
        pollTimer != nil
    }

    private(set) var lastSelection: (text: String, bounds: CGRect, bundleID: String)?

    private let userDefaults: UserDefaults
    private let selectionReader: FocusedSelectionReading
    private let isAccessibilityTrusted: () -> Bool
    private let ownBundleID: String
    private let ownProcessIdentifier: pid_t
    private let notificationCenter: NotificationCenter

    private var storedAppearAutomatically: Bool
    private var trackedNamespacedAppearValue: Bool?
    private var trackedLegacyAppearValue: Bool?
    private var isUpdatingDefaultsInternally = false
    private var isStarted = false
    private var didReportPermissionMissing = false
    private var lastObservedText = ""
    private var lastObservedBundleID = ""
    private var pollTimer: Timer?
    private var trustRetryTimer: Timer?
    private var activityToken: NSObjectProtocol?
    private var defaultsObserver: NSObjectProtocol?
    private var accessibilityObserver: NSObjectProtocol?
    private var workspaceActivateObserver: NSObjectProtocol?
    private var appBecomeActiveObserver: NSObjectProtocol?
    private var globalMouseDownMonitor: Any?
    private var globalMouseUpMonitor: Any?
    private var mouseDownScreenLocation: NSPoint?

    init(
        userDefaults: UserDefaults = .standard,
        selectionReader: FocusedSelectionReading = AccessibilityFocusedElementClient(),
        isAccessibilityTrusted: @escaping () -> Bool = { AXIsProcessTrusted() },
        ownBundleID: String? = Bundle.main.bundleIdentifier,
        ownProcessIdentifier: pid_t = ProcessInfo.processInfo.processIdentifier,
        notificationCenter: NotificationCenter = .default,
        onSelection: ((String, CGRect, String) -> Void)? = nil,
        onPermissionMissing: (() -> Void)? = nil
    ) {
        self.userDefaults = userDefaults
        self.selectionReader = selectionReader
        self.isAccessibilityTrusted = isAccessibilityTrusted
        self.ownBundleID = (ownBundleID?.isEmpty == false ? ownBundleID! : Self.fallbackOwnBundleID)
        self.ownProcessIdentifier = ownProcessIdentifier
        self.notificationCenter = notificationCenter
        self.onSelection = onSelection
        self.onPermissionMissing = onPermissionMissing

        let namespacedVal = Self.readBoolValue(from: userDefaults, forKey: Self.appearAutomaticallyDefaultsKey)
        let legacyVal = Self.readBoolValue(from: userDefaults, forKey: Self.legacyAppearAutomaticallyKey)
        self.trackedNamespacedAppearValue = namespacedVal
        self.trackedLegacyAppearValue = legacyVal
        self.storedAppearAutomatically = namespacedVal ?? legacyVal ?? true

        self.defaultsObserver = notificationCenter.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: userDefaults,
            queue: .main
        ) { [weak self] _ in
            self?.syncAppearAutomaticallyFromDefaults()
        }

        self.accessibilityObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.accessibility.api"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updatePollingState()
            for delay in [0.25, 1.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.updatePollingState()
                }
            }
        }

        self.workspaceActivateObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.isStarted, self.storedAppearAutomatically, !self.isPolling else { return }
            self.updatePollingState()
        }

        self.appBecomeActiveObserver = notificationCenter.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.isStarted, self.storedAppearAutomatically, !self.isPolling else { return }
            self.updatePollingState()
        }
    }

    deinit {
        stopPolling()
        stopTrustRetryTimer()
        if let defaultsObserver {
            notificationCenter.removeObserver(defaultsObserver)
        }
        if let accessibilityObserver {
            DistributedNotificationCenter.default().removeObserver(accessibilityObserver)
        }
        if let workspaceActivateObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceActivateObserver)
        }
        if let appBecomeActiveObserver {
            notificationCenter.removeObserver(appBecomeActiveObserver)
        }
    }

    func start() {
        isStarted = true
        syncAppearAutomaticallyFromDefaults()
        updatePollingState()
    }

    func stop() {
        isStarted = false
        stopPolling()
        stopTrustRetryTimer()
    }

    func pollOnce() {
        guard storedAppearAutomatically else {
            stopPolling()
            stopTrustRetryTimer()
            return
        }

        guard isAccessibilityTrusted() else {
            stopPolling()
            startTrustRetryIfNeeded()
            reportPermissionMissingIfNeeded()
            return
        }

        didReportPermissionMissing = false
        stopTrustRetryTimer()

        switch selectionReader.readFocusedSelection() {
        case .noSelection(let bundleID, let pid):
            if isSelfOrExcluded(bundleID: bundleID, processIdentifier: pid) {
                return
            }
            lastObservedText = ""
            lastObservedBundleID = ""

        case .selection(let current):
            if isSelfOrExcluded(bundleID: current.bundleID, processIdentifier: current.processIdentifier) {
                return
            }

            guard !current.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                lastObservedText = ""
                lastObservedBundleID = ""
                return
            }

            guard current.text != lastObservedText || current.bundleID != lastObservedBundleID else {
                return
            }

            lastObservedText = current.text
            lastObservedBundleID = current.bundleID
            lastSelection = (current.text, current.bounds, current.bundleID)
            onSelection?(current.text, current.bounds, current.bundleID)
        }
    }

    func excludedBundleIDs() -> Set<String> {
        var result = Set<String>()
        for key in [Self.excludedBundleIDsDefaultsKey, Self.legacyExcludedBundlesKey] {
            for identifier in readBundleIDList(forKey: key) {
                let normalized = identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if !normalized.isEmpty {
                    result.insert(normalized)
                }
            }
        }
        return result
    }

    private func readBundleIDList(forKey key: String) -> [String] {
        if let array = userDefaults.stringArray(forKey: key) {
            return array
        }
        if let data = userDefaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            return decoded
        }
        if let rawString = userDefaults.string(forKey: key) {
            if let jsonData = rawString.data(using: .utf8),
               let decoded = try? JSONDecoder().decode([String].self, from: jsonData) {
                return decoded
            }
            return rawString.components(separatedBy: CharacterSet(charactersIn: ",\r\n"))
        }
        return []
    }

    private func isSelfOrExcluded(bundleID: String?, processIdentifier: pid_t?) -> Bool {
        if let pid = processIdentifier, pid != 0, pid == ownProcessIdentifier {
            return true
        }
        guard let rawBundleID = bundleID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawBundleID.isEmpty else {
            return false
        }
        if rawBundleID.caseInsensitiveCompare(ownBundleID) == .orderedSame {
            return true
        }
        return excludedBundleIDs().contains(rawBundleID.lowercased())
    }

    private static func readBoolValue(from defaults: UserDefaults, forKey key: String) -> Bool? {
        guard let raw = defaults.object(forKey: key) else { return nil }
        if let boolVal = raw as? Bool {
            return boolVal
        }
        if let strVal = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            switch strVal {
            case "true", "yes", "1":
                return true
            case "false", "no", "0":
                return false
            default:
                return nil
            }
        }
        return nil
    }

    private func syncAppearAutomaticallyFromDefaults() {
        guard !isUpdatingDefaultsInternally else { return }

        let newNamespaced = Self.readBoolValue(from: userDefaults, forKey: Self.appearAutomaticallyDefaultsKey)
        let newLegacy = Self.readBoolValue(from: userDefaults, forKey: Self.legacyAppearAutomaticallyKey)

        let resolved: Bool
        if newNamespaced != trackedNamespacedAppearValue {
            resolved = newNamespaced ?? newLegacy ?? true
        } else if newLegacy != trackedLegacyAppearValue {
            resolved = newLegacy ?? newNamespaced ?? true
        } else {
            resolved = newNamespaced ?? newLegacy ?? storedAppearAutomatically
        }

        trackedNamespacedAppearValue = newNamespaced
        trackedLegacyAppearValue = newLegacy

        if storedAppearAutomatically != resolved {
            storedAppearAutomatically = resolved
            updatePollingState()
        }
    }

    private func updatePollingState() {
        guard isStarted, storedAppearAutomatically else {
            stopPolling()
            stopTrustRetryTimer()
            return
        }

        guard isAccessibilityTrusted() else {
            stopPolling()
            startTrustRetryIfNeeded()
            reportPermissionMissingIfNeeded()
            return
        }

        didReportPermissionMissing = false
        stopTrustRetryTimer()
        startPollingIfNeeded()
    }

    private func startPollingIfNeeded() {
        guard pollTimer == nil else { return }
        if activityToken == nil {
            activityToken = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep,
                reason: "Monitor text selection across applications"
            )
        }
        installMouseSelectionMonitors()
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            guard (NSEvent.pressedMouseButtons & 1) == 0 else { return }
            self?.pollOnce()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        removeMouseSelectionMonitors()
        if let token = activityToken {
            ProcessInfo.processInfo.endActivity(token)
            activityToken = nil
        }
    }

    private func startTrustRetryIfNeeded() {
        guard trustRetryTimer == nil else { return }
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.isAccessibilityTrusted() {
                self.updatePollingState()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        trustRetryTimer = timer
    }

    private func stopTrustRetryTimer() {
        trustRetryTimer?.invalidate()
        trustRetryTimer = nil
    }

    private func installMouseSelectionMonitors() {
        removeMouseSelectionMonitors()

        globalMouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            self?.mouseDownScreenLocation = NSEvent.mouseLocation
        }

        globalMouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            let upLocation = NSEvent.mouseLocation
            let clickCount = event.clickCount
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isStarted, self.isPolling else { return }
                let dragDistance: CGFloat
                if let down = self.mouseDownScreenLocation {
                    dragDistance = hypot(upLocation.x - down.x, upLocation.y - down.y)
                } else {
                    dragDistance = 0
                }
                self.mouseDownScreenLocation = nil

                if clickCount >= 2 || dragDistance >= 3 {
                    self.lastObservedText = ""
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
                    guard let self, self.isStarted, self.isPolling else { return }
                    guard (NSEvent.pressedMouseButtons & 1) == 0 else { return }
                    self.pollOnce()
                }
            }
        }
    }

    private func removeMouseSelectionMonitors() {
        if let down = globalMouseDownMonitor {
            NSEvent.removeMonitor(down)
            globalMouseDownMonitor = nil
        }
        if let up = globalMouseUpMonitor {
            NSEvent.removeMonitor(up)
            globalMouseUpMonitor = nil
        }
        mouseDownScreenLocation = nil
    }

    private func reportPermissionMissingIfNeeded() {
        guard !didReportPermissionMissing else { return }
        didReportPermissionMissing = true
        onPermissionMissing?()
    }
}
