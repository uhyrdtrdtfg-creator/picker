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

    @State private var isOpenAtLoginUnavailable = false

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

                    if isOpenAtLoginUnavailable {
                        Text("Open at Login is unavailable")
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
                storedStartAtLogin = newValue
                applyStartAtLogin(newValue)
            }
        )
    }

    private var canUseAppService: Bool {
        guard Bundle.main.bundleURL.pathExtension == "app",
              Bundle.main.bundleIdentifier != nil else {
            return false
        }
        return SMAppService.mainApp.status != .notFound
    }

    private func syncLoginItemState() {
        guard canUseAppService else {
            isOpenAtLoginUnavailable = true
            return
        }

        let status = SMAppService.mainApp.status
        isOpenAtLoginUnavailable = false
        if status == .enabled {
            storedStartAtLogin = true
        }
    }

    private func applyStartAtLogin(_ enabled: Bool) {
        guard canUseAppService else {
            isOpenAtLoginUnavailable = true
            return
        }

        do {
            let currentStatus = SMAppService.mainApp.status
            if enabled {
                if currentStatus == .enabled {
                    try? SMAppService.mainApp.unregister()
                }
                try SMAppService.mainApp.register()
            } else if currentStatus == .enabled || currentStatus == .requiresApproval {
                try SMAppService.mainApp.unregister()
            }
            isOpenAtLoginUnavailable = (SMAppService.mainApp.status == .notFound)
        } catch {
            isOpenAtLoginUnavailable = true
        }
    }
}
