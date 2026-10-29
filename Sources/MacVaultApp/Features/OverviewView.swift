import SwiftUI
import Charts
import MacVaultCore

struct OverviewView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                header

                if let error = model.startupError {
                    InlineBanner(kind: .error, title: "Local database unavailable", message: error)
                }
                if model.reconciledOnLaunch.interruptedScans > 0 {
                    InlineBanner(kind: .warning,
                                 title: "\(model.reconciledOnLaunch.interruptedScans) scan(s) were interrupted",
                                 message: "MacVault stopped before these scans finished. They are marked Interrupted; their counts reflect the last saved progress only.")
                }
                if model.reconciledOnLaunch.interruptedOperations > 0 {
                    InlineBanner(kind: .warning,
                                 title: "\(model.reconciledOnLaunch.interruptedOperations) Trash operation(s) were interrupted",
                                 message: "MacVault stopped while moving items to the Trash. Each list’s history shows which items were moved; the item being processed at that moment may also be in the Trash.",
                                 actionTitle: "Open Activity") { model.selection = .activity }
                }

                volumesSection

                RecommendationsCard()

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: Spacing.m, alignment: .top)],
                          alignment: .leading, spacing: Spacing.m) {
                    LastScanCard()
                    AccessCoverageCard()
                    RecentActivityCard()
                }
            }
            .padding(Spacing.l)
            .frame(maxWidth: 1100, alignment: .leading)
        }
        .navigationTitle("Overview")
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await model.refreshVolumes() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Read volume capacity again")
                .disabled(model.isRefreshingVolumes)
            }
        }
    }

    private var header: some View {
        SectionTitle(title: "Overview", subtitle: "System-reported capacity, your scans and recent activity.")
    }

    @ViewBuilder
    private var volumesSection: some View {
        if let error = model.volumeError {
            InlineBanner(kind: .error, title: "Volume information unavailable", message: error,
                         actionTitle: "Retry") { Task { await model.refreshVolumes() } }
        } else if model.volumes.isEmpty {
            Card { HStack { ProgressView().controlSize(.small); Text("Reading volume information…").foregroundStyle(.secondary) } }
        } else {
            VStack(spacing: Spacing.m) {
                ForEach(model.volumes) { volume in
                    VolumeCapacityCard(volume: volume, history: model.history[volume.id] ?? [])
                }
            }
        }
    }
}

// MARK: - Volume capacity

struct VolumeCapacityCard: View {
    let volume: VolumeObservation
    let history: [StorageSnapshot]

    private struct Segment: Identifiable {
        let id: String
        let bytes: Double
    }

    var body: some View {
        Card(volume.displayName, symbol: volume.isInternal == false || volume.isRemovable == true ? "externaldrive" : "internaldrive",
             trailing: AnyView(tags)) {
            if let used = volume.usedBytes, let total = volume.totalBytes, let available = volume.availableBytes {
                Chart([Segment(id: "Used", bytes: Double(used)), Segment(id: "Available", bytes: Double(available))]) { segment in
                    BarMark(x: .value("Bytes", segment.bytes), y: .value("Volume", volume.displayName))
                        .foregroundStyle(by: .value("Kind", segment.id))
                }
                .chartForegroundStyleScale(["Used": Color.accentColor, "Available": Color.secondary.opacity(0.22)])
                .chartXScale(domain: 0...Double(total))
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .chartLegend(.hidden)
                .frame(height: 16)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .accessibilityLabel("Capacity of \(volume.displayName)")
                .accessibilityValue("\(bytes(used)) used of \(bytes(total)), \(bytes(available)) available")

                HStack(alignment: .top, spacing: Spacing.xl) {
                    Metric(label: "Available", value: bytes(available))
                    Metric(label: "Used", value: bytes(used), caption: "Total − available")
                    Metric(label: "Capacity", value: bytes(total))
                    if let important = volume.availableForImportantUsageBytes, important != available {
                        Metric(label: "Available incl. purgeable", value: bytes(important),
                               caption: "macOS estimate for important use")
                    }
                }
            } else {
                Text("This volume does not report capacity.").foregroundStyle(.secondary)
            }

            if history.count >= 2 {
                Divider()
                HistoryChart(history: history)
            }

            Text("Source: \(volume.source) · Observed \(volume.observedAt.shortDateTime)\(volume.mountPath.map { " · \($0)" } ?? "")")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var tags: some View {
        HStack(spacing: Spacing.xs) {
            if volume.isReadOnly == true { StatusBadge(text: "Read-only", symbol: "lock", tint: .secondary) }
            if volume.isRemovable == true { StatusBadge(text: "Removable", symbol: "eject", tint: .secondary) }
            if let format = volume.formatDescription {
                Text(format).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Available space over time. Plots only recorded observations; gaps are not interpolated into fake points.
struct HistoryChart: View {
    let history: [StorageSnapshot]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("Available space history").font(.subheadline.weight(.medium))
            Chart(history.filter { $0.availableBytes != nil }) { snap in
                LineMark(x: .value("Observed", snap.observedAt), y: .value("Available", Double(snap.availableBytes ?? 0)))
                    .interpolationMethod(.linear)
                PointMark(x: .value("Observed", snap.observedAt), y: .value("Available", Double(snap.availableBytes ?? 0)))
                    .symbolSize(18)
            }
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel { if let v = value.as(Double.self) { Text(ByteFormat.string(Int64(v))) } }
                }
            }
            .frame(height: 120)
            .accessibilityLabel("Available space history")
            .accessibilityValue(summary)
            Text("\(history.count) observations, recorded at most hourly while MacVault is open. Lines connect recorded points only.")
                .font(.caption).foregroundStyle(.tertiary)
        }
    }

    private var summary: String {
        guard let first = history.first, let last = history.last,
              let a = first.availableBytes, let b = last.availableBytes else { return "Insufficient data" }
        return "From \(ByteFormat.string(a)) on \(first.observedAt.shortDateTime) to \(ByteFormat.string(b)) on \(last.observedAt.shortDateTime)"
    }
}

// MARK: - Recommendations

/// Every recommendation is derived from real observations; none is a generic "boost" suggestion.
struct RecommendationsCard: View {
    @Environment(AppModel.self) private var model

    private struct Item: Identifiable {
        let id: String
        let symbol: String
        let title: String
        let detail: String
        let actionTitle: String?
        let action: (() -> Void)?
    }

    private var items: [Item] {
        var result: [Item] = []
        for v in model.volumes {
            if let fraction = v.usedFraction, fraction >= 0.9, let available = v.availableBytes {
                result.append(Item(id: "low-\(v.id)", symbol: "exclamationmark.triangle",
                                   title: "\(v.displayName) has \(bytes(available)) available",
                                   detail: "More than 90% of this volume is in use (system-reported). Scanning large folders shows what takes space; the Cleaner lists caches and logs you can review.",
                                   actionTitle: "Open Analyzer", action: { model.selection = .analyzer }))
                if v.mountPath == "/" {
                    result.append(Item(id: "cleaner-\(v.id)", symbol: "sparkles.rectangle.stack",
                                       title: "Review caches, logs and developer files",
                                       detail: "Nothing is removed until you approve a list. Approved items go to the Trash.",
                                       actionTitle: "Open Cleaner", action: { model.selection = .cleaner }))
                }
            }
        }
        if model.access.locations.isEmpty {
            result.append(Item(id: "no-locations", symbol: "folder.badge.plus", title: "Choose a folder to scan",
                               detail: "MacVault only scans folders you choose. Nothing is changed or deleted.",
                               actionTitle: "Choose Folder…", action: { Task { await model.chooseAndAddLocation() } }))
        }
        for location in model.access.locations where model.access.status(of: location) == .needsReselection {
            result.append(Item(id: "stale-\(location.id)", symbol: "folder.badge.questionmark",
                               title: "Access to \(location.displayName) needs renewing",
                               detail: "macOS no longer accepts the saved access for this folder. Choose it again to keep scanning it.",
                               actionTitle: "Settings", action: { model.selection = .settings }))
        }
        if let last = model.recentScans.first, last.status == .partial {
            result.append(Item(id: "partial-\(last.id)", symbol: "eye.slash",
                               title: "Last scan could not read \(last.inaccessibleItems + last.errorCount) item(s)",
                               detail: "Sizes for \(last.scopeDescription) are a lower bound. Granting access to those folders gives a complete picture.",
                               actionTitle: "Review", action: { model.selection = .analyzer }))
        }
        return result
    }

    var body: some View {
        let items = items
        if !items.isEmpty {
            Card("Review", symbol: "checklist") {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    ForEach(items) { item in
                        HStack(alignment: .top, spacing: Spacing.s) {
                            Image(systemName: item.symbol).foregroundStyle(.secondary).frame(width: 20).accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).font(.callout.weight(.medium))
                                Text(item.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            if let title = item.actionTitle, let action = item.action {
                                Button(title, action: action).controlSize(.small)
                            }
                        }
                        if item.id != items.last?.id { Divider() }
                    }
                }
            }
        }
    }
}

// MARK: - Last scan

struct LastScanCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Card("Last Scan", symbol: "chart.bar.doc.horizontal") {
            if let scan = model.recentScans.first {
                HStack {
                    Text(scan.scopeDescription).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    StatusBadge(status: scan.status)
                }
                HStack(spacing: Spacing.l) {
                    Metric(label: "Observed", value: bytes(scan.bytesObserved), caption: "Sum of file sizes in scope")
                    Metric(label: "Files", value: scan.filesVisited.formatted())
                    Metric(label: "Not readable", value: (scan.inaccessibleItems + scan.errorCount).formatted())
                }
                Text("Started \(scan.startedAt.relative)").font(.caption).foregroundStyle(.tertiary)
                Button("Open in Analyzer") { model.selection = .analyzer }.controlSize(.small)
            } else {
                Text("No scans yet. Scan totals appear here once a scan runs.").foregroundStyle(.secondary)
                Button("Go to Storage Analyzer") { model.selection = .analyzer }.controlSize(.small)
            }
        }
    }
}

// MARK: - Access coverage

struct AccessCoverageCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Card("Access", symbol: "lock.shield") {
            if model.access.locations.isEmpty {
                Text("No folders authorized. MacVault can only measure what it is allowed to read.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.access.locations) { location in
                    let status = model.access.status(of: location)
                    HStack {
                        Image(systemName: "folder").foregroundStyle(.secondary).accessibilityHidden(true)
                        Text(location.displayPath).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        switch status {
                        case .available: StatusBadge(text: status.label, symbol: "checkmark", tint: .green)
                        case .needsReselection: StatusBadge(text: status.label, symbol: "arrow.clockwise", tint: .orange)
                        case .unavailable: StatusBadge(text: status.label, symbol: "xmark", tint: .red)
                        }
                    }
                    .font(.callout)
                }
            }
            Text("Full Disk Access is not assumed. Protected locations that cannot be read are counted and shown after each scan.")
                .font(.caption).foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Activity

struct RecentActivityCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Card("Recent Activity", symbol: "list.bullet.rectangle") {
            if model.recentEvents.isEmpty {
                Text("No activity recorded yet.").foregroundStyle(.secondary)
            } else {
                ForEach(model.recentEvents.prefix(5)) { event in
                    HStack(alignment: .firstTextBaseline) {
                        SeverityIcon(severity: event.severity)
                        Text(event.message).font(.callout).lineLimit(2)
                        Spacer()
                        Text(event.createdAt.relative).font(.caption).foregroundStyle(.tertiary)
                    }
                }
                Button("View All Activity") { model.selection = .activity }.controlSize(.small)
            }
        }
    }
}

struct SeverityIcon: View {
    let severity: AuditSeverity

    var body: some View {
        switch severity {
        case .info: Image(systemName: "info.circle").foregroundStyle(.secondary).accessibilityLabel("Info")
        case .notice: Image(systemName: "bell").foregroundStyle(.blue).accessibilityLabel("Notice")
        case .warning: Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).accessibilityLabel("Warning")
        case .error: Image(systemName: "xmark.octagon").foregroundStyle(.red).accessibilityLabel("Error")
        }
    }
}
