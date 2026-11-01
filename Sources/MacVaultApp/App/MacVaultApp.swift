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
                .uiTestWindowSize()
                .task { await model.start() }
        }
        // Compact: the toolbar row only holds the window controls and the sidebar toggle.
        .windowToolbarStyle(.unifiedCompact)
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
        Self.applyDockIconIfUnbundled()
        AppEnvironment.applyUITestHooks()
    }

    /// Without an app bundle (SwiftPM `MacVaultApp` scheme, `swift run`) there is no Info.plist or asset
    /// catalog, so the Dock shows a generic executable icon. The package ships the icon as a resource
    /// and sets it at launch. The bundled app gets its icon from the asset catalog and skips this.
    private static func applyDockIconIfUnbundled() {
        guard Bundle.main.bundleURL.pathExtension != "app" else { return }
        #if SWIFT_PACKAGE
        if let url = Bundle.module.url(forResource: "AppIcon", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = image
            Log.app.info("Dock icon set from the package resource (unbundled run)")
        } else {
            Log.app.error("Dock icon resource missing from the package bundle")
        }
        #endif
    }

    /// With the menu bar item shown, MacVault keeps running after its window closes so scheduled
    /// read-only scans and storage checks continue.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !(AppEnvironment.defaults.object(forKey: "showMenuBarExtra") as? Bool ?? true)
    }
}

/// Compact status: boot volume capacity, last scan, and quick actions. Read-only.
struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            if let volume = model.volumes.first {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    HStack(spacing: Spacing.xs) {
                        Image(systemName: "internaldrive.fill").foregroundStyle(Palette.storage).accessibilityHidden(true)
                        Text(volume.displayName).font(.cardTitle)
                        Spacer()
                        if let fraction = volume.usedFraction {
                            Text("\(LegendRow.percent(fraction)) used").font(.caption.weight(.semibold)).monospacedDigit()
                        }
                    }
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.xxs) {
                        ValueText(value: bytes(volume.availableBytes), size: .tile)
                        Text("available").font(.callout).foregroundStyle(.secondary)
                    }
                    if let fraction = volume.usedFraction {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Palette.track)
                                Capsule().fill((fraction >= 0.9 ? Palette.warning : Palette.storage).gradient)
                                    .frame(width: geo.size.width * fraction)
                            }
                        }
                        .frame(height: Spacing.xs)
                        .accessibilityLabel("\(Int(fraction * 100)) percent used")
                    }
                    Text("of \(bytes(volume.totalBytes)) · observed \(volume.observedAt.relative)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: Spacing.xs) {
                    ProgressView().controlSize(.small)
                    Text("Reading volume information…").foregroundStyle(.secondary)
                }
            }

            Divider()

            if case .running(_, let progress) = model.scanPhase {
                HStack(spacing: Spacing.xs) {
                    ProgressView().controlSize(.small)
                    Text("Scanning… \(counted(progress.filesVisited, "file"))").font(.callout).monospacedDigit()
                    Spacer()
                    Button("Cancel") { model.cancelScan() }.controlSize(.small)
                        .help("Stop the scan. What was read so far is kept.")
                }
            } else if let last = model.recentScans.first {
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    HStack {
                        TagPill(text: "Last scan", tint: Palette.analyzer)
                        Spacer()
                        StatusBadge(status: last.status)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                        ValueText(value: bytes(last.bytesObserved), size: .metric)
                        Text(last.startedAt.relative).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(last.scopeDescription).font(.smallPath).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).help(last.scopeDescription)
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
                    .help(model.selectedLocation == nil ? "Choose a folder in MacVault first." : "Read-only scan of this folder.")
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
        .frame(width: Dimensions.menuBarWidth)
    }
}
