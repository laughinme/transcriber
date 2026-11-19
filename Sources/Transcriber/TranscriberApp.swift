import AppKit
import SwiftUI

@main
struct TranscriberApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared

    var body: some Scene {
        Window("Расшифровка", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 760, minHeight: 480)
        }
        .defaultSize(width: 1040, height: 680)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Добавить файлы…") { model.openPanel() }
                    .keyboardShortcut("o")
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

/// Files dropped on the Dock icon or opened with "Open With" in Finder.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in AppModel.shared.add(urls) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Running via `swift run` has no bundle: make it a regular foreground app anyway.
        NSApp.setActivationPolicy(.regular)
        Task { @MainActor in DebugHooks.install() }
    }
}
