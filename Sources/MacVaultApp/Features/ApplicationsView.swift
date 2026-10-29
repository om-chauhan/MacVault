import SwiftUI
import MacVaultCore

struct ApplicationsView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var sortOrder = [KeyPathComparator(\AppRow.size, order: .reverse)]

    struct AppRow: Identifiable, Hashable {
        let id: String
        let name: String
        let version: String
        let size: Int64
        let location: String
        let isProtected: Bool
        let isRemoved: Bool
    }

    private var rows: [AppRow] {
        let apps = model.applications
        return apps.apps
            .filter { search.isEmpty || $0.displayName.localizedCaseInsensitiveContains(search) || ($0.bundleId ?? "").localizedCaseInsensitiveContains(search) }
            .map { AppRow(id: $0.id, name: $0.displayName, version: $0.version ?? "—", size: $0.bundleSizeBytes ?? -1,
                          location: PathUtilities.abbreviatingHome(($0.bundlePath as NSString).deletingLastPathComponent),
                          isProtected: $0.isProtected, isRemoved: apps.isRemoved($0)) }
            .sorted(using: sortOrder)
    }

    var body: some View {
        @Bindable var apps = model.applications
        VStack(spacing: 0) {
            HStack(spacing: Spacing.s) {
                TextField("Filter by name or bundle identifier", text: $search)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 300)
                Spacer()
                if apps.isScanning {
                    ProgressView(value: Double(apps.progress.done), total: Double(max(apps.progress.total, 1))).frame(width: 120)
                    Button("Stop") { apps.cancel() }
                } else {
                    Text(apps.lastScanned.map { "Checked \($0.relative)" } ?? "").font(.caption).foregroundStyle(.secondary)
                    Button(apps.apps.isEmpty ? "List Applications" : "Refresh") {
                        apps.scan(policy: model.operations.policy, store: model.store)
                    }
                    .disabled(model.operations.isExecuting)
                }
            }
            .padding(.horizontal, Spacing.l)
            .padding(.vertical, Spacing.s)
            Divider()
            VStack(alignment: .leading, spacing: Spacing.s) {
                OperationStatusPanel(types: [.appUninstall, .appLeftovers])
                if let error = apps.error { InlineBanner(kind: .error, title: "Applications could not be listed", message: error) }
                OperationHistoryList(types: [.appUninstall, .appLeftovers])
            }
            .padding(.horizontal, Spacing.l)
            .padding(.vertical, Spacing.xs)

            if apps.apps.isEmpty {
                ContentUnavailableView {
                    Label(apps.isScanning ? "Reading applications…" : "Installed applications", systemImage: "square.grid.2x2")
                } description: {
                    Text("MacVault lists apps in /Applications and ~/Applications with their size. Removing an app and removing its data are separate, reviewed steps. Apple apps can’t be removed.")
                } actions: {
                    if !apps.isScanning {
                        Button("List Applications") { apps.scan(policy: model.operations.policy, store: model.store) }
                            .buttonStyle(.borderedProminent)
                    }
                }
            } else {
                HSplitView {
                    Table(rows, selection: $apps.selectedAppID, sortOrder: $sortOrder) {
                        TableColumn("Name", value: \.name) { row in
                            HStack(spacing: Spacing.xs) {
                                Text(row.name).strikethrough(row.isRemoved)
                                if row.isProtected { Image(systemName: "lock.fill").foregroundStyle(.secondary).help("Protected") }
                                if row.isRemoved { Text("In Trash").font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                        TableColumn("Version", value: \.version).width(min: 60, ideal: 80)
                        TableColumn("Size", value: \.size) { row in
                            Text(row.size < 0 ? "Unknown" : ByteFormat.string(row.size)).monospacedDigit()
                        }
                        .width(min: 70, ideal: 90)
                        TableColumn("Location", value: \.location) { row in
                            Text(row.location).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    .frame(minWidth: 420)
                    .onChange(of: apps.selectedAppID) { _, _ in
                        Task { await apps.loadAssociated(policy: model.operations.policy) }
                    }

                    AppDetail()
                        .frame(minWidth: 340, idealWidth: 420)
                }
            }
        }
        .navigationTitle("Applications")
    }
}

private struct AppDetail: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let apps = model.applications
        if let app = apps.selectedApp {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.m) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.displayName).font(.title2.weight(.semibold))
                        Text(app.bundleId ?? "No bundle identifier").font(.caption.monospaced()).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    HStack(spacing: Spacing.xl) {
                        Metric(label: "App bundle", value: (app.sizeIsLowerBound ? "≥ " : "") + ByteFormat.string(app.bundleSizeBytes))
                        Metric(label: "Version", value: app.version ?? "Unknown")
                    }
                    HStack {
                        Button("Reveal in Finder") { FinderActions.reveal([app.bundlePath]) }
                        Spacer()
                        removeAppButton(app)
                    }
                    if app.isProtected {
                        InlineBanner(kind: .info, title: "Protected", message: app.protectionReason ?? "This app can’t be removed with MacVault.")
                    } else if apps.isRemoved(app) {
                        InlineBanner(kind: .info, title: "Moved to the Trash",
                                     message: "Its data in your Library was kept. Review it below if you no longer need it.")
                    }

                    Divider()
                    leftovers(app)
                }
                .padding(Spacing.l)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableView("No app selected", systemImage: "sidebar.right",
                                   description: Text("Select an app to see its size and the data it keeps in your Library."))
        }
    }

    @ViewBuilder
    private func removeAppButton(_ app: ApplicationRecord) -> some View {
        let apps = model.applications
        if OperationsModel.canModifyFiles && !app.isProtected && !apps.isRemoved(app) {
            Button("Move App to Trash…", role: .destructive) {
                guard let candidate = apps.inventory(policy: model.operations.policy).uninstallCandidate(for: app) else { return }
                let bundlePath = app.bundlePath
                Task {
                    await model.operations.review(.appUninstall, title: "Remove \(app.displayName)", candidates: [candidate],
                                                  inUseCheck: { _ in
                        RunningApps.runningName(bundlePath: bundlePath).map { "\($0) is running. Quit it and try again." }
                    }) {
                        if case .finished(let manifest) = model.operations.phase { apps.removeProcessed(manifest) }
                    }
                }
            }
            .disabled(model.operations.isExecuting)
            .help("Moves only the app bundle. Its data in your Library is kept unless you remove it separately.")
        }
    }

    @ViewBuilder
    private func leftovers(_ app: ApplicationRecord) -> some View {
        let apps = model.applications
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack {
                Text("Data in your Library").font(.headline)
                Spacer()
                if apps.isLoadingAssociated { ProgressView().controlSize(.small) }
            }
            Text("Found by name only. Items matching the bundle identifier are likely the app’s; items matching only the app name are less certain and are never pre-selected. Login items and keychains are never listed.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if apps.associated.isEmpty && !apps.isLoadingAssociated {
                Text(app.isProtected ? "Not reviewed for protected apps." : "Nothing found.").foregroundStyle(.secondary)
            }
            ForEach(apps.associated) { item in
                VStack(alignment: .leading, spacing: 2) {
                    CandidateRow(candidate: item.candidate, isSelected: Binding(
                        get: { apps.leftoverSelection.contains(item.id) },
                        set: { if $0 { apps.leftoverSelection.insert(item.id) } else { apps.leftoverSelection.remove(item.id) } }),
                                 disabled: !OperationsModel.canModifyFiles)
                    Text(item.confidence.displayName).font(.caption2).foregroundStyle(item.confidence == .high ? .secondary : Color.orange)
                        .padding(.leading, 44)
                }
            }
            if OperationsModel.canModifyFiles && !apps.associated.isEmpty {
                let selected = apps.associated.filter { apps.leftoverSelection.contains($0.id) }.map(\.candidate)
                HStack {
                    Text("\(selected.count) selected · \(ByteFormat.string(selected.reduce(0) { $0 + ($1.logicalBytes ?? 0) }))")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Review & Move Data to Trash…") {
                        let bundleId = app.bundleId
                        Task {
                            await model.operations.review(.appLeftovers, title: "Data of \(app.displayName)", candidates: selected,
                                                          inUseCheck: { _ in
                                guard let bundleId, RunningApps.isRunning(bundleId: bundleId) else { return nil }
                                return "\(app.displayName) is running. Quit it and try again."
                            }) {
                                if case .finished(let manifest) = model.operations.phase { apps.removeProcessed(manifest) }
                            }
                        }
                    }
                    .disabled(selected.isEmpty || model.operations.isExecuting)
                }
            } else if !OperationsModel.canModifyFiles {
                Label(OperationsModel.readOnlyExplanation, systemImage: "lock").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
