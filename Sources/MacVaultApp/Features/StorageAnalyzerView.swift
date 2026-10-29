import SwiftUI
import AppKit
import MacVaultCore

struct StorageAnalyzerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum Mode: String, CaseIterable, Identifiable {
        case largest = "Largest Files"
        case breakdown = "Breakdown"
        var id: String { rawValue }
    }

    @State private var mode: Mode = .breakdown
    @State private var search = ""
    @State private var showIssues = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            controlBar
                .padding(.horizontal, Spacing.l)
                .padding(.vertical, Spacing.s)
            Divider()
            content
        }
        .navigationTitle("Storage Analyzer")
        .animation(Motion.standard(reduceMotion: reduceMotion), value: model.isScanning)
    }

    // MARK: Controls

    private var controlBar: some View {
        HStack(spacing: Spacing.s) {
            Menu {
                ForEach(model.access.locations) { location in
                    Button(location.displayPath) { Task { await model.selectLocation(location.id) } }
                }
                if !model.access.locations.isEmpty { Divider() }
                Button("Choose Folder…") { Task { await model.chooseAndAddLocation() } }
            } label: {
                Label(model.selectedLocation?.displayPath ?? "Choose a folder", systemImage: "folder")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: 360)
            .disabled(model.isScanning)
            .help("Folder to scan")

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
            }

            Spacer()

            if model.isScanning {
                Button(role: .cancel) { model.cancelScan() } label: {
                    Label("Cancel Scan", systemImage: "stop.fill")
                }
                .keyboardShortcut(.cancelAction)
            } else {
                Button {
                    model.startScan()
                } label: {
                    Label(model.displayedScan == nil ? "Scan" : "Scan Again", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.selectedLocation == nil || model.store == nil)
                .help("Read-only scan. Nothing is moved or deleted.")
            }
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if model.access.locations.isEmpty {
            ContentUnavailableView {
                Label("Choose a folder to analyze", systemImage: "folder.badge.plus")
            } description: {
                Text("MacVault scans only folders you choose and never changes them. Choose your home folder for the broadest view.")
            } actions: {
                Button("Choose Folder…") { Task { await model.chooseAndAddLocation() } }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            VStack(alignment: .leading, spacing: Spacing.m) {
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
                    Picker("View", selection: $mode) {
                        ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 320)

                    switch mode {
                    case .largest: LargestFilesTable(findings: model.displayedFindings, search: $search,
                                                     thresholdBytes: model.settings.largeFileThresholdBytes)
                    case .breakdown: BreakdownList(entries: model.displayedAggregates, scan: scan)
                    }
                } else if !model.isScanning {
                    ContentUnavailableView {
                        Label("Not scanned yet", systemImage: "chart.bar.doc.horizontal")
                    } description: {
                        Text("Run a scan to measure what is inside \(model.selectedLocation?.displayPath ?? "this folder").")
                    }
                }
            }
            .padding(Spacing.l)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

// MARK: - Progress

struct ScanProgressPanel: View {
    let progress: ScanProgress

    var body: some View {
        Card {
            HStack(alignment: .center, spacing: Spacing.m) {
                // Total work is unknown during traversal, so progress is indeterminate.
                ProgressView().controlSize(.regular)
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text("Scanning…").font(.headline)
                    Text(PathUtilities.abbreviatingHome(progress.currentDirectory))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Metric(label: "Files", value: progress.filesVisited.formatted())
                Metric(label: "Folders", value: progress.directoriesVisited.formatted())
                Metric(label: "Observed", value: bytes(progress.logicalBytes))
                Metric(label: "Not readable", value: progress.inaccessibleItems.formatted())
                Metric(label: "Elapsed", value: Duration.seconds(progress.elapsedSeconds).formatted(.time(pattern: .minuteSecond)))
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

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                Text(scan.scopeDescription).font(.title2.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                StatusBadge(status: scan.status)
                Spacer()
                Text("Scanned \(scan.startedAt.shortDateTime)").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: Spacing.xl) {
                Metric(label: "Observed size", value: bytes(scan.bytesObserved), caption: "Logical sum of files in scope")
                Metric(label: "Allocated", value: bytes(scan.allocatedBytesObserved), caption: "May exceed physical use (APFS clones)")
                Metric(label: "Files", value: scan.filesVisited.formatted())
                Metric(label: "Folders", value: scan.directoriesVisited.formatted())
            }

            statusBanner

            let notes = coverageNotes
            if !notes.isEmpty {
                Text(notes.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
            }
            Text("A scan reads folders one after another, so it is a series of observations over time rather than an instant snapshot. Scope size is not the same as volume usage.")
                .font(.caption).foregroundStyle(.tertiary)
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
        Card {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Spacing.xxs) {
                    ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
                        HStack {
                            Text(PathUtilities.abbreviatingHome(issue.path)).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(issue.errorDescription ?? description(issue.kind)).foregroundStyle(.secondary)
                        }
                        .font(.caption.monospaced())
                    }
                }
            }
            .frame(maxHeight: 160)
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
            HStack {
                Text("Files of \(ByteFormat.string(thresholdBytes)) or more · \(findings.count) found")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                TextField("Filter by name or folder", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
            }
            if findings.isEmpty {
                ContentUnavailableView("No files at or above \(ByteFormat.string(thresholdBytes))",
                                       systemImage: "doc",
                                       description: Text("Lower the threshold in Settings to list smaller files on the next scan."))
            } else {
                Table(rows, selection: $selection, sortOrder: $sortOrder) {
                    TableColumn("Name", value: \.name) { row in
                        Label(row.name, systemImage: "doc").lineLimit(1)
                    }
                    TableColumn("Size", value: \.size) { row in
                        Text(row.size < 0 ? "Unknown" : ByteFormat.string(row.size)).monospacedDigit()
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
                        Text(row.location).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                    }
                }
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
                Text("Findings are for review only. MacVault has not assessed whether any file is safe to remove.")
                    .font(.caption).foregroundStyle(.tertiary)
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
        .frame(width: 520)
    }
}

// MARK: - Breakdown

struct BreakdownList: View {
    let entries: [DirectoryAggregate]
    let scan: ScanSessionRecord

    var body: some View {
        if entries.isEmpty {
            ContentUnavailableView("Nothing measured", systemImage: "folder",
                                   description: Text("This folder had no readable items when it was scanned."))
        } else {
            let maxBytes = max(entries.map(\.logicalBytes).max() ?? 1, 1)
            List {
                Section {
                    ForEach(entries) { entry in
                        BreakdownRow(entry: entry, fraction: Double(entry.logicalBytes) / Double(maxBytes))
                            .contextMenu {
                                Button("Reveal in Finder") { FinderActions.reveal([entry.path]) }
                                Button("Copy Path") { FinderActions.copy([entry.path]) }
                            }
                    }
                } footer: {
                    Text("Immediate contents of \(scan.scopeDescription), sized from measured files. Entries marked “lower bound” contain items that could not be read. Interactive treemap and drill-down are planned.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
        }
    }
}

struct BreakdownRow: View {
    let entry: DirectoryAggregate
    let fraction: Double

    var body: some View {
        HStack(spacing: Spacing.s) {
            Image(systemName: entry.isDirectory ? "folder.fill" : "doc").foregroundStyle(entry.isDirectory ? Color.accentColor : .secondary)
                .frame(width: 18).accessibilityHidden(true)
            Text(entry.name).lineLimit(1).truncationMode(.middle).frame(minWidth: 140, maxWidth: 260, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.12))
                    Capsule().fill(Color.accentColor.opacity(0.75)).frame(width: max(2, geo.size.width * fraction))
                }
            }
            .frame(height: 6)
            .accessibilityHidden(true)
            Text(ByteFormat.string(entry.logicalBytes)).monospacedDigit().frame(width: 90, alignment: .trailing)
            Text(entry.isDirectory ? "\(entry.fileCount.formatted()) files" : "")
                .font(.caption).foregroundStyle(.secondary).frame(width: 90, alignment: .trailing)
            if !entry.isComplete {
                StatusBadge(text: "Lower bound", symbol: "eye.slash", tint: .orange)
                    .help("\(entry.inaccessibleItems) item(s) inside could not be read")
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(entry.name), \(ByteFormat.string(entry.logicalBytes))\(entry.isComplete ? "" : ", lower bound, \(entry.inaccessibleItems) items not readable")")
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
