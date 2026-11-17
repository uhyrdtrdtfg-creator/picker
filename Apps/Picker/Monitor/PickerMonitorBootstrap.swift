import AppKit
import Foundation

@MainActor
extension SelectionMonitor {
    func bind(
        to popupController: PickerPopupController,
        actionRunner: PickerActionRunner = PickerActionRunner()
    ) {
        var currentSelectionText = ""
        var currentSelectionBounds = CGRect.zero

        popupController.onAction = { actionID in
            guard !currentSelectionText.isEmpty else { return }
            let modifiers = NSEvent.modifierFlags
            let anchor = currentSelectionBounds == .zero
                ? NSEvent.mouseLocation
                : NSPoint(x: currentSelectionBounds.midX, y: currentSelectionBounds.minY)
            _ = actionRunner.run(
                actionID: actionID,
                selection: currentSelectionText,
                modifiers: modifiers,
                anchorPoint: anchor
            )
        }

        onSelection = { text, bounds, _ in
            actionRunner.captureSelectionTarget()
            currentSelectionText = text
            currentSelectionBounds = bounds
            popupController.preferAbove = PickerMonitorBootstrap.preferredPopupAbove()
            let actions = PickerMonitorBootstrap.popupActions(for: text, using: actionRunner)
            popupController.show(actions: actions, near: bounds)
        }
    }
}

@MainActor
final class PickerMonitorBootstrap {
    static let shared = PickerMonitorBootstrap()

    let monitor: SelectionMonitor
    let popupController: PickerPopupController
    let actionRunner: PickerActionRunner

    private var didStart = false
    private var showLastSelectionObserver: NSObjectProtocol?

    init(
        monitor: SelectionMonitor? = nil,
        popupController: PickerPopupController? = nil,
        actionRunner: PickerActionRunner? = nil,
        permissionMissingHandler: (() -> Void)? = nil
    ) {
        let resolvedMonitor = monitor ?? SelectionMonitor()
        let resolvedPopup = popupController ?? PickerPopupController()
        let resolvedRunner = actionRunner ?? PickerActionRunner()

        self.monitor = resolvedMonitor
        self.popupController = resolvedPopup
        self.actionRunner = resolvedRunner

        resolvedMonitor.bind(to: resolvedPopup, actionRunner: resolvedRunner)
        resolvedMonitor.onPermissionMissing = permissionMissingHandler ?? {
            Self.presentAccessibilityPermissionPrompt()
        }

        showLastSelectionObserver = NotificationCenter.default.addObserver(
            forName: .pickerShowLastSelection,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.showLastSelection()
            }
        }
    }

    deinit {
        if let showLastSelectionObserver {
            NotificationCenter.default.removeObserver(showLastSelectionObserver)
        }
    }

    func start() {
        guard !didStart else { return }
        didStart = true

        if NSApp != nil && NSApp.isRunning {
            monitor.start()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.monitor.start()
            }
        }
    }

    func showLastSelection() {
        guard let last = monitor.lastSelection, !last.text.isEmpty else { return }
        let actions = Self.popupActions(for: last.text, using: actionRunner)
        popupController.show(actions: actions, near: last.bounds)
    }

    static func popupActions(for selection: String, using runner: PickerActionRunner) -> [PopupAction] {
        var actions: [PopupAction] = [.copy, .cut, .paste]

        let trimmed = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && trimmed.count <= 200 {
            actions.append(.search)
        }

        let urls = PickerActionRunner.extractHTTPURLs(from: selection)
        if !urls.isEmpty {
            let linkTitle = urls.count > 1 ? "Open Links" : PopupBuiltInAction.openLink.shortTitle
            actions.append(
                PopupAction(
                    id: PopupBuiltInAction.openLink.rawValue,
                    title: linkTitle,
                    symbolName: PopupBuiltInAction.openLink.symbolName
                )
            )
        }

        if PickerActionRunner.hasSystemDefinition(for: trimmed) {
            actions.append(.dictionary)
        }

        if runner.hasExistingFile(in: selection) {
            actions.append(.reveal)
        }

        if isCandidateSpellingWord(trimmed),
           runner.isWordMisspelled(trimmed),
           !runner.spellingGuesses(for: trimmed).isEmpty {
            actions.append(.spelling)
        }

        return actions
    }

    static func preferredPopupAbove(from defaults: UserDefaults = .standard) -> Bool {
        if let explicit = defaults.object(forKey: "picker.preferAbove") as? Bool {
            return explicit
        }
        if let position = defaults.string(forKey: "popupPosition")?.lowercased() {
            return position != "below"
        }
        return true
    }

    private static let allowedSpellingWords: Set<String> = ["pilotmoon", "popclip", "picker"]

    private static func isCandidateSpellingWord(_ trimmed: String) -> Bool {
        guard (3...400).contains(trimmed.count) else { return false }
        guard !allowedSpellingWords.contains(trimmed.lowercased()) else { return false }
        if trimmed.contains(where: { $0.isWhitespace || $0 == "/" || $0 == ":" || $0 == "_" }) {
            return false
        }
        var previousWasLowercase = false
        for character in trimmed {
            if previousWasLowercase && character.isUppercase {
                return false
            }
            previousWasLowercase = character.isLowercase
        }
        return true
    }

    private static func presentAccessibilityPermissionPrompt() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = AccessibilityPermission.requiredHeadline
        alert.informativeText = AccessibilityPermission.explanationText
        alert.addButton(withTitle: AccessibilityPermission.openSettingsButtonTitle)
        alert.addButton(withTitle: "Not Now")

        if alert.runModal() == .alertFirstButtonReturn {
            AccessibilityPermission.openSystemSettings()
        }
    }
}
