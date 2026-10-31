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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScreenHeader(item: .analyzer, subtitle: "Read-only scans of folders you choose") { controls }
            content
        }
        .navigationTitle("Storage Analyzer")
        .animation(Motion.standard(reduceMotion: reduceMotion), value: model.isScanning)
    }

    // MARK: Controls

    @ViewBuilder
    private var controls: some View {
        Menu {
            ForEach(model.access.locations) { location in
                Button(location.displayPath) { Task { await model.selectLocation(location.id) } }
            }
            if !model.access.locations.isEmpty { Divider() }
            Button("Choose Folder…") { Task { await model.chooseAndAddLocation() } }
        } label: {
            Label((model.selectedLocation?.displayName ?? "Choose a folder").middleTruncated(28), systemImage: "folder")
        }
        .fixedSize()
        .disabled(model.isScanning)
        .help(model.selectedLocation.map { "Folder to scan: \($0.path)" } ?? "Choose a folder to scan")

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
            .fixedSize()
            .disabled(model.isScanning)
            .help("Show an earlier scan of this folder")
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
            .help(model.selectedLocation == nil ? "Choose a folder first." : "Read-only scan. Nothing is moved or deleted.")
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if model.access.locations.isEmpty {
            EmptyState(title: "Choose a folder to analyze", symbol: "folder.badge.plus",
                       message: "MacVault scans only folders you choose and never changes them. Choose your home folder for the broadest view.") {
                Button("Choose Folder…") { Task { await model.chooseAndAddLocation() } }
                    .buttonStyle(.borderedProminent)
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
                    EmptyState(title: "Not scanned yet", symbol: SidebarItem.analyzer.symbol,
                               message: "Scan “\(model.selectedLocation?.displayName ?? "this folder")” to see what uses space inside it. Scans only read; nothing is changed.")
                        .help(model.selectedLocation?.path ?? "")
                }
            }
            .padding(.horizontal, Spacing.l)
            .padding(.bottom, Spacing.m)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: Spacing.xl) { metrics }
                VStack(alignment: .leading, spacing: Spacing.s) { metrics }
            }
            // Total work is unknown during traversal, so progress is indeterminate.
            ProgressView().progressViewStyle(.linear).tint(Palette.analyzer)
            if !progress.currentDirectory.isEmpty {
                PathText(path: progress.currentDirectory, small: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Scan in progress, \(progress.filesVisited) files read")
    }

    @ViewBuilder
    private var metrics: some View {
        Metric(label: "Observed so far", value: bytes(progress.logicalBytes), size: .hero)
        HStack(alignment: .top, spacing: Spacing.l) {
            Metric(label: "Files", value: progress.filesVisited.formatted(), size: .tile)
            Metric(label: "Folders", value: progress.directoriesVisited.formatted(), size: .tile)
            Metric(label: "Not readable", value: progress.inaccessibleItems.formatted(), size: .tile)
        }
        Spacer(minLength: 0)
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
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: Spacing.xl) {
                        hero
                        details
                        Spacer(minLength: 0)
                    }
                    VStack(alignment: .leading, spacing: Spacing.s) {
                        hero
                        details
                    }
                }
                let notes = coverageNotes
                if !notes.isEmpty {
                    Text(notes.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                }
            }
            statusBanner
        }
    }

    private var hero: some View {
        Metric(label: "Observed size", value: bytes(scan.bytesObserved), caption: "Logical sum of files", size: .hero)
    }

    private var details: some View {
        HStack(alignment: .top, spacing: Spacing.l) {
            Metric(label: "Allocated", value: bytes(scan.allocatedBytesObserved), caption: "May exceed use (APFS clones)", size: .tile)
            Metric(label: "Files", value: scan.filesVisited.formatted(),  size: .tile)
            Metric(label: "Folders", value: scan.directoriesVisited.formatted(),  size: .tile)
        }
    }

    @ViewBuilder
    private var statusBanner: some View {
        let unreadable = scan.inaccessibleItems + scan.errorCount
        switch scan.status {
        case .partial:
            InlineBanner(kind: .warning, title: "Scan incomplete — \(unreadable) item\(unreadable == 1 ? "" : "s") could not be accessed",
                         message: "Sizes are lower bounds where items could not be read.",
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
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("Files of \(ByteFormat.string(thresholdBytes)) or more · \(findings.count) found · review only, not assessed for removal")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
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
                .listInCard()
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
            Label(row.name, systemImage: "doc").font(.title3.weight(.semibold))
            Grid(alignment: .leading, horizontalSpacing: Spacing.m, verticalSpacing: Spacing.xs) {
                GridRow { Text("Path").foregroundStyle(.secondary); Text(row.path).textSelection(.enabled) }
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
