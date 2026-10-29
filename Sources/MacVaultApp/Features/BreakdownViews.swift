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

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            breadcrumbs
            if loading {
                ProgressView().frame(maxWidth: .infinity)
            } else if entries.isEmpty {
                ContentUnavailableView("Nothing measured", systemImage: "folder",
                                       description: Text(current == nil
                                                         ? "This folder had no readable items when it was scanned."
                                                         : "No detail was kept below this level."))
            } else {
                switch style {
                case .list: list
                case .treemap: TreemapView(entries: Array(entries.prefix(150)), onOpen: open)
                }
            }
            Text(footer).font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
        .task(id: "\(scan.id)|\(current?.path ?? "")") { await load() }
        .onChange(of: scan.id) { _, _ in trail = [] }
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
            Button(scan.scopeDescription) { trail = [] }
                .buttonStyle(.link)
                .disabled(trail.isEmpty)
            ForEach(Array(trail.enumerated()), id: \.element.id) { index, crumb in
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary).accessibilityHidden(true)
                Button(crumb.name) { trail = Array(trail.prefix(index + 1)) }
                    .buttonStyle(.link)
                    .disabled(index == trail.count - 1)
            }
            Spacer()
            if let current {
                Text(ByteFormat.string(current.logicalBytes)).monospacedDigit().foregroundStyle(.secondary)
                Button { trail.removeLast() } label: { Label("Up", systemImage: "arrow.up") }
                    .controlSize(.small)
                    .keyboardShortcut(.upArrow, modifiers: [.command])
            }
        }
        .font(.callout)
        .lineLimit(1)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Location in scan")
    }

    private var list: some View {
        let maxBytes = max(entries.map(\.logicalBytes).max() ?? 1, 1)
        return List(entries) { entry in
            DrillRow(entry: entry, fraction: Double(entry.logicalBytes) / Double(maxBytes))
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
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
    }
}

private struct DrillRow: View {
    let entry: BreakdownEntry
    let fraction: Double

    var body: some View {
        HStack(spacing: Spacing.s) {
            Image(systemName: entry.isRemainder ? "square.stack" : (entry.isDirectory ? "folder.fill" : "doc"))
                .foregroundStyle(entry.isDirectory && !entry.isRemainder ? Color.accentColor : .secondary)
                .frame(width: 18).accessibilityHidden(true)
            Text(entry.name).lineLimit(1).truncationMode(.middle).frame(minWidth: 140, maxWidth: 260, alignment: .leading)
                .foregroundStyle(entry.isRemainder ? .secondary : .primary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.12))
                    Capsule().fill(Color.accentColor.opacity(entry.isRemainder ? 0.35 : 0.75))
                        .frame(width: max(2, geo.size.width * fraction))
                }
            }
            .frame(height: 6)
            .accessibilityHidden(true)
            Text(ByteFormat.string(entry.logicalBytes)).monospacedDigit().frame(width: 90, alignment: .trailing)
            Text(entry.fileCount.map { "\($0.formatted()) files" } ?? "")
                .font(.caption).foregroundStyle(.secondary).frame(width: 90, alignment: .trailing)
            if !entry.isComplete {
                StatusBadge(text: "Lower bound", symbol: "eye.slash", tint: .orange)
                    .help("\(entry.inaccessibleItems) item(s) inside could not be read")
            }
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary).opacity(entry.canDrill ? 1 : 0)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(entry.name), \(ByteFormat.string(entry.logicalBytes))\(entry.isComplete ? "" : ", lower bound")\(entry.canDrill ? ", folder" : "")")
    }
}

/// Squarified treemap of the current level. Click a folder to open it.
struct TreemapView: View {
    let entries: [BreakdownEntry]
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
        .frame(minHeight: 320)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Treemap of folder sizes")
    }

    private func tile(_ entry: BreakdownEntry, rect: LayoutRect, index: Int) -> some View {
        let color: Color = entry.isRemainder ? .secondary.opacity(0.25)
            : (entry.isDirectory ? Color.accentColor.opacity(max(0.25, 0.85 - Double(index) * 0.04)) : .secondary.opacity(0.4))
        return Button { onOpen(entry) } label: {
            ZStack(alignment: .topLeading) {
                Rectangle().fill(color)
                Rectangle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1)
                if rect.width > 70 && rect.height > 34 {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.name).font(.caption.weight(.semibold)).lineLimit(1)
                        Text(ByteFormat.string(entry.logicalBytes)).font(.caption2).monospacedDigit()
                    }
                    .foregroundStyle(.white)
                    .shadow(radius: 1)
                    .padding(4)
                }
                if hovered == entry.id {
                    Rectangle().strokeBorder(Color.primary, lineWidth: 2)
                }
            }
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
    }
}
