import SwiftUI
import AppKit
import MacVaultCore

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmDelete = false
    @State private var retentionMessage: String?

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section("Scanning") {
                Stepper(value: $settings.largeFileThresholdMB, in: 1...100_000, step: settings.largeFileThresholdMB < 100 ? 10 : 100) {
                    LabeledContent("List files of at least", value: ByteFormat.string(settings.largeFileThresholdBytes))
                }
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
                        Image(systemName: "nosign").foregroundStyle(.secondary)
                        Text(PathUtilities.abbreviatingHome(path)).lineLimit(1).truncationMode(.middle)
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
                        Image(systemName: "folder").foregroundStyle(.secondary)
                        VStack(alignment: .leading) {
                            Text(location.displayPath).lineLimit(1).truncationMode(.middle)
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
                Stepper(value: $settings.keepScans, in: 1...500) {
                    LabeledContent("Keep the newest", value: "\(settings.keepScans) scans")
                }
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
                        Text(PathUtilities.abbreviatingHome(path)).font(.caption.monospaced()).textSelection(.enabled)
                    }
                    Button("Reveal Database in Finder") { FinderActions.reveal([path]) }
                }
                Button("Delete Scan History…", role: .destructive) { confirmDelete = true }
                    .disabled(model.isScanning || model.store == nil)
                Text("Deletes MacVault’s own records of scans, findings and storage snapshots. Your files are not touched. The activity log is kept.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Appearance & Accessibility") {
                LabeledContent("Appearance", value: "Follows system Light/Dark setting")
                LabeledContent("Motion", value: "Follows system Reduce Motion setting")
            }

            Section("Planned") {
                ForEach(["Scheduled read-only scans", "Low-storage notifications", "Menu bar status", "Activity export (JSON/CSV)"], id: \.self) { item in
                    HStack { Text(item).foregroundStyle(.secondary); Spacer(); StatusBadge.planned }
                }
            }

            Section("About") {
                LabeledContent("Version", value: AppSettings.version)
                LabeledContent("Edition", value: AppSettings.edition)
                Text("MacVault works locally. No file inventory, paths or logs are sent anywhere.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .confirmationDialog("Delete scan history?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Scan History", role: .destructive) { Task { await model.deleteScanHistory() } }
        } message: {
            Text("All scan sessions, findings and storage history will be removed from MacVault’s database. This cannot be undone. No files on your disk are changed.")
        }
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
