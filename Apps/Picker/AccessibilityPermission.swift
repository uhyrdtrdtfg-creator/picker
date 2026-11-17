import AppKit
import ApplicationServices
import SwiftUI

enum AccessibilityPermission {
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

    static var openSettingsButtonTitle: String {
        if usesDeviceControlPane {
            return "Open Device Control and Data Access"
        }
        return "Open Accessibility Settings"
    }

    static var explanationText: String {
        if usesDeviceControlPane {
            return "Picker needs Device Control and Data Access in \(settingsPathDescription) to read the text you select and to perform actions."
        }
        return "Picker needs Accessibility access in \(settingsPathDescription) to read the text you select and to perform actions."
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

struct OpenAccessibilitySettingsButton: View {
    var action: () -> Void = AccessibilityPermission.openSystemSettings

    var body: some View {
        Button(AccessibilityPermission.openSettingsButtonTitle) {
            action()
        }
    }
}

struct AccessibilityPermissionView: View {
    @State private var isTrusted = AccessibilityPermission.isTrusted

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: isTrusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundColor(isTrusted ? .green : .orange)
                Text(AccessibilityPermission.settingsPaneTitle)
                Spacer()
                Text(isTrusted ? "Authorized" : "Not Authorized")
                    .foregroundColor(.secondary)
            }

            if !isTrusted {
                Text(AccessibilityPermission.explanationText)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            HStack {
                OpenAccessibilitySettingsButton()
                Button("Refresh") {
                    isTrusted = AccessibilityPermission.isTrusted
                }
            }
        }
        .onAppear {
            isTrusted = AccessibilityPermission.isTrusted
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            isTrusted = AccessibilityPermission.isTrusted
        }
    }
}
