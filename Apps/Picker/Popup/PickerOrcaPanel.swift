import AppKit
import SwiftUI

private final class OrcaFirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

final class FirstMouseNoteTextField: NSTextField {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

@MainActor
public final class PickerOrcaPanelState: ObservableObject {
    @Published public var selectionText: String = ""
    @Published public var noteText: String = ""
    @Published public var errorMessage: String?
    @Published public var isLaunching: Bool = false
    @Published public var isOrcaAvailable: Bool = true

    public init() {}

    public var canSend: Bool {
        PickerOrcaLauncher.canSend(selection: selectionText) && isOrcaAvailable && !isLaunching
    }

    public func reset(selectionText: String, isOrcaAvailable: Bool = true) {
        self.selectionText = selectionText
        self.noteText = ""
        self.isOrcaAvailable = isOrcaAvailable
        self.errorMessage = isOrcaAvailable ? nil : PickerOrcaStrings.missingOrcaMessage
        self.isLaunching = false
    }

    public func updateOrcaAvailability(_ isAvailable: Bool) {
        self.isOrcaAvailable = isAvailable
        if !isAvailable {
            self.errorMessage = PickerOrcaStrings.missingOrcaMessage
        } else if self.errorMessage == PickerOrcaStrings.missingOrcaMessage {
            self.errorMessage = nil
        }
    }
}

@MainActor
public final class PickerOrcaPanel: NSPanel {
    public var onCancel: (() -> Void)?

    private var hostingView: OrcaFirstMouseHostingView<PickerOrcaView>?

    public init(contentRect: NSRect = NSRect(x: 0, y: 0, width: 266, height: 80)) {
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

    public override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, let chars = event.charactersIgnoringModifiers?.lowercased() {
            switch chars {
            case "a":
                if NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: self) {
                    return true
                }
            case "c":
                if NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: self) {
                    return true
                }
            case "v":
                if NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: self) {
                    return true
                }
            case "x":
                if NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: self) {
                    return true
                }
            case "z":
                if NSApp.sendAction(Selector(("undo:")), to: nil, from: self) {
                    return true
                }
            default:
                break
            }
        } else if flags == [.command, .shift],
                  event.charactersIgnoringModifiers?.lowercased() == "z" {
            if NSApp.sendAction(Selector(("redo:")), to: nil, from: self) {
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    @discardableResult
    public func configureContent(
        state: PickerOrcaPanelState,
        onSelectAgent: @escaping (OrcaAgent) -> Void,
        onCancel: @escaping () -> Void
    ) -> CGSize {
        self.onCancel = onCancel
        let view = PickerOrcaView(
            state: state,
            onSelectAgent: onSelectAgent,
            onCancel: onCancel
        )
        let host: OrcaFirstMouseHostingView<PickerOrcaView>
        if let existing = hostingView {
            existing.rootView = view
            host = existing
        } else {
            let created = OrcaFirstMouseHostingView(rootView: view)
            contentView = created
            hostingView = created
            host = created
        }

        return refreshFittingSize(using: host)
    }

    @discardableResult
    public func refreshFittingSize() -> CGSize {
        guard let host = hostingView else {
            return frame.size
        }
        return refreshFittingSize(using: host)
    }

    public var hasActiveMarkedText: Bool {
        (firstResponder as? NSTextView)?.hasMarkedText() == true
    }

    public func commitAndReadNoteText(fallback: String) -> String {
        guard let root = contentView,
              let noteField = Self.findNoteTextField(in: root) else {
            return fallback
        }
        if let editor = noteField.currentEditor() as? NSTextView {
            if editor.hasMarkedText() {
                editor.unmarkText()
            }
            let editorText = editor.string
            if noteField.stringValue != editorText {
                noteField.stringValue = editorText
            }
            return editorText
        }
        return noteField.stringValue
    }

    public func focusNoteField() {
        guard let root = contentView,
              let noteField = Self.findNoteTextField(in: root) else {
            return
        }
        if let editor = firstResponder as? NSTextView,
           editor.delegate === noteField {
            return
        }
        if makeFirstResponder(noteField),
           let editor = noteField.currentEditor() as? NSTextView {
            let endLocation = (noteField.stringValue as NSString).length
            editor.selectedRange = NSRange(location: endLocation, length: 0)
        }
    }

    private func refreshFittingSize(using host: OrcaFirstMouseHostingView<PickerOrcaView>) -> CGSize {
        host.invalidateIntrinsicContentSize()
        host.layoutSubtreeIfNeeded()
        let fitting = host.fittingSize
        setContentSize(fitting)
        return fitting
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
        becomesKeyOnlyIfNeeded = false
        appearance = nil
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        animationBehavior = .utilityWindow
    }

    private static func findNoteTextField(in view: NSView) -> FirstMouseNoteTextField? {
        if let match = view as? FirstMouseNoteTextField {
            return match
        }
        for subview in view.subviews {
            if let found = findNoteTextField(in: subview) {
                return found
            }
        }
        return nil
    }
}

public struct PickerOrcaView: View {
    public static let panelWidth: CGFloat = PickerStyle.orcaPanelWidth
    public static let panelPadding: CGFloat = PickerStyle.orcaPanelPadding
    public static let agentRowHeight: CGFloat = PickerStyle.orcaControlHeight
    public static let noteFieldHeight: CGFloat = PickerStyle.orcaControlHeight
    public static let cornerRadius: CGFloat = PickerStyle.cornerRadius

    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var state: PickerOrcaPanelState
    let onSelectAgent: (OrcaAgent) -> Void
    let onCancel: () -> Void

    public init(
        state: PickerOrcaPanelState,
        onSelectAgent: @escaping (OrcaAgent) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.state = state
        self.onSelectAgent = onSelectAgent
        self.onCancel = onCancel
    }

    private var singleLineErrorMessage: String? {
        guard let raw = state.errorMessage else {
            return nil
        }
        let collapsed = raw
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed.isEmpty ? nil : collapsed
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            OrcaNoteTextField(
                text: $state.noteText,
                placeholder: PickerOrcaStrings.noteFieldLabel,
                isEnabled: !state.isLaunching,
                onCancel: onCancel
            )
            .frame(maxWidth: .infinity)
            .frame(height: Self.noteFieldHeight)
            .background(PickerStyle.surfaceColor(for: colorScheme))
            .clipShape(RoundedRectangle(cornerRadius: PickerStyle.controlCornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: PickerStyle.controlCornerRadius, style: .continuous)
                    .strokeBorder(PickerStyle.borderColor(for: colorScheme), lineWidth: PickerStyle.borderWidth)
            )

            if let errorMessage = singleLineErrorMessage {
                Text(errorMessage)
                    .font(.system(size: PickerStyle.captionSize))
                    .foregroundColor(PickerStyle.errorColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 0) {
                ForEach(Array(OrcaAgent.allCases.enumerated()), id: \.element.id) { index, agent in
                    if index > 0 {
                        Rectangle()
                            .fill(PickerStyle.borderColor(for: colorScheme))
                            .frame(width: PickerStyle.dividerThickness)
                    }

                    OrcaAgentButton(
                        title: agent.buttonTitle,
                        isEnabled: state.canSend,
                        hoverColor: PickerStyle.hoverColor(for: colorScheme),
                        pressedColor: PickerStyle.pressedColor(for: colorScheme)
                    ) {
                        onSelectAgent(agent)
                    }
                }
            }
            .frame(height: Self.agentRowHeight)
            .background(PickerStyle.surfaceColor(for: colorScheme))
            .clipShape(RoundedRectangle(cornerRadius: PickerStyle.controlCornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: PickerStyle.controlCornerRadius, style: .continuous)
                    .strokeBorder(PickerStyle.borderColor(for: colorScheme), lineWidth: PickerStyle.borderWidth)
            )
        }
        .padding(Self.panelPadding)
        .frame(width: Self.panelWidth)
        .background(PickerStyle.surfaceColor(for: colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .strokeBorder(PickerStyle.borderColor(for: colorScheme), lineWidth: PickerStyle.borderWidth)
        )
        .shadow(
            color: PickerStyle.shadowColor(for: colorScheme),
            radius: PickerStyle.shadowRadius,
            x: 0,
            y: PickerStyle.shadowOffsetY
        )
        .padding(PickerStyle.floatingShadowInsets)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct OrcaAgentButton: View {
    let title: String
    let isEnabled: Bool
    let hoverColor: Color
    let pressedColor: Color
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: PickerStyle.bodySize, weight: .medium))
                .lineLimit(1)
                .foregroundColor(isEnabled ? .primary : .secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(
            OrcaAgentButtonStyle(
                isEnabled: isEnabled,
                isHovered: isHovered,
                hoverColor: hoverColor,
                pressedColor: pressedColor
            )
        )
        .disabled(!isEnabled)
        .onHover { hovering in
            isHovered = hovering
        }
        .accessibilityLabel(Text(title))
    }
}

private struct OrcaAgentButtonStyle: ButtonStyle {
    let isEnabled: Bool
    let isHovered: Bool
    let hoverColor: Color
    let pressedColor: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(fillColor(isPressed: configuration.isPressed))
    }

    private func fillColor(isPressed: Bool) -> Color {
        guard isEnabled else { return .clear }
        if isPressed {
            return pressedColor
        }
        if isHovered {
            return hoverColor
        }
        return .clear
    }
}

private final class FirstMouseNoteFieldContainerView: NSView {
    let textField: FirstMouseNoteTextField

    init(textField: FirstMouseNoteTextField) {
        self.textField = textField
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        textField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textField)
        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            textField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            textField.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        guard textField.isEnabled else {
            super.mouseDown(with: event)
            return
        }
        window?.makeFirstResponder(textField)
    }
}

private struct OrcaNoteTextField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let isEnabled: Bool
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> FirstMouseNoteFieldContainerView {
        let field = FirstMouseNoteTextField(frame: .zero)
        field.delegate = context.coordinator
        field.isEditable = true
        field.isSelectable = true
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.textColor = .labelColor
        field.focusRingType = .none
        field.font = .systemFont(ofSize: PickerStyle.bodySize)
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        applyPlaceholder(placeholder, to: field)
        field.setAccessibilityLabel(placeholder)
        field.stringValue = text
        field.isEnabled = isEnabled
        return FirstMouseNoteFieldContainerView(textField: field)
    }

    func updateNSView(_ nsView: FirstMouseNoteFieldContainerView, context: Context) {
        context.coordinator.parent = self
        let field = nsView.textField
        applyPlaceholder(placeholder, to: field)
        field.setAccessibilityLabel(placeholder)
        field.isEnabled = isEnabled
        if let editor = field.currentEditor() as? NSTextView {
            editor.insertionPointColor = .labelColor
        }
        let hasMarked = (field.currentEditor() as? NSTextView)?.hasMarkedText() == true
        if !hasMarked && field.stringValue != text {
            field.stringValue = text
        }
    }

    private func applyPlaceholder(_ string: String, to field: NSTextField) {
        field.placeholderAttributedString = NSAttributedString(
            string: string,
            attributes: [
                .font: NSFont.systemFont(ofSize: PickerStyle.bodySize),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
        )
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: OrcaNoteTextField

        init(_ parent: OrcaNoteTextField) {
            self.parent = parent
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            if let field = obj.object as? NSTextField,
               let editor = field.currentEditor() as? NSTextView {
                editor.insertionPointColor = .labelColor
            }
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                parent.onCancel()
                return true
            }
            return false
        }
    }
}
