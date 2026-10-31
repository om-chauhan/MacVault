import SwiftUI
import MacVaultCore

/// One row/tile at the current drill-down level.
struct BreakdownEntry: Identifiable, Hashable {
    let id: String
    let name: String
    let path: String
    let isDirectory: Bool
    let logicalBytes: Int64
    let fileCount: Int?
    let inaccessibleItems: Int
    /// "Files directly in this folder and smaller items" — not a real path.
    let isRemainder: Bool

    var isComplete: Bool { inaccessibleItems == 0 }
    var canDrill: Bool { isDirectory && !isRemainder }
}

/// Breakdown of a scan that can be drilled into, as a list or a treemap.
/// Sizes come from the scan's persisted tree (directories up to 4 levels, largest kept).
struct DrillDownBreakdown: View {
    enum Style { case list, treemap }

    @Environment(AppModel.self) private var model
    let scan: ScanSessionRecord
    let aggregates: [DirectoryAggregate]
    let style: Style

    /// Folders entered, outermost first.
    @State private var trail: [BreakdownEntry] = []
    @State private var children: [TreeNode] = []
    @State private var loading = false

    private var current: BreakdownEntry? { trail.last }

    private var entries: [BreakdownEntry] {
        guard let current else {
            return aggregates.map {
                BreakdownEntry(id: $0.path, name: $0.name, path: $0.path, isDirectory: $0.isDirectory, logicalBytes: $0.logicalBytes,
                               fileCount: $0.isDirectory ? $0.fileCount : nil, inaccessibleItems: $0.inaccessibleItems, isRemainder: false)
            }
        }
        var result = children.map {
            BreakdownEntry(id: $0.path, name: $0.name, path: $0.path, isDirectory: true, logicalBytes: $0.logicalBytes,
                           fileCount: $0.fileCount, inaccessibleItems: $0.inaccessibleItems, isRemainder: false)
        }
        let remainder = current.logicalBytes - children.reduce(0) { $0 + $1.logicalBytes }
        if remainder > 0 {
            result.append(BreakdownEntry(id: current.path + "/\u{0}remainder", name: "Files here and smaller folders",
                                         path: current.path, isDirectory: false, logicalBytes: remainder, fileCount: nil,
                                         inaccessibleItems: 0, isRemainder: true))
        }
        return result.sorted { $0.logicalBytes > $1.logicalBytes }
    }

    /// Colour per entry, shared by the ring, legend, bars and treemap: the five largest get series
    /// colours, everything else (and the remainder) is neutral.
    private var colors: [String: Color] {
        var result: [String: Color] = [:]
        for (index, entry) in entries.filter({ !$0.isRemainder }).prefix(5).enumerated() {
            result[entry.id] = Palette.series[index]
        }
        return result
    }

    var body: some View {
        let colors = colors
        HStack(alignment: .top, spacing: Spacing.m) {
            CompositionCard(title: current?.name ?? folderName, entries: entries, colors: colors, footer: footer)
                .frame(width: Dimensions.compositionWidth)
            VStack(alignment: .leading, spacing: Spacing.s) {
                breadcrumbs
                if loading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if entries.isEmpty {
                    EmptyState(title: "Nothing measured", symbol: "folder",
                               message: current == nil
                                   ? "This folder had no readable items when it was scanned."
                                   : "No detail was kept below this level.")
                } else {
                    switch style {
                    case .list: list(colors)
                    case .treemap:
                        TreemapView(entries: Array(entries.prefix(150)), colors: colors, onOpen: open)
                            .clipShape(RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
                            .padding(Spacing.xs)
                            .cardSurface()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .task(id: "\(scan.id)|\(current?.path ?? "")") { await load() }
        .onChange(of: scan.id) { _, _ in trail = [] }
    }

    private var folderName: String {
        let name = (scan.scopeDescription as NSString).lastPathComponent
        return name.isEmpty ? scan.scopeDescription : name
    }

    private var footer: String {
        "Sizes are measured from files in the scan. Entries marked “lower bound” contain items that could not be read. Detail is kept for folders up to four levels deep; smaller folders are grouped with the files beside them."
    }

    private func load() async {
        guard let current else { children = []; return }
        loading = true
        children = await model.treeChildren(of: current.path)
        loading = false
    }

    private func open(_ entry: BreakdownEntry) {
        guard entry.canDrill else { return }
        trail.append(entry)
    }

    private var breadcrumbs: some View {
        HStack(spacing: Spacing.xxs) {
            Button(folderName) { trail = [] }
                .buttonStyle(.link)
                .disabled(trail.isEmpty)
                .help(scan.scopeDescription)
            ForEach(Array(trail.enumerated()), id: \.element.id) { index, crumb in
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary).accessibilityHidden(true)
                Button(crumb.name) { trail = Array(trail.prefix(index + 1)) }
                    .accessibilityIdentifier("crumb-\(crumb.name)")
                    .buttonStyle(.link)
                    .disabled(index == trail.count - 1)
            }
            Spacer()
            if let current {
                Text(ByteFormat.string(current.logicalBytes)).font(.rowValue).monospacedDigit().foregroundStyle(.secondary)
                Button { trail.removeLast() } label: { Label("Up", systemImage: "arrow.up") }
                    .controlSize(.small)
                    .keyboardShortcut(.upArrow, modifiers: [.command])
                    .help("Up one level (⌘↑)")
            }
        }
        .font(.callout.weight(.medium))
        .frame(minHeight: Spacing.l)
        .lineLimit(1)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Location in scan")
    }

    private func list(_ colors: [String: Color]) -> some View {
        let maxBytes = max(entries.map(\.logicalBytes).max() ?? 1, 1)
        return List(entries) { entry in
            DrillRow(entry: entry, fraction: Double(entry.logicalBytes) / Double(maxBytes), color: colors[entry.id] ?? Palette.neutral)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { open(entry) }
                .contextMenu {
                    if entry.canDrill { Button("Open") { open(entry) } }
                    if !entry.isRemainder {
                        Button("Reveal in Finder") { FinderActions.reveal([entry.path]) }
                        Button("Copy Path") { FinderActions.copy([entry.path]) }
                    }
                }
                .accessibilityAction(named: "Open") { open(entry) }
                .accessibilityIdentifier("breakdownRow-\(entry.name)")
        }
        .listStyle(.inset)
        .listInCard()
    }
}

/// Ring of the current level's largest entries plus "Other", with legend rows (ref. 03).
private struct CompositionCard: View {
    let title: String
    let entries: [BreakdownEntry]
    let colors: [String: Color]
    let footer: String

    var body: some View {
        let total = max(entries.reduce(0) { $0 + $1.logicalBytes }, 1)
        let named = entries.filter { colors[$0.id] != nil }
        let other = total - named.reduce(0) { $0 + $1.logicalBytes }
        let segments = named.map { ChartSegment(id: $0.id, label: $0.name, bytes: $0.logicalBytes, color: colors[$0.id]!) }
            + (other > 0 ? [ChartSegment(id: "other", label: "Other", bytes: other, color: Palette.neutral)] : [])
        Card("Composition", symbol: "chart.pie.fill", tint: Palette.analyzer, info: footer) {
            if entries.isEmpty {
                CardEmptyState(title: "Nothing measured", message: "No sizes were recorded at this level.")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.s) {
                        RingChart(segments: segments) {
                            VStack(spacing: 0) {
                                ValueText(value: ByteFormat.string(total), size: .metric)
                                Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                    .frame(maxWidth: 80)
                            }
                        }
                        .frame(width: Dimensions.compositionRing, height: Dimensions.compositionRing)
                        .frame(maxWidth: .infinity)
                        VStack(spacing: Spacing.xs) {
                            ForEach(segments) { segment in
                                LegendRow(color: segment.color, label: segment.label, value: ByteFormat.string(segment.bytes),
                                          share: Double(segment.bytes) / Double(total))
                            }
                        }
                    }
                }
            }
        }
        .environment(\.cardFillsHeight, true)
    }
}

private struct DrillRow: View {
    let entry: BreakdownEntry
    let fraction: Double
    let color: Color

    var body: some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: entry.isRemainder ? "square.stack.fill" : (entry.isDirectory ? "folder.fill" : "doc.fill"))
                .foregroundStyle(entry.isDirectory && !entry.isRemainder ? color : .secondary)
                .frame(width: Spacing.m).accessibilityHidden(true)
            // Name column (with the lower-bound badge) of the same width on every row, so bars line up.
            HStack(spacing: Spacing.xs) {
                Text(entry.name).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(entry.isRemainder ? .secondary : .primary)
                    .help(entry.isRemainder ? entry.name : entry.path)
                if !entry.isComplete {
                    StatusBadge(text: "Lower bound", symbol: "eye.slash.fill", tint: Palette.warning)
                        .help("\(entry.inaccessibleItems) item(s) inside could not be read")
                }
            }
            .frame(minWidth: 96, maxWidth: 280, alignment: .leading)
            .layoutPriority(1)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.track)
                    Capsule().fill(color.gradient)
                        .frame(width: max(Spacing.xxs, geo.size.width * fraction))
                }
            }
            .frame(minWidth: Spacing.l, maxHeight: Spacing.xs)
            .accessibilityHidden(true)
            Text(ByteFormat.string(entry.logicalBytes)).font(.rowValue).monospacedDigit()
                .frame(minWidth: 72, alignment: .trailing)
            Text(entry.fileCount.map { counted($0, "file") } ?? "")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                .frame(minWidth: 64, alignment: .trailing)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary).opacity(entry.canDrill ? 1 : 0)
                .accessibilityHidden(true)
        }
        .padding(.vertical, Spacing.xxs / 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(entry.name), \(ByteFormat.string(entry.logicalBytes))\(entry.isComplete ? "" : ", lower bound")\(entry.canDrill ? ", folder" : "")")
    }
}

/// Squarified treemap of the current level. Click a folder to open it.
struct TreemapView: View {
    let entries: [BreakdownEntry]
    let colors: [String: Color]
    let onOpen: (BreakdownEntry) -> Void
    @State private var hovered: String?

    var body: some View {
        GeometryReader { geo in
            let rects = TreemapLayout.squarify(entries.map { (id: $0.id, weight: Double($0.logicalBytes)) },
                                               in: LayoutRect(x: 0, y: 0, width: geo.size.width, height: geo.size.height))
            let byId = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
            ZStack(alignment: .topLeading) {
                ForEach(rects, id: \.id) { item in
                    if let entry = byId[item.id] {
                        tile(entry, rect: item.rect, index: entries.firstIndex(of: entry) ?? 0)
                    }
                }
            }
        }
        .frame(minHeight: 200)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Treemap of folder sizes")
    }

    private func tile(_ entry: BreakdownEntry, rect: LayoutRect, index: Int) -> some View {
        let base = colors[entry.id] ?? (entry.isDirectory && !entry.isRemainder ? Palette.analyzer.opacity(max(0.35, 0.8 - Double(index) * 0.04)) : Palette.neutral)
        return Button { onOpen(entry) } label: {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: Radius.small, style: .continuous).fill(base.gradient)
                if rect.width > 70 && rect.height > 34 {
                    // Large tiles get larger labels, like the hero numbers of cards.
                    let large = rect.width > 160 && rect.height > 90
                    VStack(alignment: .leading, spacing: Spacing.xxs / 2) {
                        Text(entry.name).font(large ? .cardTitle : .caption.weight(.semibold)).lineLimit(1)
                        Text(ByteFormat.string(entry.logicalBytes)).font(large ? .rowValue : .caption2.weight(.medium)).monospacedDigit()
                    }
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.35), radius: 1)
                    .padding(Spacing.xs)
                }
                if hovered == entry.id {
                    RoundedRectangle(cornerRadius: Radius.small, style: .continuous).strokeBorder(Color.primary, lineWidth: 2)
                }
            }
            .padding(1)
        }
        .buttonStyle(.plain)
        .frame(width: max(0, rect.width), height: max(0, rect.height))
        .offset(x: rect.x, y: rect.y)
        .onHover { hovered = $0 ? entry.id : (hovered == entry.id ? nil : hovered) }
        .help("\(entry.name) — \(ByteFormat.string(entry.logicalBytes))\(entry.isComplete ? "" : " (lower bound)")\(entry.canDrill ? "\nClick to open" : "")")
        .contextMenu {
            if !entry.isRemainder {
                Button("Reveal in Finder") { FinderActions.reveal([entry.path]) }
                Button("Copy Path") { FinderActions.copy([entry.path]) }
            }
        }
        .accessibilityLabel("\(entry.name), \(ByteFormat.string(entry.logicalBytes))")
        .accessibilityHint(entry.canDrill ? "Opens this folder" : "")
        .accessibilityIdentifier("treemapTile-\(entry.name)")
    }
}
