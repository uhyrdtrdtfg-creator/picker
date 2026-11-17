import SwiftUI

public struct PickerPopupView: View {
    public static let minimumButtonHeight: CGFloat = 28

    private static let surfaceBackgroundColor = Color(red: 0.98, green: 0.98, blue: 0.99)
    private static let hoverBackgroundColor = Color(red: 0.91, green: 0.92, blue: 0.95)
    private static let pressedBackgroundColor = Color(red: 0.85, green: 0.87, blue: 0.91)
    private static let primaryTextColor = Color(red: 0.11, green: 0.12, blue: 0.14)
    private static let dividerColor = Color.black.opacity(0.09)
    private static let borderColor = Color.black.opacity(0.14)

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
                if index > 0 {
                    Rectangle()
                        .fill(Self.dividerColor)
                        .frame(width: 1, height: 18)
                }

                PopupActionButton(
                    title: Self.resolvedTitle(for: action),
                    symbolName: Self.resolvedSymbolName(for: action),
                    minimumHeight: Self.minimumButtonHeight,
                    textColor: Self.primaryTextColor,
                    hoverColor: Self.hoverBackgroundColor,
                    pressedColor: Self.pressedBackgroundColor
                ) {
                    onAction(action.id)
                }
            }
        }
        .padding(.horizontal, 3)
        .padding(.vertical, 2)
        .background(Self.surfaceBackgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Self.borderColor, lineWidth: 0.75)
        )
        .fixedSize()
        .environment(\.colorScheme, .light)
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
    let minimumHeight: CGFloat
    let textColor: Color
    let hoverColor: Color
    let pressedColor: Color
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbolName)
                    .font(.system(size: 12, weight: .medium))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundColor(textColor)
            .padding(.horizontal, 9)
            .frame(minHeight: minimumHeight)
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
                RoundedRectangle(cornerRadius: 6, style: .continuous)
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
