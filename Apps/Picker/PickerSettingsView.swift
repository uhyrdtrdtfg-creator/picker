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
    @Environment(\.colorScheme) private var colorScheme

    @AppStorage(PickerDefaultsKey.appearAutomatically) private var appearAutomatically = true
    @AppStorage(PickerDefaultsKey.startAtLogin) private var storedStartAtLogin = false
    @AppStorage(PickerDefaultsKey.excludedBundleIdentifiers) private var excludedBundleIdentifiersText = ""

    @State private var loginItemMessage = ""
    @State private var loginItemIsError = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                settingsSection("Activation") {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(alignment: .center, spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Appear automatically")
                                    .font(.system(size: PickerStyle.bodySize))
                                    .foregroundColor(.primary)
                                Text("Picker appears automatically when you select text with the pointer or when you click and hold.")
                                    .font(.system(size: PickerStyle.captionSize))
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 8)
                            Toggle("", isOn: appearAutomaticallyBinding)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .accessibilityLabel(Text("Appear automatically"))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)

                        Rectangle()
                            .fill(PickerStyle.borderColor(for: colorScheme))
                            .frame(height: PickerStyle.dividerThickness)

                        HStack(alignment: .center, spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Start at login")
                                    .font(.system(size: PickerStyle.bodySize))
                                    .foregroundColor(.primary)

                                if !loginItemMessage.isEmpty {
                                    Text(loginItemMessage)
                                        .font(.system(size: PickerStyle.captionSize))
                                        .foregroundColor(loginItemIsError ? PickerStyle.errorColor : .secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            Spacer(minLength: 8)
                            Toggle("", isOn: startAtLoginBinding)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .accessibilityLabel(Text("Start at login"))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                    }
                }

                settingsSection("Permissions") {
                    AccessibilityPermissionView()
                }

                settingsSection("Exclude these apps") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Restrict where Picker can appear automatically. Enter one bundle identifier per line:")
                            .font(.system(size: PickerStyle.captionSize))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        TextEditor(text: excludedAppsBinding)
                            .font(.system(size: PickerStyle.bodySize, design: .monospaced))
                            .foregroundColor(.primary)
                            .scrollContentBackground(.hidden)
                            .padding(6)
                            .frame(minHeight: 92)
                            .background(PickerStyle.surfaceColor(for: colorScheme))
                            .clipShape(RoundedRectangle(cornerRadius: PickerStyle.controlCornerRadius, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: PickerStyle.controlCornerRadius, style: .continuous)
                                    .strokeBorder(PickerStyle.borderColor(for: colorScheme), lineWidth: PickerStyle.borderWidth)
                            )
                    }
                    .padding(12)
                }
            }
            .padding(18)
        }
        .frame(minWidth: 460, idealWidth: 500, minHeight: 440)
        .onAppear {
            syncLoginItemState()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            syncLoginItemState()
        }
    }

    @ViewBuilder
    private func settingsSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: PickerStyle.sectionTitleSize, weight: .semibold))
                .foregroundColor(.primary)

            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(PickerStyle.surfaceColor(for: colorScheme))
                .clipShape(RoundedRectangle(cornerRadius: PickerStyle.cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: PickerStyle.cornerRadius, style: .continuous)
                        .strokeBorder(PickerStyle.borderColor(for: colorScheme), lineWidth: PickerStyle.borderWidth)
                )
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
            loginItemIsError = false
        case .requiresApproval:
            storedStartAtLogin = true
            loginItemMessage = "Allow Picker in System Settings > General > Login Items."
            loginItemIsError = false
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
            loginItemIsError = true
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
                    loginItemIsError = false
                case .requiresApproval:
                    storedStartAtLogin = true
                    loginItemMessage = "Allow Picker in System Settings > General > Login Items."
                    loginItemIsError = false
                case .notRegistered, .notFound:
                    storedStartAtLogin = false
                    loginItemMessage = "macOS did not register Picker as a login item."
                    loginItemIsError = true
                @unknown default:
                    storedStartAtLogin = false
                    loginItemMessage = "macOS reported an unknown login item status."
                    loginItemIsError = true
                }
            } catch {
                storedStartAtLogin = false
                loginItemMessage = Self.describeLoginItemError(error)
                loginItemIsError = true
            }
        } else {
            do {
                let currentStatus = SMAppService.mainApp.status
                if currentStatus == .enabled || currentStatus == .requiresApproval {
                    try SMAppService.mainApp.unregister()
                }
                storedStartAtLogin = false
                loginItemMessage = ""
                loginItemIsError = false
            } catch {
                let postStatus = SMAppService.mainApp.status
                storedStartAtLogin = (postStatus == .enabled || postStatus == .requiresApproval)
                loginItemMessage = Self.describeLoginItemError(error)
                loginItemIsError = true
            }
        }
    }

    private static func describeLoginItemError(_ error: Error) -> String {
        let localized = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return localized.isEmpty ? String(describing: error) : localized
    }
}
