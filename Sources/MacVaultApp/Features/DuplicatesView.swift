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
            ScreenHeader(item: .duplicates, subtitle: subtitle(dups)) { controls(dups) }

            VStack(alignment: .leading, spacing: Spacing.s) {
                OperationStatusPanel(types: [.duplicateRemoval])
                if let error = dups.error { InlineBanner(kind: .error, title: "Search could not finish", message: error) }
                if let result = dups.result, !result.isComplete {
                    InlineBanner(kind: .warning, title: "\(result.inaccessibleItems) item(s) could not be read",
                                 message: "Some duplicates may be missing from this list.")
                }
                OperationHistoryList(types: [.duplicateRemoval])
                if let result = dups.result, !dups.groups.isEmpty { summary(result, dups) }
                content(dups)
            }
            .padding(.horizontal, Spacing.l)
            .padding(.bottom, Spacing.m)
            .frame(maxHeight: .infinity, alignment: .top)

            // Nothing to review before the first search, so no footer either.
            if !dups.groups.isEmpty {
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
        }
        .navigationTitle("Duplicates")
    }

    private func subtitle(_ dups: DuplicatesModel) -> String {
        guard let location else { return "Files with identical content" }
        return "Identical files in \(location.displayPath)"
    }

    @ViewBuilder
    private func controls(_ dups: DuplicatesModel) -> some View {
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
            Label((location?.displayName ?? "Choose a folder").middleTruncated(24), systemImage: "folder")
        }
        .fixedSize()
        .disabled(dups.isScanning)
        .help(location.map { "Folder to search: \($0.path)" } ?? "Choose a folder to search")

        Picker("Minimum size", selection: Binding(get: { dups.minimumSizeMB }, set: { dups.minimumSizeMB = $0 })) {
            ForEach([1, 10, 50, 100, 500], id: \.self) { Text("≥ \($0) MB").tag($0) }
        }
        .labelsHidden()
        .fixedSize()
        .disabled(dups.isScanning)
        .help("Only files at least this large are compared")

        if dups.isScanning {
            ProgressView().controlSize(.small)
            Text(progressText(dups.progress)).font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            Button("Stop") { dups.cancel() }
                .help("Stop searching. Nothing has been changed.")
        } else if dups.result != nil {
            // Before the first search the start screen holds the only button.
            Button("Search Again") {
                if let location { dups.scan(location: location, access: model.access, policy: model.operations.policy,
                                            exclusions: model.settings.exclusions) }
            }
            .disabled(location == nil || model.operations.isExecuting)
            .help(location == nil ? "Choose a folder first." : "Compare files by size, then by content again. Read-only.")
        }
    }

    private func progressText(_ progress: DuplicateProgress?) -> String {
        guard let progress else { return "Listing files…" }
        switch progress.stage {
        case .listing: return "Listing files… \(progress.processed.formatted())"
        case .comparing: return "Comparing \(progress.processed.formatted()) of \(progress.total.formatted())"
        case .verifying: return "Verifying \(progress.processed.formatted()) of \(progress.total.formatted())"
        }
    }

    private func summary(_ result: DuplicateScanResult, _ dups: DuplicatesModel) -> some View {
        let groups = result.groups.sorted { $0.reclaimableBytes > $1.reclaimableBytes }
        return Card("Found", symbol: "doc.on.doc.fill", tint: Palette.duplicates,
                    info: "Every group was verified with a full SHA-256 content hash. Savings are estimates: APFS clones can share storage, and space is freed only after the Trash is emptied. Hard-linked files (\(result.hardLinksIgnored)) are never offered.") {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: Spacing.l) {
                    totals(result, dups).frame(width: Dimensions.summaryTotalsWidth, alignment: .leading)
                    CategoryBars(segments: groups.prefix(4).enumerated().map { index, group in
                        ChartSegment(id: group.contentHash, label: group.files.first?.name ?? "Group \(index + 1)",
                                     bytes: group.reclaimableBytes,
                                     color: index == 0 ? Palette.duplicates : Palette.series[(index + 1) % Palette.series.count])
                    }, maxRows: 4)
                    .frame(maxWidth: .infinity)
                }
                totals(result, dups)
            }
        }
    }

    private func totals(_ result: DuplicateScanResult, _ dups: DuplicatesModel) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.xxs) {
                Text("Up to").font(.callout).foregroundStyle(.secondary)
                ValueText(value: ByteFormat.string(result.reclaimableBytes), size: .tile)
            }
            Text("\(counted(result.groups.count, "group")) · \(counted(result.filesConsidered, "file")) compared")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            Text(dups.selectedCount == 0 ? "Nothing selected" : "\(dups.selectedCount) selected · \(ByteFormat.string(dups.selectedBytes))")
                .font(.caption.weight(.medium)).monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func content(_ dups: DuplicatesModel) -> some View {
        if dups.groups.isEmpty && dups.isScanning {
            LoadingState(title: progressText(dups.progress),
                         message: "Files are compared by size, then by content hash. Nothing is changed.")
        } else if dups.groups.isEmpty, dups.result != nil {
            // "Search Again" is in the header.
            EmptyState(title: "No duplicates found", symbol: "doc.on.doc",
                       message: "No files of at least \(dups.minimumSizeMB) MB with identical content were found in \(location?.displayPath ?? "this folder"). Lower the minimum size or choose another folder to search again.")
        } else if dups.groups.isEmpty {
            StartScreen(
                item: .duplicates, title: "Find files with identical content",
                message: "Files of at least \(dups.minimumSizeMB) MB in the chosen folder are compared by size, then by content. Every group is confirmed with a full SHA-256 hash before it is listed, and you choose which copy to keep.",
                actionTitle: "Find Duplicates",
                actionDisabled: location == nil || model.operations.isExecuting,
                actionHelp: location == nil ? "Choose a folder first." : "Compare files by size, then by content. Read-only.",
                note: location.map { "In \($0.displayPath) · files ≥ \(dups.minimumSizeMB) MB" } ?? "Choose a folder above",
                checksTitle: "How files are compared",
                checks: [
                    StartFact("Same size", symbol: "1.circle.fill",
                              detail: "Only files with an identical size can be copies; everything else is skipped without being read."),
                    StartFact("Same content", symbol: "2.circle.fill",
                              detail: "Candidates are hashed and grouped: the first bytes decide quickly, a full SHA-256 confirms each group."),
                    StartFact("You keep one", symbol: "3.circle.fill",
                              detail: "Each group suggests a copy to keep. Change it with Keep This before you review the rest."),
                ],
                safety: [
                    StartFact("App libraries and packages", symbol: "shippingbox",
                              detail: "Apps, photo libraries and other packages are never searched inside."),
                    StartFact("Git data and node_modules", symbol: "arrow.triangle.branch",
                              detail: "Version control data and dependency folders are skipped."),
                    StartFact("Your Library folder", symbol: "folder.fill",
                              detail: "App data in ~/Library is never searched for duplicates."),
                    StartFact("Hard-linked files", symbol: "link",
                              detail: "They already share one copy on disk, so removing one frees nothing; they are never offered."),
                ]) {
                    if let location {
                        dups.scan(location: location, access: model.access, policy: model.operations.policy,
                                  exclusions: model.settings.exclusions)
                    }
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
                        ListSectionHeader(title: "\(group.files.count) copies · \(ByteFormat.string(group.sizeBytes)) each") {
                            TagPill(text: "Up to \(ByteFormat.string(group.reclaimableBytes))", tint: Palette.duplicates)
                        }
                    }
                }
            }
            .listStyle(.inset)
            .listInCard()
        }
    }
}

private struct DuplicateFileRow: View {
    let file: DuplicateFile
    let isKeeper: Bool
    @Binding var isSelected: Bool
    let onKeep: () -> Void

    private var displayPath: String { PathUtilities.abbreviatingHome(file.path) }

    var body: some View {
        HStack(spacing: Spacing.s) {
            Toggle("", isOn: $isSelected)
                .toggleStyle(.checkbox).labelsHidden()
                .disabled(isKeeper || !OperationsModel.canModifyFiles)
                .accessibilityLabel(isKeeper ? "Kept copy \(displayPath)" : "Move \(displayPath) to the Trash")
                // A hint: SwiftUI keeps a checkbox's accessibility value as its checked state.
                .accessibilityHint(isKeeper ? "Kept copy" : (isSelected ? "Will be moved to the Trash" : "Kept"))
                .accessibilityIdentifier("dup-\(file.path)")
            VStack(alignment: .leading, spacing: Spacing.xxs / 2) {
                Text(file.name).font(isKeeper ? .rowTitle.weight(.semibold) : .rowTitle).lineLimit(1)
                Text(displayPath).font(.smallPath).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).help(file.path)
            }
            Spacer()
            if let modified = file.modifiedAt {
                Text(modified.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    .help("Modified \(modified.shortDateTime)")
            }
            // The badge and the button share one column width, so the dates beside them line up.
            Group {
                if isKeeper {
                    StatusBadge(text: "Keep", symbol: "star.fill", tint: Palette.success)
                } else {
                    Button("Keep This") { onKeep() }.controlSize(.small)
                        // Every row has this button, so its label names the file it keeps.
                        .accessibilityLabel("Keep \(displayPath)")
                        .accessibilityIdentifier("keep-\(file.path)")
                        .help("Keep this copy and offer the others for removal")
                }
            }
            .frame(minWidth: Dimensions.rowActionWidth, alignment: .trailing)
        }
        .contextMenu {
            Button("Reveal in Finder") { FinderActions.reveal([file.path]) }
            Button("Copy Path") { FinderActions.copy([file.path]) }
        }
        // Children stay separate so the checkbox and "Keep This" remain their own controls.
        .accessibilityElement(children: .contain)
    }
}
