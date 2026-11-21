import AppKit
import SwiftUI

private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

@MainActor
public final class PickerPopupPanel: NSPanel {
    public var onResign: (() -> Void)?
    public var shouldHideOnResign: (() -> Bool)?

    private var hostingView: FirstMouseHostingView<PickerPopupView>?
    private var isPerformingResignHide = false

    public init(contentRect: NSRect = NSRect(x: 0, y: 0, width: 120, height: 30)) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        configurePanel()
    }

    public override var canBecomeKey: Bool {
        true
    }

    public override var canBecomeMain: Bool {
        false
    }

    public override func resignKey() {
        super.resignKey()
        hideForResign()
    }

    public override func resignMain() {
        super.resignMain()
        hideForResign()
    }

    public override func cancelOperation(_ sender: Any?) {
        hideForResign()
    }

    @discardableResult
    public func setActions(
        _ actions: [PopupAction],
        onAction: @escaping (String) -> Void
    ) -> CGSize {
        let popupView = PickerPopupView(actions: actions, onAction: onAction)
        let host: FirstMouseHostingView<PickerPopupView>
        if let existing = hostingView {
            existing.rootView = popupView
            host = existing
        } else {
            let created = FirstMouseHostingView(rootView: popupView)
            contentView = created
            hostingView = created
            host = created
        }

        host.invalidateIntrinsicContentSize()
        host.layoutSubtreeIfNeeded()
        let fittingSize = host.fittingSize
        setContentSize(fittingSize)
        return fittingSize
    }

    private func configurePanel() {
        isFloatingPanel = true
        level = .popUpMenu
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        appearance = nil
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        animationBehavior = .utilityWindow
    }

    private func hideForResign() {
        guard shouldHideOnResign?() ?? true else { return }
        guard !isPerformingResignHide else { return }
        isPerformingResignHide = true
        defer { isPerformingResignHide = false }
        orderOut(nil)
        onResign?()
    }
}
