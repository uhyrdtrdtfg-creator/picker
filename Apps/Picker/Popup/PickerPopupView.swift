import SwiftUI

public struct PickerPopupView: View {
    public static let buttonSize: CGFloat = PickerStyle.popupButtonSize
    public static let minimumButtonHeight: CGFloat = PickerStyle.popupButtonSize
    public static let symbolSize: CGFloat = PickerStyle.popupSymbolSize

    @Environment(\.colorScheme) private var colorScheme

    public let actions: [PopupAction]
    public let onAction: (String) -> Void

    public init(
        actions: [PopupAction],
        onAction: @escaping (String) -> Void
    ) {
        self.actions = actions
        self.onAction = onAction
    }

    public var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                if Self.shouldShowDivider(before: index, in: actions) {
                    Rectangle()
                        .fill(PickerStyle.borderColor(for: colorScheme))
                        .frame(width: PickerStyle.dividerThickness, height: 16)
                        .padding(.horizontal, 1)
                }

                PopupActionButton(
                    title: Self.resolvedTitle(for: action),
                    symbolName: Self.resolvedSymbolName(for: action),
                    size: Self.buttonSize,
                    symbolSize: Self.symbolSize,
                    hoverColor: PickerStyle.hoverColor(for: colorScheme),
                    pressedColor: PickerStyle.pressedColor(for: colorScheme)
                ) {
                    onAction(action.id)
                }
            }
        }
        .padding(1)
        .background(PickerStyle.surfaceColor(for: colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: PickerStyle.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: PickerStyle.cornerRadius, style: .continuous)
                .strokeBorder(PickerStyle.borderColor(for: colorScheme), lineWidth: PickerStyle.borderWidth)
        )
        .shadow(
            color: PickerStyle.shadowColor(for: colorScheme),
            radius: PickerStyle.shadowRadius,
            x: 0,
            y: PickerStyle.shadowOffsetY
        )
        .padding(PickerStyle.floatingShadowInsets)
        .fixedSize()
    }

    public static func actionGroup(for action: PopupAction) -> PopupActionGroup {
        PopupBuiltInAction(actionID: action.id)?.group ?? .lookup
    }

    public static func shouldShowDivider(before index: Int, in actions: [PopupAction]) -> Bool {
        guard index > 0, index < actions.count else {
            return false
        }
        return actionGroup(for: actions[index - 1]) != actionGroup(for: actions[index])
    }

    public static func resolvedTitle(for action: PopupAction) -> String {
        if let builtIn = PopupBuiltInAction(actionID: action.id), action.title.isEmpty || action.title == action.id {
            return builtIn.shortTitle
        }
        if !action.title.isEmpty {
            return action.title
        }
        return action.id
    }

    public static func resolvedSymbolName(for action: PopupAction) -> String {
        if !action.symbolName.isEmpty && action.symbolName != "circle" {
            return action.symbolName
        }
        if let builtIn = PopupBuiltInAction(actionID: action.id) {
            return builtIn.symbolName
        }
        return action.symbolName.isEmpty ? "circle" : action.symbolName
    }
}

private struct PopupActionButton: View {
    let title: String
    let symbolName: String
    let size: CGFloat
    let symbolSize: CGFloat
    let hoverColor: Color
    let pressedColor: Color
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbolName)
                .font(.system(size: symbolSize))
                .foregroundColor(.primary)
                .frame(width: size, height: size)
                .contentShape(Rectangle())
        }
        .buttonStyle(
            PopupActionButtonStyle(
                isHovered: isHovered,
                hoverColor: hoverColor,
                pressedColor: pressedColor
            )
        )
        .onHover { hovering in
            isHovered = hovering
        }
        .help(title)
        .accessibilityLabel(Text(title))
    }
}

private struct PopupActionButtonStyle: ButtonStyle {
    let isHovered: Bool
    let hoverColor: Color
    let pressedColor: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(backgroundFill(isPressed: configuration.isPressed))
            )
    }

    private func backgroundFill(isPressed: Bool) -> Color {
        if isPressed {
            return pressedColor
        }
        if isHovered {
            return hoverColor
        }
        return .clear
    }
}
