import SwiftUI
import AppKit
import MacVaultCore

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmDelete = false
    @State private var retentionMessage: String?
    @State private var notificationNotice: String?

    var body: some View {
        @Bindable var settings = model.settings
        VStack(spacing: 0) {
            ScreenHeader(item: .settings, subtitle: "Scanning, folder access, monitoring and MacVault’s own data") {}
            form(settings)
        }
        .navigationTitle("Settings")
        .confirmationDialog("Delete scan history?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Scan History", role: .destructive) { Task { await model.deleteScanHistory() } }
        } message: {
            Text("All scan sessions, findings and storage history will be removed from MacVault’s database. This cannot be undone. No files on your disk are changed.")
        }
    }

    private func form(_ settings: AppSettings) -> some View {
        @Bindable var settings = settings
        return Form {
            Section("Scanning") {
                StepperRow(title: "List files of at least", valueText: ByteFormat.string(settings.largeFileThresholdBytes),
                           value: $settings.largeFileThresholdMB, range: 1...100_000,
                           step: settings.largeFileThresholdMB < 100 ? 10 : 100)
                Toggle("Enter other volumes found inside a scanned folder", isOn: $settings.crossMountPoints)
                Text("Off by default: mounted disks and network shares inside a folder are counted as skipped instead of measured.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                if settings.exclusions.isEmpty {
                    Text("No exclusions").foregroundStyle(.secondary)
                }
                ForEach(settings.exclusions, id: \.self) { path in
                    HStack {
                        Image(systemName: "nosign").foregroundStyle(.secondary).accessibilityHidden(true)
                        PathText(path: path)
                        Spacer()
                        Button("Remove") { settings.exclusions.removeAll { $0 == path } }.controlSize(.small)
                    }
                }
                Button("Add Exclusion…") { addExclusion() }
            } header: {
                Text("Scan Exclusions")
            } footer: {
                Text("Excluded folders are skipped and counted, never measured.").font(.caption)
            }

            Section {
                if model.access.locations.isEmpty {
                    Text("No folders authorized").foregroundStyle(.secondary)
                }
                ForEach(model.access.locations) { location in
                    let status = model.access.status(of: location)
                    HStack {
                        Image(systemName: "folder.fill").foregroundStyle(Palette.analyzer).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: Spacing.xxs / 2) {
                            Text(location.displayPath).lineLimit(1).truncationMode(.middle).help(location.path)
                            Text("\(status.label) · added \(location.addedAt.formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if status != .available {
                            Button("Choose Again…") { Task { await model.chooseAndAddLocation() } }.controlSize(.small)
                        }
                        Button("Remove") { Task { await model.removeLocation(location) } }
                            .controlSize(.small)
                            .disabled(model.isScanning)
                            .help(model.isScanning ? "Wait for the scan to finish." : "Stop scanning this folder. Its files are not touched.")
                    }
                }
                Button("Add Folder…") { Task { await model.chooseAndAddLocation() } }
                #if !APPSTORE
                Button("Open Full Disk Access Settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                        NSWorkspace.shared.open(url)
                    }
                }
                #endif
            } header: {
                Text("Access")
            } footer: {
                Text(accessFooter).font(.caption)
            }

            Section {
                StepperRow(title: "Keep the newest", valueText: counted(settings.keepScans, "scan"),
                           value: $settings.keepScans, range: 1...500)
                HStack {
                    Button("Apply Now") {
                        Task {
                            let removed = await model.applyRetention()
                            retentionMessage = removed.map { $0 == 0 ? "Nothing to remove." : "Removed \($0) older scan record(s)." }
                                ?? "Retention could not be applied."
                        }
                    }
                    if let retentionMessage { Text(retentionMessage).font(.caption).foregroundStyle(.secondary) }
                }
            } header: {
                Text("History Retention")
            } footer: {
                Text("Older scans are also pruned automatically after each scan. Volume snapshots are kept.").font(.caption)
            }

            Section("Local Data") {
                if let path = model.store?.path {
                    LabeledContent("Database") {
                        PathText(path: path, small: true)
                    }
                    Button("Reveal Database in Finder") { FinderActions.reveal([path]) }
                }
                Button("Delete Scan History…", role: .destructive) { confirmDelete = true }
                    .disabled(model.isScanning || model.store == nil)
                    .help(model.store == nil ? "The local database is unavailable." : (model.isScanning ? "Wait for the scan to finish." : "Delete MacVault’s scan records. Your files are not touched."))
                Text("Deletes MacVault’s own records of scans, findings and storage snapshots. Your files are not touched. The activity log is kept.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Appearance & Accessibility") {
                LabeledContent("Appearance", value: "Follows system Light/Dark setting")
                LabeledContent("Motion", value: "Follows system Reduce Motion setting")
            }

            Section {
                Picker("Scheduled read-only scans", selection: $settings.scanSchedule) {
                    ForEach(ScanSchedule.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .accessibilityIdentifier("schedulePicker")
                if settings.scanSchedule != .off {
                    LabeledContent("Last scheduled scan", value: settings.lastScheduledScan?.shortDateTime ?? "Not yet")
                    Toggle("Notify when a scheduled scan finishes", isOn: notificationBinding($settings.notifyScheduledScans))
                    Button("Run Scheduled Scan Now") { Task { await model.runScheduledScans() } }
                        .disabled(model.isScanning || model.access.locations.isEmpty)
                        .help(model.access.locations.isEmpty ? "Add a folder first." : (model.isScanning ? "A scan is already running." : "Scan every folder now. Read-only."))
                }
                Toggle("Warn when a disk is low on space", isOn: notificationBinding($settings.lowStorageAlerts))
                    .accessibilityIdentifier("lowStorageToggle")
                if settings.lowStorageAlerts {
                    StepperRow(title: "Warn below", valueText: "\(settings.lowStorageThresholdPercent)% available",
                               value: $settings.lowStorageThresholdPercent, range: 1...50)
                }
                Toggle("Show MacVault in the menu bar", isOn: $settings.showMenuBarExtra)
                    .accessibilityIdentifier("menuBarToggle")
                if let notice = notificationNotice {
                    Label(notice, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(Palette.warning)
                }
            } header: {
                Text("Monitoring")
            } footer: {
                Text("Scheduled scans and storage checks run only while MacVault is open (including from the menu bar). They only read: nothing is ever moved or deleted automatically. Every warning is also recorded in Activity.")
                    .font(.caption)
            }

            Section("About") {
                LabeledContent("Version", value: AppSettings.version)
                LabeledContent("Edition", value: AppSettings.edition)
                Text("MacVault works locally. No file inventory, paths or logs are sent anywhere.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .frame(maxWidth: Dimensions.formWidth)
        // Leading, under the screen header like every other screen's content.
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Turning on an option that notifies asks macOS for permission first; the option stays on either way
    /// (events are still recorded in Activity).
    private func notificationBinding(_ binding: Binding<Bool>) -> Binding<Bool> {
        Binding(get: { binding.wrappedValue }, set: { newValue in
            binding.wrappedValue = newValue
            guard newValue else { return }
            Task {
                if !Notifier.isAvailable {
                    notificationNotice = "Notifications need the bundled app (built with Xcode). Events are still recorded in Activity."
                } else if await Notifier.requestAuthorization() == false {
                    notificationNotice = "Notifications are turned off for MacVault in System Settings › Notifications. Events are still recorded in Activity."
                } else {
                    notificationNotice = nil
                }
            }
        })
    }

    private var accessFooter: String {
        #if APPSTORE
        return "MacVault can read only folders you choose here. Access is remembered with security-scoped bookmarks."
        #else
        return "MacVault reads only folders you choose. macOS protects some locations (Mail, Messages, Safari data and others) unless you grant Full Disk Access; without it those items are counted as not readable. MacVault never asks you to disable system security."
        #endif
    }

    private func addExclusion() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Exclude"
        panel.message = "Choose folders to skip during scans."
        guard panel.runModal() == .OK else { return }
        let paths = panel.urls.map { PathUtilities.canonicalize($0.path) }
        for path in paths where !model.settings.exclusions.contains(path) {
            model.settings.exclusions.append(path)
        }
    }
}
