import Foundation
import ServiceManagement
import SwiftUI

enum PickerDefaultsKey {
    static let appearAutomatically = "appearAutomatically"
    static let startAtLogin = "startAtLogin"
    static let excludedBundleIdentifiers = "excludedBundleIdentifiers"

    static func excludedAppBundleIDs(from defaults: UserDefaults = .standard) -> [String] {
        let rawText = defaults.string(forKey: excludedBundleIdentifiers) ?? ""
        return rawText
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
            Section("General") {
                Toggle("Appear automatically", isOn: $appearAutomatically)

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

            Section("Exclude Apps") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Bundle identifiers, one per line:")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    TextEditor(text: $excludedBundleIdentifiersText)
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
        .frame(minWidth: 460, idealWidth: 500, minHeight: 420)
        .onAppear {
            syncLoginItemStateOnAppear()
        }
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

    private func syncLoginItemStateOnAppear() {
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
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                let status = SMAppService.mainApp.status
                if status == .enabled || status == .requiresApproval {
                    try SMAppService.mainApp.unregister()
                }
            }
            isOpenAtLoginUnavailable = (SMAppService.mainApp.status == .notFound)
        } catch {
            isOpenAtLoginUnavailable = true
        }
    }
}
