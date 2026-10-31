import SwiftUI
import Charts
import MacVaultCore

/// Dashboard of widget cards. Every value comes from a system report, the database or a list the
/// user made in this session; a card without data says so instead of showing a number.
struct OverviewView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(item: .overview, subtitle: "System-reported capacity, your scans and recent activity.") {
                Button {
                    Task { await model.refreshVolumes() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Read volume capacity again (⌘R)")
                .disabled(model.isRefreshingVolumes)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.m) {
                    banners
                    WidgetGridView {
                        volumeCards
                        LastScanTile().widgetSpan(1)
                        TrashTile().widgetSpan(1)
                        DuplicatesTile().widgetSpan(1)
                        ApplicationsTile().widgetSpan(1)
                        // Paired so each row holds two medium cards of similar height.
                        if !RecommendationsCard.items(model).isEmpty {
                            RecommendationsCard().widgetSpan(2)
                        }
                        RecentActivityCard().widgetSpan(2)
                        AccessCoverageCard().widgetSpan(2)
                        ForEach(model.volumes.dropFirst()) { volume in
                            VolumeSummaryCard(volume: volume).widgetSpan(2)
                        }
                    }
                }
                .padding(Spacing.l)
                .frame(maxWidth: Dimensions.readableWidth)
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("Overview")
    }

    @ViewBuilder
    private var banners: some View {
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
        if let error = model.volumeError {
            InlineBanner(kind: .error, title: "Volume information unavailable", message: error,
                         actionTitle: "Retry") { Task { await model.refreshVolumes() } }
        }
    }

    @ViewBuilder
    private var volumeCards: some View {
        if let volume = model.volumes.first {
            VolumeCapacityCard(volume: volume, history: model.history[volume.id] ?? []).widgetSpan(2)
            AvailableHistoryCard(volume: volume, history: model.history[volume.id] ?? []).widgetSpan(2)
        } else if model.volumeError == nil {
            Card("Volumes", symbol: "internaldrive", tint: Palette.storage) {
                HStack(spacing: Spacing.xs) {
                    ProgressView().controlSize(.small)
                    Text("Reading volume information…").foregroundStyle(.secondary)
                }
            }
            .widgetSpan(4)
        }
    }
}

// MARK: - Shared pieces

/// "Open <screen>" button for a card header.
struct OpenScreenButton: View {
    let item: SidebarItem
    @Environment(AppModel.self) private var model
    @Environment(\.onBoldSurface) private var onBold

    var body: some View {
        Button { model.selection = item } label: {
            Label("Open \(item.title)", systemImage: "arrow.up.right")
        }
        .buttonStyle(.borderless)
        .labelStyle(.iconOnly)
        .foregroundStyle(onBold ? AnyShapeStyle(Palette.onBoldSecondary) : AnyShapeStyle(.secondary))
        .help("Open \(item.title)")
    }
}

// MARK: - Volume capacity

/// Hero card: available space, a ring of used vs available, legend rows and the 7-day change.
struct VolumeCapacityCard: View {
    let volume: VolumeObservation
    let history: [StorageSnapshot]
    @Environment(AppModel.self) private var model

    private var info: String {
        "Source: \(volume.source) · Observed \(volume.observedAt.shortDateTime)\(volume.mountPath.map { " · \($0)" } ?? "")"
            + "\nUsed is total capacity minus available space, both reported by macOS."
    }

    var body: some View {
        Card(volume.displayName, symbol: volume.isInternal == false || volume.isRemovable == true ? "externaldrive.fill" : "internaldrive.fill",
             tint: Palette.storage, info: info, trailing: AnyView(actions)) {
            if let used = volume.usedBytes, let total = volume.totalBytes, let available = volume.availableBytes, total > 0 {
                HStack(alignment: .center, spacing: Spacing.l) {
                    RingChart(segments: [
                        ChartSegment(id: "used", label: "Used", bytes: used, color: Palette.storage),
                        ChartSegment(id: "available", label: "Available", bytes: available, color: Palette.neutral),
                    ]) {
                        VStack(spacing: 0) {
                            Text(LegendRow.percent(Double(used) / Double(total)))
                                .font(.tileNumber).monospacedDigit()
                            Text("used").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: Dimensions.capacityRing, height: Dimensions.capacityRing)

                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Available").font(.callout).foregroundStyle(.secondary)
                            ValueText(value: bytes(available), size: .hero)
                        }
                        if let delta = WeekChange(history: history, current: available) {
                            DeltaPill(delta: delta.bytes, caption: "since \(delta.since.formatted(.dateTime.month(.abbreviated).day()))")
                        }
                        VStack(spacing: Spacing.xxs) {
                            LegendRow(color: Palette.storage, label: "Used", value: bytes(used), share: Double(used) / Double(total))
                            LegendRow(color: Palette.neutral, label: "Available", value: bytes(available), share: Double(available) / Double(total))
                        }
                        Text(capacityLine(total: total, available: available))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            } else {
                CardEmptyState(title: "Capacity unknown", message: "This volume does not report its capacity.")
            }
        }
        .accessibilityLabel("Capacity of \(volume.displayName)")
    }

    private func capacityLine(total: Int64, available: Int64) -> String {
        var parts = ["Capacity \(bytes(total))"]
        if let important = volume.availableForImportantUsageBytes, important != available {
            parts.append("\(bytes(important)) incl. purgeable")
        }
        if let format = volume.formatDescription { parts.append(format) }
        return parts.joined(separator: " · ")
    }

    private var actions: some View {
        HStack(spacing: Spacing.xs) {
            if volume.isReadOnly == true { StatusBadge(text: "Read-only", symbol: "lock.fill", tint: .secondary) }
            if volume.isRemovable == true { StatusBadge(text: "Removable", symbol: "eject.fill", tint: .secondary) }
            ActionsPill {
                Button { Task { await model.refreshVolumes() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .help("Read volume capacity again")
                    .disabled(model.isRefreshingVolumes)
                Button { model.selection = .analyzer } label: { Label("Open Storage Analyzer", systemImage: "arrow.up.right") }
                    .help("See what uses space in a folder")
            }
        }
    }
}

/// Change in available space against the oldest recorded observation of the last 7 days.
/// Nil unless at least two observations exist.
struct WeekChange {
    let bytes: Int64
    let since: Date

    init?(history: [StorageSnapshot], current: Int64) {
        let recorded = history.filter { $0.availableBytes != nil }
        guard recorded.count >= 2 else { return nil }
        let weekAgo = Date().addingTimeInterval(-7 * 86_400)
        guard let oldest = recorded.filter({ $0.observedAt >= weekAgo }).min(by: { $0.observedAt < $1.observedAt }),
              let then = oldest.availableBytes,
              oldest.observedAt < (recorded.map(\.observedAt).max() ?? .distantPast) else { return nil }
        bytes = current - then
        since = oldest.observedAt
    }
}

/// Available space over time: one bar per recorded observation (latest highlighted with its value)
/// and a dotted average rule. Nothing is interpolated.
struct AvailableHistoryCard: View {
    let volume: VolumeObservation
    let history: [StorageSnapshot]

    private struct Point: Identifiable {
        let id: Int
        let date: Date
        let bytes: Int64
    }

    private var points: [Point] {
        let recorded = history.filter { $0.availableBytes != nil }.sorted { $0.observedAt < $1.observedAt }.suffix(24)
        return recorded.enumerated().map { Point(id: $0.offset, date: $0.element.observedAt, bytes: $0.element.availableBytes ?? 0) }
    }

    var body: some View {
        let points = points
        Card("Available Space History", symbol: "chart.bar.fill", tint: Palette.storage,
             info: "Recorded at most hourly while MacVault is open, and after scans. Each bar is one recorded observation of \(volume.displayName); the dotted line is their average.") {
            if points.count >= 2 {
                chart(points)
            } else {
                CardEmptyState(title: points.isEmpty ? "No observations yet" : "One observation so far",
                               message: "MacVault records available space at most hourly while it is open. The chart appears once there are two observations.",
                               symbol: "chart.bar.xaxis")
                Spacer(minLength: 0)
                if let only = points.first {
                    Divider()
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                        TagPill(text: "Recorded", tint: Palette.storage)
                        ValueText(value: ByteFormat.string(only.bytes), size: .metric)
                        Text("available · \(only.date.shortDateTime)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func chart(_ points: [Point]) -> some View {
        let average = Double(points.reduce(0) { $0 + $1.bytes }) / Double(points.count)
        let last = points.last!
        return VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("\(points.count) observations since \(points[0].date.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption).foregroundStyle(.secondary)
            Chart {
                ForEach(points) { point in
                    // Categorical x (one slot per observation), so every bar gets a width.
                    BarMark(x: .value("Observation", "\(point.id)"), y: .value("Available", Double(point.bytes)), width: .ratio(0.62))
                        .cornerRadius(Radius.small)
                        .foregroundStyle(point.id == last.id ? AnyShapeStyle(Palette.storage.gradient) : AnyShapeStyle(Palette.track))
                        .annotation(position: .top, spacing: Spacing.xxs) {
                            if point.id == last.id { ValueBubble(text: ByteFormat.string(point.bytes), tint: Palette.storage) }
                        }
                }
                RuleMark(y: .value("Average", average))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                    .foregroundStyle(.secondary)
                    .annotation(position: .top, alignment: .leading, spacing: Spacing.xxs) {
                        ValueBubble(text: "Avg \(ByteFormat.string(Int64(average)))")
                    }
            }
            .chartXAxis {
                // First and last observation only; times when they are on the same day.
                let sameDay = Calendar.current.isDate(points[0].date, inSameDayAs: last.date)
                AxisMarks(values: ["\(points[0].id)", "\(last.id)"]) { value in
                    AxisValueLabel {
                        if let index = value.as(String.self).flatMap(Int.init), index == points[0].id || index == last.id {
                            Text(sameDay ? points[index].date.formatted(date: .omitted, time: .shortened)
                                         : points[index].date.formatted(.dateTime.month(.abbreviated).day()))
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Palette.track)
                    AxisValueLabel { if let v = value.as(Double.self) { Text(ByteFormat.string(Int64(v))) } }
                }
            }
            .frame(minHeight: 140)
            .accessibilityLabel("Available space history")
            .accessibilityValue("\(points.count) observations. Latest \(ByteFormat.string(last.bytes)), average \(ByteFormat.string(Int64(average))).")
        }
    }
}

/// Compact card for volumes other than the first.
struct VolumeSummaryCard: View {
    let volume: VolumeObservation

    var body: some View {
        Card(volume.displayName, symbol: volume.isInternal == false || volume.isRemovable == true ? "externaldrive.fill" : "internaldrive.fill",
             tint: Palette.storage,
             info: "Source: \(volume.source) · Observed \(volume.observedAt.shortDateTime)\(volume.mountPath.map { " · \($0)" } ?? "")",
             trailing: AnyView(tags)) {
            if let used = volume.usedBytes, let total = volume.totalBytes, let available = volume.availableBytes, total > 0 {
                HStack(alignment: .firstTextBaseline) {
                    ValueText(value: bytes(available), size: .tile)
                    Text("available of \(bytes(total))").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(LegendRow.percent(Double(used) / Double(total))) used").font(.callout.weight(.semibold)).monospacedDigit()
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Palette.track)
                        Capsule().fill(Palette.storage.gradient).frame(width: geo.size.width * Double(used) / Double(total))
                    }
                }
                .frame(height: Spacing.xs)
                .accessibilityLabel("\(bytes(used)) used of \(bytes(total))")
            } else {
                CardEmptyState(title: "Capacity unknown", message: "This volume does not report its capacity.")
            }
        }
    }

    private var tags: some View {
        HStack(spacing: Spacing.xs) {
            if volume.isReadOnly == true { StatusBadge(text: "Read-only", symbol: "lock.fill", tint: .secondary) }
            if volume.isRemovable == true { StatusBadge(text: "Removable", symbol: "eject.fill", tint: .secondary) }
            if let format = volume.formatDescription { TagPill(text: format) }
        }
    }
}

// MARK: - Tiles

/// The screen's one bold tile (ref. 03): the most recent scan.
struct LastScanTile: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Card("Last Scan", symbol: SidebarItem.analyzer.symbol, tint: Palette.analyzer, style: .bold,
             trailing: AnyView(OpenScreenButton(item: .analyzer))) {
            if let scan = model.recentScans.first {
                ValueText(value: bytes(scan.bytesObserved), size: .tile)
                StatusBadge(status: scan.status)
                Spacer(minLength: 0)
                Text("\(counted(scan.filesVisited, "file")) · \(scan.startedAt.relative)")
                    .font(.caption).foregroundStyle(Palette.onBoldSecondary).monospacedDigit().lineLimit(1)
                Text(scan.scopeDescription).font(.smallPath).foregroundStyle(Palette.onBoldSecondary).lineLimit(1).truncationMode(.middle).help(scan.rootPath ?? scan.scopeDescription)
            } else {
                CardEmptyState(title: "No scans yet", message: "Scan a folder to see what it contains.")
            }
        }
    }
}

struct TrashTile: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let lists = model.operations.history(for: Set(OperationType.allCases)).filter { $0.count(.trashed) > 0 }
        let items = lists.reduce(0) { $0 + $1.count(.trashed) }
        let total = lists.reduce(Int64(0)) { $0 + $1.trashedBytes }
        Card("Moved to Trash", symbol: "trash.fill", tint: Palette.cleaner,
             info: "Measured size of items you approved and MacVault moved to the Trash, from your most recent lists. Space is freed only when the Trash is emptied.",
             trailing: AnyView(OpenScreenButton(item: .activity))) {
            if lists.isEmpty {
                CardEmptyState(title: "Nothing moved yet", message: "Approved lists and every item’s outcome are recorded in Activity.")
            } else {
                ValueText(value: ByteFormat.string(total), size: .tile)
                TagPill(text: "\(items) item\(items == 1 ? "" : "s")", tint: Palette.cleaner)
                Spacer(minLength: 0)
                Text("In \(lists.count) approved list\(lists.count == 1 ? "" : "s") · last \(lists[0].createdAt.relative)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }
}

struct DuplicatesTile: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Card("Duplicates", symbol: SidebarItem.duplicates.symbol, tint: Palette.duplicates,
             trailing: AnyView(OpenScreenButton(item: .duplicates))) {
            if let result = model.duplicates.result {
                ValueText(value: "\(result.groups.count) group\(result.groups.count == 1 ? "" : "s")", size: .tile)
                TagPill(text: "Up to \(ByteFormat.string(result.reclaimableBytes))", tint: Palette.duplicates)
                Spacer(minLength: 0)
                Text("\(counted(result.filesConsidered, "file")) compared").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            } else {
                CardEmptyState(title: "Not searched yet", message: "Find files with identical content in a folder you choose.")
            }
        }
    }
}

struct ApplicationsTile: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let apps = model.applications.apps
        Card("Applications", symbol: SidebarItem.applications.symbol, tint: Palette.applications,
             trailing: AnyView(OpenScreenButton(item: .applications))) {
            if apps.isEmpty {
                CardEmptyState(title: "Not listed yet", message: "List installed apps with their size and the data they keep.")
            } else {
                ValueText(value: "\(apps.count) app\(apps.count == 1 ? "" : "s")", size: .tile)
                TagPill(text: ByteFormat.string(apps.reduce(Int64(0)) { $0 + ($1.bundleSizeBytes ?? 0) }), tint: Palette.applications)
                Spacer(minLength: 0)
                Text(model.applications.lastScanned.map { "Listed \($0.relative)" } ?? "")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Recommendations

/// Every suggestion is derived from real observations; none is a generic "boost" suggestion.
struct RecommendationsCard: View {
    @Environment(AppModel.self) private var model

    struct Item: Identifiable {
        let id: String
        let symbol: String
        let tint: Color
        let title: String
        let detail: String
        let actionTitle: String?
        let action: (() -> Void)?
    }

    @MainActor
    static func items(_ model: AppModel) -> [Item] {
        var result: [Item] = []
        for v in model.volumes {
            if let fraction = v.usedFraction, fraction >= 0.9, let available = v.availableBytes {
                result.append(Item(id: "low-\(v.id)", symbol: "exclamationmark.triangle.fill", tint: Palette.warning,
                                   title: "\(v.displayName) has \(bytes(available)) available",
                                   detail: "More than 90% of this volume is in use (system-reported). Scanning large folders shows what takes space; the Cleaner lists caches and logs you can review.",
                                   actionTitle: "Open Analyzer", action: { model.selection = .analyzer }))
                if v.mountPath == "/" {
                    result.append(Item(id: "cleaner-\(v.id)", symbol: SidebarItem.cleaner.symbol, tint: Palette.cleaner,
                                       title: "Review caches, logs and developer files",
                                       detail: "Nothing is removed until you approve a list. Approved items go to the Trash.",
                                       actionTitle: "Open Cleaner", action: { model.selection = .cleaner }))
                }
            }
        }
        if model.access.locations.isEmpty {
            result.append(Item(id: "no-locations", symbol: "folder.badge.plus", tint: Palette.analyzer, title: "Choose a folder to scan",
                               detail: "MacVault only scans folders you choose. Nothing is changed or deleted.",
                               actionTitle: "Choose Folder…", action: { Task { await model.chooseAndAddLocation() } }))
        }
        for location in model.access.locations where model.access.status(of: location) == .needsReselection {
            result.append(Item(id: "stale-\(location.id)", symbol: "folder.badge.questionmark", tint: Palette.warning,
                               title: "Access to \(location.displayName) needs renewing",
                               detail: "macOS no longer accepts the saved access for this folder. Choose it again to keep scanning it.",
                               actionTitle: "Settings", action: { model.selection = .settings }))
        }
        if let last = model.recentScans.first, last.status == .partial {
            result.append(Item(id: "partial-\(last.id)", symbol: "eye.slash.fill", tint: Palette.warning,
                               title: "Last scan could not read \(last.inaccessibleItems + last.errorCount) item(s)",
                               detail: "Sizes for \(last.scopeDescription) are a lower bound. Granting access to those folders gives a complete picture.",
                               actionTitle: "Review", action: { model.selection = .analyzer }))
        }
        return result
    }

    var body: some View {
        let items = Self.items(model)
        Card("Suggestions", symbol: "lightbulb.fill", tint: Palette.warning,
             info: "Based only on what MacVault observed: system-reported capacity, folder access and your last scan.") {
            VStack(alignment: .leading, spacing: Spacing.s) {
                ForEach(items) { item in
                    HStack(alignment: .top, spacing: Spacing.s) {
                        Image(systemName: item.symbol).foregroundStyle(item.tint).frame(width: Spacing.l).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: Spacing.xxs / 2) {
                            Text(item.title).font(.rowTitle)
                            Text(item.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: Spacing.xs)
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

// MARK: - Access coverage

struct AccessCoverageCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Card("Folder Access", symbol: "lock.shield.fill", tint: Palette.analyzer,
             info: "Full Disk Access is not assumed. Protected locations that cannot be read are counted and shown after each scan.",
             trailing: AnyView(OpenScreenButton(item: .settings))) {
            if model.access.locations.isEmpty {
                CardEmptyState(title: "No folders yet", message: "MacVault can only measure what it is allowed to read.")
            } else {
                VStack(spacing: Spacing.xs) {
                    ForEach(model.access.locations) { location in
                        let status = model.access.status(of: location)
                        HStack(spacing: Spacing.xs) {
                            Image(systemName: "folder.fill").foregroundStyle(Palette.analyzer).accessibilityHidden(true)
                            PathText(path: location.path)
                            Spacer(minLength: Spacing.xs)
                            switch status {
                            case .available: StatusBadge(text: status.label, symbol: "checkmark.circle.fill", tint: Palette.success)
                            case .needsReselection: StatusBadge(text: status.label, symbol: "arrow.clockwise.circle.fill", tint: Palette.warning)
                            case .unavailable: StatusBadge(text: status.label, symbol: "xmark.circle.fill", tint: Palette.error)
                            }
                        }
                        if location.id != model.access.locations.last?.id { Divider() }
                    }
                }
            }
        }
    }
}

// MARK: - Activity

struct RecentActivityCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Card("Recent Activity", symbol: SidebarItem.activity.symbol, tint: Palette.activity,
             trailing: AnyView(OpenScreenButton(item: .activity))) {
            if model.recentEvents.isEmpty {
                CardEmptyState(title: "No activity yet", message: "Scans, access changes and approved lists are recorded here.")
            } else {
                VStack(spacing: Spacing.xs) {
                    ForEach(model.recentEvents.prefix(5)) { event in
                        HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                            SeverityIcon(severity: event.severity)
                            Text(event.message).font(.callout).lineLimit(1).truncationMode(.middle).help(event.message)
                            Spacer(minLength: Spacing.xs)
                            Text(event.createdAt.relative).font(.caption).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                        }
                        if event.id != model.recentEvents.prefix(5).last?.id { Divider() }
                    }
                }
            }
        }
    }
}

struct SeverityIcon: View {
    let severity: AuditSeverity

    var body: some View {
        switch severity {
        case .info: Image(systemName: "info.circle.fill").foregroundStyle(.secondary).accessibilityLabel("Info")
        case .notice: Image(systemName: "bell.fill").foregroundStyle(Palette.storage).accessibilityLabel("Notice")
        case .warning: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.warning).accessibilityLabel("Warning")
        case .error: Image(systemName: "xmark.octagon.fill").foregroundStyle(Palette.error).accessibilityLabel("Error")
        }
    }
}
