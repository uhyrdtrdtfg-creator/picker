import AppKit
import Foundation

#if canImport(PickerCore)
import PickerCore
#endif

#if canImport(PickerActions)
import PickerActions
#endif

@MainActor
public final class PickerPopupController {
    public static let verticalGap: CGFloat = PopupPlacement.gap
    private static let escapeKeyCode: UInt16 = 53

    public let panel: PickerPopupPanel
    public var onAction: ((String) -> Void)?
    public var preferAbove: Bool

    private let monitorStore = PopupEventMonitorStore()
    private let observerStore = PopupNotificationObserverStore()
    private var isHiding = false

    public var isVisible: Bool {
        panel.isVisible
    }

    public init(
        panel: PickerPopupPanel? = nil,
        preferAbove: Bool = true,
        onAction: ((String) -> Void)? = nil
    ) {
        let resolvedPanel = panel ?? PickerPopupPanel()
        self.panel = resolvedPanel
        self.preferAbove = preferAbove
        self.onAction = onAction

        resolvedPanel.onResign = { [weak self] in
            self?.hide()
        }

        installNotificationObservers()
    }

    deinit {
        monitorStore.removeAll()
        observerStore.removeAll()
    }

    public func show(actions: [PopupAction], near rect: NSRect) {
        guard !actions.isEmpty else {
            hide()
            return
        }

        let popupSize = panel.setActions(actions) { [weak self] actionID in
            self?.handleActionSelection(actionID)
        }

        let visibleFrame = Self.screenVisibleFrame(near: rect)
        let targetFrame = Self.calculateFrame(
            popupSize: popupSize,
            near: rect,
            in: visibleFrame,
            preferAbove: preferAbove
        )

        panel.setFrame(targetFrame, display: true)
        installEventMonitors()
        panel.orderFrontRegardless()
    }

    #if canImport(PickerActions)
    public func show(actions: [PickerAction], near rect: NSRect) {
        show(actions: actions.map(PopupAction.init(pickerAction:)), near: rect)
    }
    #endif

    public func hide() {
        guard !isHiding else { return }
        isHiding = true
        defer { isHiding = false }

        monitorStore.removeAll()
        if panel.isVisible {
            panel.orderOut(nil)
        }
    }

    public static func calculateFrame(
        popupSize: CGSize,
        near rect: NSRect,
        in visibleFrame: NSRect,
        preferAbove: Bool = true
    ) -> NSRect {
        PopupPlacement.place(
            selectionBounds: rect,
            screenVisible: visibleFrame,
            preferAbove: preferAbove,
            popupSize: popupSize
        )
    }

    private func handleActionSelection(_ actionID: String) {
        hide()
        onAction?(actionID)
    }

    private func installNotificationObservers() {
        let appCenter = NotificationCenter.default
        let workspaceCenter = NSWorkspace.shared.notificationCenter

        let resignActive = appCenter.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.hide()
            }
        }

        let appSwitch = workspaceCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.hide()
            }
        }

        let spaceSwitch = workspaceCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.hide()
            }
        }

        observerStore.store([
            (appCenter, resignActive),
            (workspaceCenter, appSwitch),
            (workspaceCenter, spaceSwitch)
        ])
    }

    private func installEventMonitors() {
        monitorStore.removeAll()

        let localKey = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isVisible else { return event }
            if event.keyCode == Self.escapeKeyCode {
                self.hide()
                return nil
            }
            return event
        }

        let globalKey = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == Self.escapeKeyCode else { return }
            Task { @MainActor [weak self] in
                self?.hide()
            }
        }

        let localMouse = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            guard let self, self.panel.isVisible else { return event }
            if event.window !== self.panel {
                self.hide()
            }
            return event
        }

        let globalMouse = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.panel.isVisible else { return }
                if !self.panel.frame.contains(NSEvent.mouseLocation) {
                    self.hide()
                }
            }
        }

        monitorStore.store([localKey, globalKey, localMouse, globalMouse].compactMap { $0 })
    }

    private static func screenVisibleFrame(near rect: NSRect) -> NSRect {
        let screens = NSScreen.screens
        let midpoint = CGPoint(x: rect.midX, y: rect.midY)

        if let containingScreen = screens.first(where: { $0.frame.contains(midpoint) }) {
            return containingScreen.visibleFrame
        }

        var bestScreen: NSScreen?
        var largestArea: CGFloat = 0
        for screen in screens {
            let intersection = screen.frame.intersection(rect)
            if !intersection.isNull {
                let area = intersection.width * intersection.height
                if area > largestArea {
                    largestArea = area
                    bestScreen = screen
                }
            }
        }
        if let bestScreen {
            return bestScreen.visibleFrame
        }

        let mousePoint = NSEvent.mouseLocation
        if let mouseScreen = screens.first(where: { $0.frame.contains(mousePoint) }) {
            return mouseScreen.visibleFrame
        }

        return NSScreen.main?.visibleFrame
            ?? screens.first?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }
}

private final class PopupEventMonitorStore: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [Any] = []

    func store(_ newTokens: [Any]) {
        lock.lock()
        tokens = newTokens
        lock.unlock()
    }

    func removeAll() {
        lock.lock()
        let existing = tokens
        tokens.removeAll()
        lock.unlock()

        for token in existing {
            NSEvent.removeMonitor(token)
        }
    }
}

private final class PopupNotificationObserverStore: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(NotificationCenter, NSObjectProtocol)] = []

    func store(_ newEntries: [(NotificationCenter, NSObjectProtocol)]) {
        lock.lock()
        entries = newEntries
        lock.unlock()
    }

    func removeAll() {
        lock.lock()
        let existing = entries
        entries.removeAll()
        lock.unlock()

        for (center, observer) in existing {
            center.removeObserver(observer)
        }
    }
}
