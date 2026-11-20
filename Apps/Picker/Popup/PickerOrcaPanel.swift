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

    public init() {}

    public var canSend: Bool {
        PickerOrcaLauncher.canSend(selection: selectionText) && !isLaunching
    }

    public func reset(selectionText: String) {
        self.selectionText = selectionText
        self.noteText = ""
        self.errorMessage = nil
        self.isLaunching = false
    }
}

@MainActor
public final class PickerOrcaPanel: NSPanel {
    public var onCancel: (() -> Void)?

    private var hostingView: OrcaFirstMouseHostingView<PickerOrcaView>?

    public init(contentRect: NSRect = NSRect(x: 0, y: 0, width: PickerOrcaView.panelWidth, height: 96)) {
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
        let size = CGSize(width: PickerOrcaView.panelWidth, height: ceil(fitting.height))
        setContentSize(size)
        invalidateShadow()
        return size
    }

    private func configurePanel() {
        isFloatingPanel = true
        level = .popUpMenu
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = false
        appearance = NSAppearance(named: .aqua)
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
    public static let panelWidth: CGFloat = 280
    public static let panelPadding: CGFloat = 8
    public static let cornerRadius: CGFloat = 8
    public static let agentRowHeight: CGFloat = 28
    public static let maxPreviewCharacters: Int = 80

    private static let surfaceBackgroundColor = Color.white
    private static let borderColor = Color.black.opacity(0.14)
    private static let dividerColor = Color.black.opacity(0.09)
    private static let primaryTextColor = Color(red: 0.11, green: 0.12, blue: 0.14)
    private static let secondaryTextColor = Color(red: 0.42, green: 0.44, blue: 0.48)
    private static let errorTextColor = Color(red: 0.80, green: 0.16, blue: 0.16)
    private static let buttonHoverColor = Color(red: 0.94, green: 0.95, blue: 0.97)
    private static let buttonPressedColor = Color(red: 0.89, green: 0.90, blue: 0.93)

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

    private var previewText: String {
        Self.compactSingleLinePreview(state.selectionText)
    }

    private var errorText: String? {
        guard let raw = state.errorMessage else { return nil }
        let singleLine = raw
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return singleLine.isEmpty ? nil : singleLine
    }

    public static func compactSingleLinePreview(_ selection: String) -> String {
        let collapsed = selection
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return PickerOrcaLauncher.displaySelectionPreview(collapsed, maxCharacters: maxPreviewCharacters)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !previewText.isEmpty {
                Text(previewText)
                    .font(.system(size: 11))
                    .foregroundColor(Self.secondaryTextColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 2)
            }

            OrcaNoteTextField(
                text: $state.noteText,
                placeholder: PickerOrcaStrings.noteFieldLabel,
                isEnabled: !state.isLaunching,
                onCancel: onCancel
            )
            .frame(maxWidth: .infinity)
            .frame(height: 24)

            if let errorText {
                Text(errorText)
                    .font(.system(size: 11))
                    .foregroundColor(Self.errorTextColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 2)
            }

            HStack(spacing: 0) {
                ForEach(Array(OrcaAgent.allCases.enumerated()), id: \.element.id) { index, agent in
                    if index > 0 {
                        Rectangle()
                            .fill(Self.dividerColor)
                            .frame(width: 1)
                    }

                    OrcaAgentButton(
                        title: agent.buttonTitle,
                        isEnabled: state.canSend,
                        textColor: Self.primaryTextColor,
                        hoverColor: Self.buttonHoverColor,
                        pressedColor: Self.buttonPressedColor
                    ) {
                        onSelectAgent(agent)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: Self.agentRowHeight)
            .background(Self.surfaceBackgroundColor)
            .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                    .strokeBorder(Self.borderColor, lineWidth: 0.75)
            )
            .overlay(alignment: .trailing) {
                if state.isLaunching {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.75)
                        .padding(.trailing, 6)
                }
            }
        }
        .padding(Self.panelPadding)
        .frame(width: Self.panelWidth)
        .background(Self.surfaceBackgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .strokeBorder(Self.borderColor, lineWidth: 0.75)
        )
        .fixedSize(horizontal: false, vertical: true)
        .environment(\.colorScheme, .light)
    }
}

private struct OrcaAgentButton: View {
    let title: String
    let isEnabled: Bool
    let textColor: Color
    let hoverColor: Color
    let pressedColor: Color
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(isEnabled ? textColor : textColor.opacity(0.4))
                .lineLimit(1)
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

private struct OrcaNoteTextField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let isEnabled: Bool
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> FirstMouseNoteTextField {
        let field = FirstMouseNoteTextField(frame: .zero)
        field.delegate = context.coordinator
        field.placeholderString = placeholder
        field.isEditable = true
        field.isSelectable = true
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.focusRingType = .exterior
        field.drawsBackground = true
        field.backgroundColor = .white
        field.textColor = NSColor(red: 0.11, green: 0.12, blue: 0.14, alpha: 1)
        field.appearance = NSAppearance(named: .aqua)
        field.font = .systemFont(ofSize: 12)
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setAccessibilityLabel(placeholder)
        field.stringValue = text
        field.isEnabled = isEnabled
        return field
    }

    func updateNSView(_ nsView: FirstMouseNoteTextField, context: Context) {
        context.coordinator.parent = self
        if nsView.placeholderString != placeholder {
            nsView.placeholderString = placeholder
            nsView.setAccessibilityLabel(placeholder)
        }
        if nsView.isEnabled != isEnabled {
            nsView.isEnabled = isEnabled
        }
        let hasMarkedText = (nsView.currentEditor() as? NSTextView)?.hasMarkedText() ?? false
        if !hasMarkedText && nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: OrcaNoteTextField

        init(_ parent: OrcaNoteTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            if parent.text != field.stringValue {
                parent.text = field.stringValue
            }
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
