import AppKit
import ApplicationServices
import SwiftUI

enum AccessibilityPermission {
    static let accessibilityChangedNotification = Notification.Name("com.apple.accessibility.api")

    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    static func isProcessTrusted(prompt: Bool = false) -> Bool {
        if prompt {
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            return AXIsProcessTrustedWithOptions(options)
        }
        return AXIsProcessTrusted()
    }

    static var usesDeviceControlPane: Bool {
        if #available(macOS 27, *) {
            return true
        }
        return usesDeviceControlPane(for: ProcessInfo.processInfo.operatingSystemVersion)
    }

    static func usesDeviceControlPane(for version: OperatingSystemVersion) -> Bool {
        version.majorVersion >= 27
    }

    static var settingsPaneTitle: String {
        usesDeviceControlPane ? "Device Control and Data Access" : "Accessibility"
    }

    static var settingsPathDescription: String {
        if usesDeviceControlPane {
            return "Privacy & Security > Device Control and Data Access"
        }
        return "Privacy & Security > Accessibility"
    }

    static var requiredHeadline: String {
        if usesDeviceControlPane {
            return "Device Control and Data Access is required"
        }
        return "Accessibility access is required"
    }

    static var requestButtonTitle: String {
        if usesDeviceControlPane {
            return "Request Device Control and Data Access"
        }
        return "Request Accessibility Access"
    }

    static var openSettingsButtonTitle: String {
        if usesDeviceControlPane {
            return "Open Device Control and Data Access"
        }
        return "Open Accessibility Settings"
    }

    static var explanationText: String {
        let pane = settingsPathDescription
        return "Open \(pane), click +, and choose Picker from Applications. Then turn its switch on. macOS does not add an unsigned menu-bar app by itself."
    }

    static func requestAccess() {
        _ = isProcessTrusted(prompt: true)
        openSystemSettings()
    }

    static var systemSettingsURL: URL {
        if #available(macOS 27, *) {
            return URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility")!
        }
        if usesDeviceControlPane {
            return URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility")!
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    }

    static func openSystemSettings() {
        NSWorkspace.shared.open(systemSettingsURL)
    }
}

struct PickerSettingsActionButton: View {
    let title: String
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: PickerStyle.bodySize, weight: .medium))
                .foregroundColor(.primary)
                .padding(.horizontal, 10)
                .frame(height: PickerStyle.orcaControlHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(
            PickerSettingsActionButtonStyle(
                colorScheme: colorScheme,
                isHovered: isHovered
            )
        )
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

private struct PickerSettingsActionButtonStyle: ButtonStyle {
    let colorScheme: ColorScheme
    let isHovered: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: PickerStyle.controlCornerRadius, style: .continuous)
                    .fill(backgroundFill(isPressed: configuration.isPressed))
            )
            .overlay(
                RoundedRectangle(cornerRadius: PickerStyle.controlCornerRadius, style: .continuous)
                    .strokeBorder(PickerStyle.borderColor(for: colorScheme), lineWidth: PickerStyle.borderWidth)
            )
    }

    private func backgroundFill(isPressed: Bool) -> Color {
        if isPressed {
            return PickerStyle.pressedColor(for: colorScheme)
        }
        if isHovered {
            return PickerStyle.hoverColor(for: colorScheme)
        }
        return .clear
    }
}

struct OpenAccessibilitySettingsButton: View {
    var isTrusted: Bool = AccessibilityPermission.isTrusted
    var action: () -> Void = AccessibilityPermission.openSystemSettings

    var body: some View {
        PickerSettingsActionButton(
            title: isTrusted
                ? AccessibilityPermission.openSettingsButtonTitle
                : AccessibilityPermission.requestButtonTitle
        ) {
            if isTrusted {
                action()
            } else {
                AccessibilityPermission.requestAccess()
            }
        }
    }
}

struct AccessibilityPermissionView: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var isTrusted = AccessibilityPermission.isTrusted

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: isTrusted ? "checkmark.circle" : "exclamationmark.triangle")
                        .font(.system(size: PickerStyle.bodySize, weight: .medium))
                        .foregroundColor(isTrusted ? .secondary : PickerStyle.errorColor)
                    Text(isTrusted ? AccessibilityPermission.settingsPaneTitle : AccessibilityPermission.requiredHeadline)
                        .font(.system(size: PickerStyle.bodySize))
                        .foregroundColor(.primary)
                    Spacer()
                    Text(isTrusted ? "Authorized" : "Not Authorized")
                        .font(.system(size: PickerStyle.captionSize))
                        .foregroundColor(isTrusted ? .secondary : PickerStyle.errorColor)
                }

                if !isTrusted {
                    Text(AccessibilityPermission.explanationText)
                        .font(.system(size: PickerStyle.captionSize))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Rectangle()
                .fill(PickerStyle.borderColor(for: colorScheme))
                .frame(height: PickerStyle.dividerThickness)

            HStack(spacing: 8) {
                OpenAccessibilitySettingsButton(isTrusted: isTrusted)
                PickerSettingsActionButton(title: "Refresh") {
                    refreshTrustState()
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .onAppear {
            refreshTrustState()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshTrustState()
        }
        .onReceive(
            DistributedNotificationCenter.default().publisher(
                for: AccessibilityPermission.accessibilityChangedNotification
            )
        ) { _ in
            refreshTrustState()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                refreshTrustState()
            }
        }
    }

    private func refreshTrustState() {
        isTrusted = AccessibilityPermission.isTrusted
    }
}
