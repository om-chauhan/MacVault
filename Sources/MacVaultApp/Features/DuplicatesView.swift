import SwiftUI
import MacVaultCore

struct DuplicatesView: View {
    @Environment(AppModel.self) private var model

    private var location: AuthorizedLocation? {
        let id = model.duplicates.locationID ?? model.selectedLocationID
        return model.access.locations.first { $0.id == id } ?? model.access.locations.first
    }

    var body: some View {
        @Bindable var dups = model.duplicates
        VStack(spacing: 0) {
            controls(dups)
            Divider()
            VStack(alignment: .leading, spacing: Spacing.s) {
                OperationStatusPanel(types: [.duplicateRemoval])
                if let error = dups.error { InlineBanner(kind: .error, title: "Search could not finish", message: error) }
                if let result = dups.result {
                    summary(result)
                }
                OperationHistoryList(types: [.duplicateRemoval])
            }
            .padding(.horizontal, Spacing.l)
            .padding(.vertical, Spacing.xs)

            content(dups)
            Divider()
            ReviewFooter(count: dups.selectedCount, bytes: dups.selectedBytes, buttonTitle: "Review & Move Copies to Trash…",
                         disabled: model.operations.isExecuting || dups.isScanning) {
                let estimated = dups.selectedBytes
                Task {
                    await model.operations.review(.duplicateRemoval, title: "Duplicate copies", estimatedBytes: estimated,
                                                  items: { dups.removalItems(manifestId: $0) }) {
                        if case .finished(let manifest) = model.operations.phase { dups.removeProcessed(manifest) }
                    }
                }
            }
        }
        .navigationTitle("Duplicates")
    }

    private func controls(_ dups: DuplicatesModel) -> some View {
        HStack(spacing: Spacing.s) {
            Menu {
                ForEach(model.access.locations) { loc in
                    Button(loc.displayPath) { dups.locationID = loc.id }
                }
                if !model.access.locations.isEmpty { Divider() }
                Button("Choose Folder…") {
                    Task {
                        await model.chooseAndAddLocation()
                        dups.locationID = model.selectedLocationID
                    }
                }
            } label: {
                Label(location?.displayPath ?? "Choose a folder", systemImage: "folder")
            }
            .frame(maxWidth: 260)
            .disabled(dups.isScanning)

            Picker("Minimum size", selection: Binding(get: { dups.minimumSizeMB }, set: { dups.minimumSizeMB = $0 })) {
                ForEach([1, 10, 50, 100, 500], id: \.self) { Text("≥ \($0) MB").tag($0) }
            }
            .fixedSize()
            .disabled(dups.isScanning)

            Spacer()
            if dups.isScanning {
                ProgressView().controlSize(.small)
                Text(progressText(dups.progress)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                Button("Stop") { dups.cancel() }
            } else {
                Button(dups.result == nil ? "Find Duplicates" : "Search Again") {
                    if let location { dups.scan(location: location, access: model.access, policy: model.operations.policy,
                                                exclusions: model.settings.exclusions) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(location == nil || model.operations.isExecuting)
            }
        }
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.s)
    }

    private func progressText(_ progress: DuplicateProgress?) -> String {
        guard let progress else { return "Listing files…" }
        switch progress.stage {
        case .listing: return "Listing files… \(progress.processed.formatted())"
        case .comparing: return "Comparing \(progress.processed.formatted()) of \(progress.total.formatted())"
        case .verifying: return "Verifying \(progress.processed.formatted()) of \(progress.total.formatted())"
        }
    }

    private func summary(_ result: DuplicateScanResult) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.xl) {
                Metric(label: "Groups", value: result.groups.count.formatted())
                Metric(label: "Up to", value: ByteFormat.string(result.reclaimableBytes), caption: "if one copy of each is kept")
                Metric(label: "Files compared", value: result.filesConsidered.formatted())
            }
            Text("Every group was verified with a full SHA-256 content hash. Savings are estimates: APFS clones can share storage, and space is freed only after the Trash is emptied. Hard-linked files (\(result.hardLinksIgnored)) are never offered.")
                .font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            if !result.isComplete {
                InlineBanner(kind: .warning, title: "\(result.inaccessibleItems) item(s) could not be read",
                             message: "Some duplicates may be missing from this list.")
            }
        }
    }

    @ViewBuilder
    private func content(_ dups: DuplicatesModel) -> some View {
        if dups.groups.isEmpty {
            ContentUnavailableView {
                Label(dups.isScanning ? "Searching…" : (dups.result == nil ? "Find files with identical content" : "No duplicates found"),
                      systemImage: "doc.on.doc")
            } description: {
                Text("Files are compared by size, then by content hash. Nothing is removed automatically — you choose which copy to keep. App libraries, packages, Git data and your Library folder are never searched.")
            }
        } else {
            List {
                ForEach(dups.groups) { group in
                    Section {
                        ForEach(group.files) { file in
                            DuplicateFileRow(file: file, isKeeper: dups.keeper(for: group) == file.path,
                                             isSelected: Binding(
                                                get: { dups.selection.contains(file.path) },
                                                set: { if $0 { dups.selection.insert(file.path) } else { dups.selection.remove(file.path) } }),
                                             onKeep: { dups.setKeeper(file.path, for: group) })
                        }
                    } header: {
                        HStack {
                            Text("\(group.files.count) copies · \(ByteFormat.string(group.sizeBytes)) each")
                            Spacer()
                            Text("Up to \(ByteFormat.string(group.reclaimableBytes))").monospacedDigit()
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
    }
}

private struct DuplicateFileRow: View {
    let file: DuplicateFile
    let isKeeper: Bool
    @Binding var isSelected: Bool
    let onKeep: () -> Void

    var body: some View {
        HStack(spacing: Spacing.s) {
            Toggle("", isOn: $isSelected)
                .toggleStyle(.checkbox).labelsHidden()
                .disabled(isKeeper || !OperationsModel.canModifyFiles)
                .accessibilityLabel("Move \(file.name) to the Trash")
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name).font(.callout.weight(isKeeper ? .semibold : .regular)).lineLimit(1)
                Text(PathUtilities.abbreviatingHome(file.path)).font(.caption.monospaced()).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if let modified = file.modifiedAt {
                Text(modified.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary)
            }
            if isKeeper {
                StatusBadge(text: "Keep", symbol: "star.fill", tint: .green)
            } else {
                Button("Keep This") { onKeep() }.controlSize(.small)
            }
        }
        .contextMenu {
            Button("Reveal in Finder") { FinderActions.reveal([file.path]) }
            Button("Copy Path") { FinderActions.copy([file.path]) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(isKeeper ? "kept copy" : (isSelected ? "will be moved to the Trash" : "kept"))
    }
}
