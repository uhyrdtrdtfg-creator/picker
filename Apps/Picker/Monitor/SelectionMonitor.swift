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
    private var pollTimer: Timer?
    private var defaultsObserver: NSObjectProtocol?
    private var accessibilityObserver: NSObjectProtocol?

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

        let namespacedVal = userDefaults.object(forKey: Self.appearAutomaticallyDefaultsKey) as? Bool
        let legacyVal = userDefaults.object(forKey: Self.legacyAppearAutomaticallyKey) as? Bool
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.updatePollingState()
            }
        }
    }

    deinit {
        stopPolling()
        if let defaultsObserver {
            notificationCenter.removeObserver(defaultsObserver)
        }
        if let accessibilityObserver {
            DistributedNotificationCenter.default().removeObserver(accessibilityObserver)
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
    }

    func pollOnce() {
        guard storedAppearAutomatically else {
            stopPolling()
            return
        }

        guard isAccessibilityTrusted() else {
            stopPolling()
            reportPermissionMissingIfNeeded()
            return
        }

        didReportPermissionMissing = false

        switch selectionReader.readFocusedSelection() {
        case .noSelection(let bundleID, let pid):
            if isSelfOrExcluded(bundleID: bundleID, processIdentifier: pid) {
                return
            }
            lastObservedText = ""

        case .selection(let current):
            if isSelfOrExcluded(bundleID: current.bundleID, processIdentifier: current.processIdentifier) {
                return
            }

            guard !current.text.isEmpty else {
                lastObservedText = ""
                return
            }

            guard current.text != lastObservedText else {
                return
            }

            lastObservedText = current.text
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

    private func syncAppearAutomaticallyFromDefaults() {
        guard !isUpdatingDefaultsInternally else { return }

        let newNamespaced = userDefaults.object(forKey: Self.appearAutomaticallyDefaultsKey) as? Bool
        let newLegacy = userDefaults.object(forKey: Self.legacyAppearAutomaticallyKey) as? Bool

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
            return
        }

        guard isAccessibilityTrusted() else {
            stopPolling()
            reportPermissionMissingIfNeeded()
            return
        }

        didReportPermissionMissing = false
        startPollingIfNeeded()
    }

    private func startPollingIfNeeded() {
        guard pollTimer == nil else { return }
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            self?.pollOnce()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func reportPermissionMissingIfNeeded() {
        guard !didReportPermissionMissing else { return }
        didReportPermissionMissing = true
        onPermissionMissing?()
    }
}
