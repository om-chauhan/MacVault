import SwiftUI
import AppKit
import MacVaultCore

struct StorageAnalyzerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum Mode: String, CaseIterable, Identifiable {
        case largest = "Largest Files"
        case breakdown = "Breakdown"
        case treemap = "Treemap"
        var id: String { rawValue }
    }

    @State private var mode: Mode = .breakdown
    @State private var search = ""
    @State private var showIssues = false
    @State private var showPathEntry = false
    @State private var locationError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScreenHeader(item: .analyzer, subtitle: "Read-only scans of your Mac or any folder you choose") { controls }
            content
        }
        .navigationTitle("Storage Analyzer")
        .animation(Motion.standard(reduceMotion: reduceMotion), value: model.isScanning)
        .sheet(isPresented: $showPathEntry) {
            PathEntrySheet { path in await model.addLocation(path: path) }
        }
        .alert("Location could not be added", isPresented: Binding(
            get: { locationError != nil }, set: { if !$0 { locationError = nil } }
        )) {
            Button("OK", role: .cancel) { locationError = nil }
        } message: {
            Text(locationError ?? "")
        }
    }

    private func selectWholeMac() {
        Task { locationError = await model.selectWholeMac() }
    }

    // MARK: Controls

    @ViewBuilder
    private var controls: some View {
        Menu {
            Button {
                selectWholeMac()
            } label: {
                Label("Whole Mac (\(AuthorizedLocation.startupDiskName))", systemImage: "internaldrive")
            }
            let folders = model.access.locations.filter { !$0.isWholeVolume }
            if !folders.isEmpty {
                Divider()
                ForEach(folders) { location in
                    Button(location.displayPath) { Task { await model.selectLocation(location.id) } }
                }
            }
            Divider()
            Button("Choose Folder…") { Task { await model.chooseAndAddLocation() } }
            Button("Enter Path…") { showPathEntry = true }
        } label: {
            Label((model.selectedLocation?.displayName ?? "Choose what to scan").middleTruncated(28),
                  systemImage: model.selectedLocation?.isWholeVolume == true ? "internaldrive" : "folder")
        }
        .fixedSize()
        .disabled(model.isScanning)
        .accessibilityIdentifier("scopeMenu")
        .help(model.selectedLocation.map { $0.isWholeVolume ? "Scope: the whole startup disk" : "Folder to scan: \($0.path)" }
              ?? "Choose the whole Mac or a folder to scan")

        let pastScans = model.scans(for: model.selectedLocation)
        if pastScans.count > 1 {
            Menu {
                ForEach(pastScans) { scan in
                    Button("\(scan.startedAt.shortDateTime) — \(scan.status.displayName)") {
                        Task { await model.show(scanID: scan.id) }
                    }
                }
            } label: {
                Label("History", systemImage: "clock.arrow.circlepath")
            }
            // Icon only, so the scope menu, this menu and the Scan button fit beside the status line
            // at the minimum window width; the label stays for VoiceOver and the help.
            .labelStyle(.iconOnly)
            .fixedSize()
            .disabled(model.isScanning)
            .accessibilityLabel("Scan history")
            .help("Show an earlier scan of this folder (\(pastScans.count) scans)")
        }

        if model.isScanning {
            Button(role: .cancel) { model.cancelScan() } label: {
                Label("Cancel Scan", systemImage: "stop.fill")
            }
            .keyboardShortcut(.cancelAction)
            .help("Stop the scan (⌘.). What was read so far is kept and marked Cancelled.")
        } else {
            Button {
                model.startScan()
            } label: {
                Label(model.displayedScan == nil ? "Scan" : "Scan Again", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.selectedLocation == nil || model.store == nil)
            .accessibilityIdentifier("scanButton")
            .help(model.selectedLocation == nil ? "Choose what to scan first." : "Read-only scan. Nothing is moved or deleted.")
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if model.access.locations.isEmpty {
            EmptyState(title: "Choose what to analyze", symbol: "folder.badge.plus",
                       message: "Scan the whole Mac to see where all the space goes, or pick a single folder or path. Scans only read; nothing is changed.") {
                HStack(spacing: Spacing.s) {
                    Button {
                        selectWholeMac()
                    } label: {
                        Label("Whole Mac", systemImage: "internaldrive")
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Choose Folder…") { Task { await model.chooseAndAddLocation() } }
                    Button("Enter Path…") { showPathEntry = true }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: Spacing.s) {
                if case .failed(let message) = model.scanPhase {
                    InlineBanner(kind: .error, title: "Scan could not run", message: message,
                                 actionTitle: "Dismiss") { model.dismissScanError() }
                }
                ForEach(model.lastWarnings, id: \.self) { warning in
                    InlineBanner(kind: .warning, title: "Not everything was recorded", message: warning)
                }
                if case .running(_, let progress) = model.scanPhase {
                    ScanProgressPanel(progress: progress)
                }
                if let scan = model.displayedScan {
                    ScanSummaryHeader(scan: scan, issues: model.displayedIssues, showIssues: $showIssues)
                    HStack(spacing: Spacing.s) {
                        Picker("View", selection: $mode) {
                            ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        Spacer(minLength: Spacing.s)
                        if mode == .largest && !model.displayedFindings.isEmpty {
                            TextField("Filter by name or folder", text: $search)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: Dimensions.searchFieldWidth)
                        }
                    }

                    switch mode {
                    case .largest: LargestFilesTable(findings: model.displayedFindings, search: $search,
                                                     thresholdBytes: model.settings.largeFileThresholdBytes)
                    // One view for both styles, so the drill-down position survives switching between them.
                    case .breakdown, .treemap:
                        DrillDownBreakdown(scan: scan, aggregates: model.displayedAggregates,
                                           style: mode == .treemap ? .treemap : .list)
                    }
                } else if model.isScanning {
                    LoadingState(title: "Measuring \(model.selectedLocation?.displayName ?? "the folder")…",
                                 message: "The breakdown, treemap and largest files appear when the scan finishes. Nothing is changed.")
                } else {
                    // The Scan button is in the header, where it is on every visit.
                    let wholeMac = model.selectedLocation?.isWholeVolume == true
                    EmptyState(title: "Not scanned yet", symbol: SidebarItem.analyzer.symbol,
                               message: wholeMac
                                   ? "Scan the whole Mac to see what uses space on \(model.selectedLocation?.displayName ?? "the startup disk"). This reads every folder, so it takes longer than a single folder. Scans only read; nothing is changed."
                                   : "Scan “\(model.selectedLocation?.displayName ?? "this folder")” to see what uses space inside it. Scans only read; nothing is changed.")
                        .help(model.selectedLocation?.path ?? "")
                }
            }
            .padding(.horizontal, Spacing.l)
            .padding(.bottom, Spacing.m)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

// MARK: - Path entry

/// Lets the user type or paste a folder path instead of using the open panel. "~" is accepted.
struct PathEntrySheet: View {
    /// Adds the path; returns a message when it cannot be used.
    let add: (String) async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var path = ""
    @State private var error: String?
    @State private var isAdding = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            SheetHeader(title: "Scan a specific path", subtitle: "Added to the folders MacVault may scan",
                        symbol: "folder.badge.plus", tint: Palette.analyzer)
            Text("Enter the full path of a folder on this Mac or an attached volume. MacVault only reads it; nothing is changed.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("/Users/Shared or ~/Downloads", text: $path)
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
                .accessibilityIdentifier("pathField")
                .onSubmit { submit() }
            if let error {
                InlineBanner(kind: .error, title: "Path could not be used", message: error)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add and Select") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(path.trimmingCharacters(in: .whitespaces).isEmpty || isAdding)
                    .accessibilityIdentifier("addPathButton")
            }
        }
        .padding(Spacing.l)
        .frame(width: Dimensions.sheetWidth - Spacing.xl * 4)
    }

    private func submit() {
        guard !isAdding else { return }
        isAdding = true
        Task {
            let message = await add(path)
            isAdding = false
            if let message { error = message } else { dismiss() }
        }
    }
}

// MARK: - Progress

struct ScanProgressPanel: View {
    let progress: ScanProgress

    var body: some View {
        Card("Scanning…", symbol: "magnifyingglass", tint: Palette.analyzer,
             trailing: AnyView(Text(Duration.seconds(progress.elapsedSeconds).formatted(.time(pattern: .minuteSecond)))
                .font(.rowValue).monospacedDigit().foregroundStyle(.secondary))) {
            MetricGrid(items: [
                MetricItem("Observed so far", value: bytes(progress.logicalBytes), size: .hero),
                MetricItem("Files", value: progress.filesVisited.formatted()),
                MetricItem("Folders", value: progress.directoriesVisited.formatted()),
                MetricItem("Not readable", value: progress.inaccessibleItems.formatted()),
            ])
            // Total work is unknown during traversal, so progress is indeterminate.
            ProgressView().progressViewStyle(.linear).tint(Palette.analyzer).controlSize(.small)
            if !progress.currentDirectory.isEmpty {
                PathText(path: progress.currentDirectory, small: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Scan in progress, \(progress.filesVisited) files read")
    }
}

// MARK: - Summary

struct ScanSummaryHeader: View {
    let scan: ScanSessionRecord
    let issues: [ScanIssue]
    @Binding var showIssues: Bool

    private var folderName: String {
        let name = (scan.scopeDescription as NSString).lastPathComponent
        return name.isEmpty ? scan.scopeDescription : name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Card(folderName, symbol: "folder.fill", tint: Palette.analyzer,
                 info: "\(scan.scopeDescription)\n\nA scan reads folders one after another, so it is a series of observations over time rather than an instant snapshot. Scope size is not the same as volume usage.",
                 trailing: AnyView(HStack(spacing: Spacing.xs) {
                     Text("Scanned \(scan.startedAt.shortDateTime)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                     StatusBadge(status: scan.status)
                 })) {
                MetricGrid(items: [
                    MetricItem("Observed size", value: bytes(scan.bytesObserved), caption: "Logical sum of files", size: .hero),
                    MetricItem("Allocated", value: bytes(scan.allocatedBytesObserved), caption: "May exceed use (APFS clones)"),
                    MetricItem("Files", value: scan.filesVisited.formatted()),
                    MetricItem("Folders", value: scan.directoriesVisited.formatted()),
                ])
                let notes = coverageNotes
                if !notes.isEmpty {
                    Text(notes.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                }
            }
            statusBanner
        }
    }

    @ViewBuilder
    private var statusBanner: some View {
        let unreadable = scan.inaccessibleItems + scan.errorCount
        switch scan.status {
        case .partial:
            InlineBanner(kind: .warning, title: "Scan incomplete — \(unreadable) item\(unreadable == 1 ? "" : "s") could not be accessed",
                         message: scan.rootPath == ScanConfiguration.wholeVolumeRoot
                             ? "Sizes are lower bounds where items could not be read. macOS protects some folders (Mail, Messages, Safari, other users): grant MacVault Full Disk Access in System Settings › Privacy & Security to include them."
                             : "Sizes are lower bounds where items could not be read.",
                         actionTitle: issues.contains { $0.kind != .mountPointSkipped } ? (showIssues ? "Hide" : "Show Items") : nil) {
                showIssues.toggle()
            }
            if showIssues { IssueList(issues: issues.filter { $0.kind != .mountPointSkipped }, total: unreadable) }
        case .cancelled:
            InlineBanner(kind: .info, title: "Scan cancelled",
                         message: "Only the part of the folder read before cancelling is shown.")
        case .interrupted:
            InlineBanner(kind: .warning, title: "Scan interrupted",
                         message: scan.failureReason ?? "MacVault stopped before this scan finished.")
        case .failed:
            InlineBanner(kind: .error, title: "Scan failed", message: scan.failureReason)
        case .running:
            EmptyView()
        case .completed:
            EmptyView()
        }
    }

    private var coverageNotes: [String] {
        var notes: [String] = []
        if scan.excludedItems > 0 { notes.append("\(scan.excludedItems) excluded by settings") }
        if scan.symlinksSkipped > 0 { notes.append("\(scan.symlinksSkipped) symbolic links not followed") }
        if scan.mountPointsSkipped > 0 { notes.append("\(scan.mountPointsSkipped) other volumes not entered") }
        return notes
    }
}

struct IssueList: View {
    let issues: [ScanIssue]
    let total: Int

    var body: some View {
        Card("Not Readable", symbol: "eye.slash.fill", tint: Palette.warning) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Spacing.xxs) {
                    ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
                        HStack(spacing: Spacing.xs) {
                            PathText(path: issue.path, small: true)
                            Spacer(minLength: Spacing.xs)
                            Text(issue.errorDescription ?? description(issue.kind)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(maxHeight: Dimensions.boundedListHeight)
            .fixedSize(horizontal: false, vertical: true)
            if total > issues.count {
                Text("Showing \(issues.count) of \(total). All are counted in the totals above.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func description(_ kind: ScanIssueKind) -> String {
        switch kind {
        case .unreadableDirectory: return "Folder not readable"
        case .metadataUnavailable: return "Details unavailable"
        case .undecodableName: return "Name could not be read"
        case .mountPointSkipped: return "Other volume"
        }
    }
}

// MARK: - Largest files

struct FileRow: Identifiable, Hashable {
    let id: String
    let path: String
    let name: String
    let location: String
    let size: Int64
    let allocated: Int64
    let modified: Date

    init(_ finding: FileFinding) {
        id = finding.id
        path = finding.path
        name = finding.name
        location = PathUtilities.abbreviatingHome((finding.path as NSString).deletingLastPathComponent)
        size = finding.logicalSizeBytes ?? -1
        allocated = finding.allocatedSizeBytes ?? -1
        modified = finding.modifiedAt ?? .distantPast
    }
}

struct LargestFilesTable: View {
    let findings: [FileFinding]
    @Binding var search: String
    let thresholdBytes: Int64

    @State private var sortOrder = [KeyPathComparator(\FileRow.size, order: .reverse)]
    @State private var selection: Set<FileRow.ID> = []
    @State private var inspected: FileRow?

    private var rows: [FileRow] {
        let all = findings.map(FileRow.init)
        let filtered = search.isEmpty ? all : all.filter {
            $0.name.localizedCaseInsensitiveContains(search) || $0.location.localizedCaseInsensitiveContains(search)
        }
        return filtered.sorted(using: sortOrder)
    }

    var body: some View {
        Card("Largest Files", symbol: "doc.fill", tint: Palette.analyzer,
             info: "The largest files recorded by the scan (up to 500). Listed for review only; they are not assessed for removal.",
             trailing: AnyView(Text("Files of \(ByteFormat.string(thresholdBytes)) or more · \(counted(findings.count, "file"))")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)),
             flush: true) {
            if findings.isEmpty {
                EmptyState(title: "No files at or above \(ByteFormat.string(thresholdBytes))", symbol: "doc",
                           message: "Lower the threshold in Settings to list smaller files on the next scan.")
            } else if rows.isEmpty {
                EmptyState(title: "No matching files", symbol: "magnifyingglass",
                           message: "No file name or folder contains “\(search)”.")
            } else {
                Table(rows, selection: $selection, sortOrder: $sortOrder) {
                    TableColumn("Name", value: \.name) { row in
                        Label(row.name, systemImage: "doc.fill").lineLimit(1).help(row.path)
                    }
                    TableColumn("Size", value: \.size) { row in
                        Text(row.size < 0 ? "Unknown" : ByteFormat.string(row.size)).font(.rowValue).monospacedDigit()
                    }
                    .width(min: 80, ideal: 90)
                    TableColumn("Allocated", value: \.allocated) { row in
                        Text(row.allocated < 0 ? "Unknown" : ByteFormat.string(row.allocated)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .width(min: 80, ideal: 90)
                    TableColumn("Modified", value: \.modified) { row in
                        Text(row.modified == .distantPast ? "Unknown" : row.modified.formatted(date: .abbreviated, time: .omitted))
                    }
                    .width(min: 90, ideal: 110)
                    TableColumn("Folder", value: \.location) { row in
                        Text(row.location).font(.smallPath).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                            .help(row.location)
                    }
                }
                .scrollContentBackground(.hidden)
                .contextMenu(forSelectionType: FileRow.ID.self) { ids in
                    let picked = rows.filter { ids.contains($0.id) }
                    Button("Reveal in Finder") { FinderActions.reveal(picked.map(\.path)) }
                    Button("Copy Path") { FinderActions.copy(picked.map(\.path)) }
                    if picked.count == 1, let one = picked.first {
                        Button("Show Details") { inspected = one }
                    }
                } primaryAction: { ids in
                    FinderActions.reveal(rows.filter { ids.contains($0.id) }.map(\.path))
                }
            }
        }
        .environment(\.cardFillsHeight, true)
        .sheet(item: $inspected) { row in
            FileDetailSheet(row: row)
        }
    }
}

struct FileDetailSheet: View {
    let row: FileRow
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            SheetHeader(title: row.name, subtitle: row.location, symbol: "doc.fill", tint: Palette.analyzer)
            Grid(alignment: .leading, horizontalSpacing: Spacing.m, verticalSpacing: Spacing.xs) {
                GridRow { Text("Path").foregroundStyle(.secondary); Text(row.path).font(.path).textSelection(.enabled) }
                GridRow { Text("Size").foregroundStyle(.secondary); Text(row.size < 0 ? "Unknown" : ByteFormat.string(row.size)) }
                GridRow { Text("Allocated").foregroundStyle(.secondary); Text(row.allocated < 0 ? "Unknown" : ByteFormat.string(row.allocated)) }
                GridRow { Text("Modified").foregroundStyle(.secondary); Text(row.modified == .distantPast ? "Unknown" : row.modified.shortDateTime) }
                GridRow { Text("Assessment").foregroundStyle(.secondary); Text("Not assessed — review only") }
            }
            .font(.callout)
            Text("Values were observed during the scan and may have changed since.").font(.caption).foregroundStyle(.tertiary)
            HStack {
                Button("Reveal in Finder") { FinderActions.reveal([row.path]) }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(Spacing.l)
        .frame(width: Dimensions.sheetWidth - Spacing.xl * 4)
    }
}

// MARK: - Finder

enum FinderActions {
    static func reveal(_ paths: [String]) {
        let urls = paths.map { URL(fileURLWithPath: $0) }
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    static func copy(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
    }
}
