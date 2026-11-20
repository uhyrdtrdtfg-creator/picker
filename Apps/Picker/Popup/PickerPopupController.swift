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
    public static let attachedPanelGap: CGFloat = 4
    private static let escapeKeyCode: UInt16 = 53

    public let panel: PickerPopupPanel
    public let orcaPanel: PickerOrcaPanel
    public let orcaState = PickerOrcaPanelState()
    public var onAction: ((String) -> Void)?
    public var onSendToOrca: ((OrcaAgent, String, String, @escaping @MainActor (PickerOrcaLaunchOutcome) -> Void) -> Void)?
    public var preferAbove: Bool

    private let monitorStore = PopupEventMonitorStore()
    private let observerStore = PopupNotificationObserverStore()
    private var isHiding = false
    private var isOpeningOrcaPanel = false
    private var isLaunchingOrca = false
    private var currentSelectionText = ""
    private var currentSelectionRect = NSRect.zero

    public var isVisible: Bool {
        panel.isVisible
    }

    public var isOrcaPanelVisible: Bool {
        orcaPanel.isVisible
    }

    public init(
        panel: PickerPopupPanel? = nil,
        orcaPanel: PickerOrcaPanel? = nil,
        preferAbove: Bool = true,
        onAction: ((String) -> Void)? = nil
    ) {
        let resolvedPanel = panel ?? PickerPopupPanel()
        let resolvedOrcaPanel = orcaPanel ?? PickerOrcaPanel()
        self.panel = resolvedPanel
        self.orcaPanel = resolvedOrcaPanel
        self.preferAbove = preferAbove
        self.onAction = onAction

        resolvedPanel.shouldHideOnResign = { [weak self] in
            guard let self else { return true }
            return !self.isOpeningOrcaPanel && !self.orcaPanel.isVisible && !self.isLaunchingOrca
        }
        resolvedPanel.onResign = { [weak self] in
            self?.hide()
        }

        installNotificationObservers()
    }

    deinit {
        monitorStore.removeAll()
        observerStore.removeAll()
    }

    public func show(actions: [PopupAction], near rect: NSRect, selectionText: String = "") {
        guard !actions.isEmpty else {
            hide()
            return
        }

        hideOrcaPanel()
        currentSelectionText = selectionText
        currentSelectionRect = rect

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
    public func show(actions: [PickerAction], near rect: NSRect, selectionText: String = "") {
        show(actions: actions.map(PopupAction.init(pickerAction:)), near: rect, selectionText: selectionText)
    }
    #endif

    public func hide() {
        guard !isHiding else { return }
        isHiding = true
        defer { isHiding = false }

        isLaunchingOrca = false
        monitorStore.removeAll()
        hideOrcaPanel()
        if panel.isVisible {
            panel.orderOut(nil)
        }
    }

    public func showOrcaPanel(selectionText: String? = nil) {
        let resolvedSelection = selectionText ?? currentSelectionText
        guard PickerOrcaLauncher.canSend(selection: resolvedSelection) else { return }

        currentSelectionText = resolvedSelection
        isOpeningOrcaPanel = true
        defer { isOpeningOrcaPanel = false }

        if !orcaPanel.isVisible || orcaState.selectionText != resolvedSelection {
            orcaState.reset(selectionText: resolvedSelection)
        } else {
            orcaState.errorMessage = nil
        }

        let fittingSize = orcaPanel.configureContent(
            state: orcaState,
            onSelectAgent: { [weak self] agent in
                self?.handleOrcaAgentSelection(agent)
            },
            onCancel: { [weak self] in
                self?.hide()
            }
        )

        positionOrcaPanel(size: fittingSize)
        orcaPanel.orderFrontRegardless()
        orcaPanel.makeKey()
        orcaPanel.focusNoteField()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.orcaPanel.isVisible else { return }
            self.orcaPanel.focusNoteField()
        }
    }

    public static func calculateAttachedFrame(
        attachedSize: CGSize,
        popupFrame: NSRect,
        selectionBounds: NSRect,
        in visibleFrame: NSRect
    ) -> NSRect {
        let visible = visibleFrame.standardized
        let width = visible.width > 0 ? min(max(0, attachedSize.width), visible.width) : max(0, attachedSize.width)
        let height = visible.height > 0 ? min(max(0, attachedSize.height), visible.height) : max(0, attachedSize.height)

        let idealX = popupFrame.midX - (width / 2)
        let abovePopupY = popupFrame.maxY + attachedPanelGap
        let belowPopupY = popupFrame.minY - attachedPanelGap - height

        let preferredY = belowPopupY
        let alternateY = abovePopupY

        let preferredFits = preferredY >= visible.minY && (preferredY + height) <= visible.maxY
        let alternateFits = alternateY >= visible.minY && (alternateY + height) <= visible.maxY

        let unclampedY: CGFloat
        if preferredFits {
            unclampedY = preferredY
        } else if alternateFits {
            unclampedY = alternateY
        } else {
            let roomAbove = visible.maxY - popupFrame.maxY
            let roomBelow = popupFrame.minY - visible.minY
            unclampedY = roomAbove >= roomBelow ? abovePopupY : belowPopupY
        }

        let maxX = max(visible.minX, visible.maxX - width)
        let maxY = max(visible.minY, visible.maxY - height)
        let clampedX = min(max(idealX, visible.minX), maxX)
        let clampedY = min(max(unclampedY, visible.minY), maxY)
        return NSRect(x: clampedX, y: clampedY, width: width, height: height)
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
        if PopupBuiltInAction(actionID: actionID) == .sendToOrca {
            showOrcaPanel()
            return
        }
        hide()
        onAction?(actionID)
    }

    private func handleOrcaAgentSelection(_ agent: OrcaAgent) {
        let selection = orcaState.selectionText
        guard PickerOrcaLauncher.canSend(selection: selection), !orcaState.isLaunching else {
            return
        }

        orcaState.errorMessage = nil
        orcaState.isLaunching = true
        isLaunchingOrca = true
        refreshOrcaPanelFrame()

        let note = orcaState.noteText
        if let onSendToOrca {
            onSendToOrca(agent, selection, note) { [weak self] outcome in
                self?.applyOrcaLaunchOutcome(outcome)
            }
        } else {
            PickerOrcaLauncher.launch(
                agent: agent,
                selection: selection,
                note: note,
                frontDocumentPath: nil
            ) { [weak self] outcome in
                self?.applyOrcaLaunchOutcome(outcome)
            }
        }
    }

    private func applyOrcaLaunchOutcome(_ outcome: PickerOrcaLaunchOutcome) {
        isLaunchingOrca = false
        orcaState.isLaunching = false

        switch outcome {
        case .launched:
            hide()
        case .emptySelection:
            refreshOrcaPanelFrame()
        case .missingOrca:
            orcaState.errorMessage = PickerOrcaStrings.missingOrcaMessage
            DispatchQueue.main.async { [weak self] in
                self?.refreshOrcaPanelFrame()
            }
        case .failed(let firstErrorLine):
            orcaState.errorMessage = firstErrorLine
            DispatchQueue.main.async { [weak self] in
                self?.refreshOrcaPanelFrame()
            }
        }
    }

    private func hideOrcaPanel() {
        orcaState.isLaunching = false
        orcaState.errorMessage = nil
        if orcaPanel.isVisible {
            orcaPanel.orderOut(nil)
        }
    }

    private func refreshOrcaPanelFrame() {
        guard orcaPanel.isVisible else { return }
        let newSize = orcaPanel.refreshFittingSize()
        positionOrcaPanel(size: newSize)
    }

    private func positionOrcaPanel(size: CGSize) {
        let visibleFrame = Self.screenVisibleFrame(near: panel.frame)
        let attachedFrame = Self.calculateAttachedFrame(
            attachedSize: size,
            popupFrame: panel.frame,
            selectionBounds: currentSelectionRect,
            in: visibleFrame
        )
        orcaPanel.setFrame(attachedFrame, display: true)
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
                guard let self, !self.isLaunchingOrca else { return }
                self.hide()
            }
        }

        let appSwitch = workspaceCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isLaunchingOrca else { return }
                self.hide()
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
            guard let self, self.panel.isVisible || self.orcaPanel.isVisible else { return event }
            if event.keyCode == Self.escapeKeyCode {
                if self.orcaPanel.isVisible && self.orcaPanel.hasActiveMarkedText {
                    return event
                }
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
            guard let self, self.panel.isVisible || self.orcaPanel.isVisible else { return event }
            if event.window !== self.panel && event.window !== self.orcaPanel {
                self.hide()
            }
            return event
        }

        let globalMouse = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.panel.isVisible || self.orcaPanel.isVisible else { return }
                let mouse = NSEvent.mouseLocation
                let inPopup = self.panel.isVisible && self.panel.frame.contains(mouse)
                let inOrca = self.orcaPanel.isVisible && self.orcaPanel.frame.contains(mouse)
                if !inPopup && !inOrca {
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
