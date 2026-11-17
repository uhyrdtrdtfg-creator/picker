import AppKit
import SwiftUI

extension Notification.Name {
    static let pickerShowLastSelection = Notification.Name("app.picker.mac.showLastSelection")
}

@main
struct PickerApp: App {
    private static let settingsWindowID = "picker-settings"

    var body: some Scene {
        MenuBarExtra("Picker") {
            PickerMenuContent(settingsWindowID: Self.settingsWindowID)
        }

        Window("Picker Settings", id: Self.settingsWindowID) {
            PickerSettingsView()
        }
        .defaultSize(width: 500, height: 460)
    }
}

private struct PickerMenuContent: View {
    let settingsWindowID: String
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Show last selection") {
            NotificationCenter.default.post(name: .pickerShowLastSelection, object: nil)
        }

        Divider()

        Button("Settings") {
            openSettingsWindow()
        }
        .keyboardShortcut(",", modifiers: .command)

        Divider()

        Button("Quit") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }

    private func openSettingsWindow() {
        openWindow(id: settingsWindowID)
        activateApplication()
        DispatchQueue.main.async {
            activateApplication()
            for window in NSApp.windows where window.title == "Picker Settings" {
                window.makeKeyAndOrderFront(nil)
                window.orderFrontRegardless()
            }
        }
    }

    private func activateApplication() {
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
