import SwiftUI
import AppKit
import MacVaultCore

@main
struct MacVaultApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("MacVault") {
            RootView()
                .environment(model)
                .frame(minWidth: 960, minHeight: 620)
                .task { await model.start() }
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Scan") {
                Button("Refresh Volume Information") { Task { await model.refreshVolumes() } }
                    .keyboardShortcut("r", modifiers: [.command])
                Button("Cancel Scan") { model.cancelScan() }
                    .keyboardShortcut(".", modifiers: [.command])
                    .disabled(!model.isScanning)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched via `swift run` (no app bundle) so the window can take focus.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
