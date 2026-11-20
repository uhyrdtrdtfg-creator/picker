import AppKit
import Foundation
import ServiceManagement
import SwiftUI

enum PickerDefaultsKey {
    static let appearAutomatically = "appearAutomatically"
    static let namespacedAppearAutomatically = "picker.appearAutomatically"
    static let startAtLogin = "startAtLogin"
    static let excludedBundleIdentifiers = "excludedBundleIdentifiers"
    static let namespacedExcludedBundleIDs = "picker.excludedBundleIDs"

    static func excludedAppBundleIDs(from defaults: UserDefaults = .standard) -> [String] {
        let rawText = defaults.string(forKey: excludedBundleIdentifiers) ?? ""
        return parseBundleIdentifiers(from: rawText)
    }

    static func parseBundleIdentifiers(from rawText: String) -> [String] {
        rawText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

struct PickerSettingsView: View {
    @AppStorage(PickerDefaultsKey.appearAutomatically) private var appearAutomatically = true
    @AppStorage(PickerDefaultsKey.startAtLogin) private var storedStartAtLogin = false
    @AppStorage(PickerDefaultsKey.excludedBundleIdentifiers) private var excludedBundleIdentifiersText = ""

    @State private var loginItemMessage = ""

    var body: some View {
        Form {
            Section("Activation") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Appear automatically", isOn: appearAutomaticallyBinding)
                    Text("Picker appears automatically when you select text with the pointer or when you click and hold.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Start at login", isOn: startAtLoginBinding)

                    if !loginItemMessage.isEmpty {
                        Text(loginItemMessage)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Section("Permissions") {
                AccessibilityPermissionView()
            }

            Section("Exclude these apps") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Restrict where Picker can appear automatically. Enter one bundle identifier per line:")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    TextEditor(text: excludedAppsBinding)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 110)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                        )
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 460, idealWidth: 500, minHeight: 440)
        .onAppear {
            syncLoginItemState()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            syncLoginItemState()
        }
    }

    private var appearAutomaticallyBinding: Binding<Bool> {
        Binding(
            get: { appearAutomatically },
            set: { newValue in
                appearAutomatically = newValue
                UserDefaults.standard.set(newValue, forKey: PickerDefaultsKey.namespacedAppearAutomatically)
            }
        )
    }

    private var excludedAppsBinding: Binding<String> {
        Binding(
            get: { excludedBundleIdentifiersText },
            set: { newValue in
                excludedBundleIdentifiersText = newValue
                let parsed = PickerDefaultsKey.parseBundleIdentifiers(from: newValue)
                UserDefaults.standard.set(parsed, forKey: PickerDefaultsKey.namespacedExcludedBundleIDs)
            }
        )
    }

    private var startAtLoginBinding: Binding<Bool> {
        Binding(
            get: { storedStartAtLogin },
            set: { newValue in
                applyStartAtLogin(newValue)
            }
        )
    }

    private var isRunningFromAppBundle: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }

    private func syncLoginItemState() {
        guard isRunningFromAppBundle else {
            storedStartAtLogin = false
            return
        }

        switch SMAppService.mainApp.status {
        case .enabled:
            storedStartAtLogin = true
            loginItemMessage = ""
        case .requiresApproval:
            storedStartAtLogin = true
            loginItemMessage = "Allow Picker in System Settings > General > Login Items."
        case .notRegistered, .notFound:
            storedStartAtLogin = false
        @unknown default:
            storedStartAtLogin = false
        }
    }

    private func applyStartAtLogin(_ enabled: Bool) {
        guard isRunningFromAppBundle else {
            storedStartAtLogin = false
            loginItemMessage = "Start at login requires running Picker from an app bundle."
            return
        }

        if enabled {
            do {
                if SMAppService.mainApp.status == .enabled {
                    try? SMAppService.mainApp.unregister()
                }
                try SMAppService.mainApp.register()
                switch SMAppService.mainApp.status {
                case .enabled:
                    storedStartAtLogin = true
                    loginItemMessage = ""
                case .requiresApproval:
                    storedStartAtLogin = true
                    loginItemMessage = "Allow Picker in System Settings > General > Login Items."
                case .notRegistered, .notFound:
                    storedStartAtLogin = false
                    loginItemMessage = "macOS did not register Picker as a login item."
                @unknown default:
                    storedStartAtLogin = false
                    loginItemMessage = "macOS reported an unknown login item status."
                }
            } catch {
                storedStartAtLogin = false
                loginItemMessage = Self.describeLoginItemError(error)
            }
        } else {
            do {
                let currentStatus = SMAppService.mainApp.status
                if currentStatus == .enabled || currentStatus == .requiresApproval {
                    try SMAppService.mainApp.unregister()
                }
                storedStartAtLogin = false
                loginItemMessage = ""
            } catch {
                let postStatus = SMAppService.mainApp.status
                storedStartAtLogin = (postStatus == .enabled || postStatus == .requiresApproval)
                loginItemMessage = Self.describeLoginItemError(error)
            }
        }
    }

    private static func describeLoginItemError(_ error: Error) -> String {
        let localized = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return localized.isEmpty ? String(describing: error) : localized
    }
}
