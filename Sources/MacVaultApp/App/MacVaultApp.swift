import SwiftUI
import AppKit
import MacVaultCore

@main
struct MacVaultApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("MacVault", id: "main") {
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

        MenuBarExtra("MacVault", systemImage: "internaldrive",
                     isInserted: Binding(get: { model.settings.showMenuBarExtra },
                                         set: { model.settings.showMenuBarExtra = $0 })) {
            MenuBarContent()
                .environment(model)
                .task { await model.start() }
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched via `swift run` (no app bundle) so the window can take focus.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// With the menu bar item shown, MacVault keeps running after its window closes so scheduled
    /// read-only scans and storage checks continue.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !(UserDefaults.standard.object(forKey: "showMenuBarExtra") as? Bool ?? true)
    }
}

/// Compact status: boot volume capacity, last scan, and quick actions. Read-only.
struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            if let volume = model.volumes.first {
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    HStack {
                        Text(volume.displayName).font(.headline)
                        Spacer()
                        Text("\(bytes(volume.availableBytes)) available").font(.callout).monospacedDigit()
                    }
                    if let fraction = volume.usedFraction {
                        ProgressView(value: fraction)
                            .tint(fraction >= 0.9 ? .orange : .accentColor)
                            .accessibilityLabel("\(Int(fraction * 100)) percent used")
                    }
                    Text("of \(bytes(volume.totalBytes)) · observed \(volume.observedAt.relative)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Reading volume information…").foregroundStyle(.secondary)
            }

            Divider()

            if case .running(_, let progress) = model.scanPhase {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Scanning… \(progress.filesVisited.formatted()) files").font(.callout).monospacedDigit()
                    Spacer()
                    Button("Cancel") { model.cancelScan() }.controlSize(.small)
                }
            } else if let last = model.recentScans.first {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Last scan").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        StatusBadge(status: last.status)
                    }
                    Text("\(last.scopeDescription) · \(bytes(last.bytesObserved))").font(.callout).lineLimit(1).truncationMode(.middle)
                    Text(last.startedAt.relative).font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("No scans yet").font(.callout).foregroundStyle(.secondary)
            }

            if model.settings.scanSchedule != .off {
                Text("Scheduled scans: \(model.settings.scanSchedule.displayName.lowercased()) · last \(model.settings.lastScheduledScan?.relative ?? "never")")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Divider()

            HStack {
                Button("Scan \(model.selectedLocation?.displayName ?? "Folder")") { model.startScan() }
                    .disabled(model.isScanning || model.selectedLocation == nil || model.store == nil)
                Spacer()
                Button("Open MacVault") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                .keyboardShortcut(.defaultAction)
            }
            HStack {
                Button("Refresh") { Task { await model.refreshVolumes() } }
                Spacer()
                Button("Quit MacVault") { NSApp.terminate(nil) }
            }
            .controlSize(.small)
        }
        .padding(Spacing.m)
        .frame(width: 320)
    }
}
