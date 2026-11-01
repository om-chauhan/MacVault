import SwiftUI
import AppKit
import MacVaultCore

/// The Finder icon of an app bundle, read through Icon Services and cached per path.
/// Bundles that no longer exist (moved to the Trash) get the generic application icon.
struct AppIconView: View {
    let bundlePath: String
    var size: CGFloat = Dimensions.appIconSmall

    var body: some View {
        Image(nsImage: AppIconCache.shared.icon(for: bundlePath))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

@MainActor
final class AppIconCache {
    static let shared = AppIconCache()
    private let cache = NSCache<NSString, NSImage>()

    func icon(for path: String) -> NSImage {
        if let cached = cache.object(forKey: path as NSString) { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        image.size = NSSize(width: Dimensions.appIconLarge, height: Dimensions.appIconLarge)
        cache.setObject(image, forKey: path as NSString)
        return image
    }
}

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
        let bundlePath: String
        let isProtected: Bool
        let isRemoved: Bool
    }

    private var rows: [AppRow] {
        let apps = model.applications
        return apps.apps
            .filter { search.isEmpty || $0.displayName.localizedCaseInsensitiveContains(search) || ($0.bundleId ?? "").localizedCaseInsensitiveContains(search) }
            .map { AppRow(id: $0.id, name: $0.displayName, version: $0.version ?? "—", size: $0.bundleSizeBytes ?? -1,
                          location: PathUtilities.abbreviatingHome(($0.bundlePath as NSString).deletingLastPathComponent),
                          bundlePath: $0.bundlePath, isProtected: $0.isProtected, isRemoved: apps.isRemoved($0)) }
            .sorted(using: sortOrder)
    }

    var body: some View {
        @Bindable var apps = model.applications
        VStack(spacing: 0) {
            ScreenHeader(item: .applications, subtitle: subtitle(apps)) {
                if !apps.apps.isEmpty {
                    TextField("Filter by name or bundle ID", text: $search)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: Dimensions.searchFieldWidth)
                }
                if apps.isScanning {
                    ProgressView(value: Double(apps.progress.done), total: Double(max(apps.progress.total, 1)))
                        .frame(width: 120)
                        .accessibilityLabel("Reading applications, \(apps.progress.done) of \(apps.progress.total)")
                    Button("Stop") { apps.cancel() }
                        .help("Stop reading applications. Nothing has been changed.")
                } else {
                    Button(apps.apps.isEmpty ? "List Applications" : "Refresh") {
                        apps.scan(policy: model.operations.policy, store: model.store)
                    }
                    .disabled(model.operations.isExecuting)
                    .help(model.operations.isExecuting ? "Wait until items are moved to the Trash." : "Read /Applications and ~/Applications. Read-only.")
                }
            }

            VStack(alignment: .leading, spacing: Spacing.s) {
                OperationStatusPanel(types: [.appUninstall, .appLeftovers])
                if let error = apps.error { InlineBanner(kind: .error, title: "Applications could not be listed", message: error) }
                OperationHistoryList(types: [.appUninstall, .appLeftovers])

                if apps.apps.isEmpty && apps.isScanning {
                    LoadingState(title: "Reading applications…",
                                 message: "\(apps.progress.done) of \(apps.progress.total) measured. Nothing is changed.")
                } else if apps.apps.isEmpty {
                    EmptyState(title: "Installed applications", symbol: SidebarItem.applications.symbol,
                               message: "MacVault lists apps in /Applications and ~/Applications with their size. Removing an app and removing its data are separate, reviewed steps. Apple apps can’t be removed.") {
                        Button("List Applications") { apps.scan(policy: model.operations.policy, store: model.store) }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.operations.isExecuting)
                    }
                } else {
                    summary(apps)
                    // The list takes the width; the selected app's detail is a fixed-width inspector card.
                    HStack(alignment: .top, spacing: Spacing.m) {
                        Card(flush: true) {
                            Table(rows, selection: $apps.selectedAppID, sortOrder: $sortOrder) {
                                TableColumn("Name", value: \.name) { row in
                                    HStack(spacing: Spacing.xs) {
                                        AppIconView(bundlePath: row.bundlePath)
                                            .opacity(row.isRemoved ? 0.5 : 1)
                                        Text(row.name).strikethrough(row.isRemoved)
                                        if row.isProtected {
                                            Image(systemName: "lock.fill").foregroundStyle(.secondary)
                                                .help("Protected").accessibilityLabel("Protected")
                                        }
                                        if row.isRemoved { TagPill(text: "In Trash") }
                                    }
                                }
                                // Ideal widths sum to what fits beside the inspector at the minimum window;
                                // the last column takes the rest in wider windows.
                                .width(min: 80, ideal: 110)
                                TableColumn("Version", value: \.version) { row in
                                    Text(row.version).monospacedDigit()
                                }
                                .width(min: 44, ideal: 50, max: 110)
                                TableColumn("Size", value: \.size) { row in
                                    Text(row.size < 0 ? "Unknown" : ByteFormat.string(row.size)).font(.rowValue).monospacedDigit()
                                }
                                .width(min: 60, ideal: 66, max: 120)
                                TableColumn("Location", value: \.location) { row in
                                    Text(row.location).font(.smallPath).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                        .help(row.location)
                                }
                                .width(min: 50, ideal: 54)
                            }
                            .alternatingRowBackgrounds(.disabled)
                            .scrollContentBackground(.hidden)
                            .onChange(of: apps.selectedAppID) { _, _ in
                                Task { await apps.loadAssociated(policy: model.operations.policy) }
                            }
                        }
                        .environment(\.cardFillsHeight, true)

                        AppDetail()
                            .frame(width: Dimensions.inspectorWidth)
                            .frame(maxHeight: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                            .cardSurface()
                    }
                    .frame(maxHeight: .infinity)
                }
            }
            .padding(.horizontal, Spacing.l)
            .padding(.bottom, Spacing.m)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .navigationTitle("Applications")
    }

    private func subtitle(_ apps: ApplicationsModel) -> String {
        guard !apps.apps.isEmpty else { return "Apps in /Applications and ~/Applications" }
        return "\(apps.apps.count) app\(apps.apps.count == 1 ? "" : "s")" + (apps.lastScanned.map { " · checked \($0.relative)" } ?? "")
    }

    private func summary(_ apps: ApplicationsModel) -> some View {
        let sized = apps.apps.filter { ($0.bundleSizeBytes ?? 0) > 0 }.sorted { ($0.bundleSizeBytes ?? 0) > ($1.bundleSizeBytes ?? 0) }
        return Card("App Bundles", symbol: "shippingbox.fill", tint: Palette.applications,
                    info: "Measured size of each app bundle. An app’s data in your Library is listed separately when you select it.") {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: Spacing.l) {
                    totals(apps).frame(width: Dimensions.summaryTotalsWidth, alignment: .leading)
                    CategoryBars(segments: sized.prefix(4).enumerated().map { index, app in
                        ChartSegment(id: app.id, label: app.displayName, bytes: app.bundleSizeBytes ?? 0,
                                     color: index == 0 ? Palette.applications : Palette.series[(index + 1) % Palette.series.count])
                    }, maxRows: 4)
                    .frame(maxWidth: .infinity)
                }
                totals(apps)
            }
        }
    }

    private func totals(_ apps: ApplicationsModel) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            ValueText(value: ByteFormat.string(apps.apps.reduce(Int64(0)) { $0 + ($1.bundleSizeBytes ?? 0) }), size: .tile)
            Text("\(apps.apps.count) app\(apps.apps.count == 1 ? "" : "s") · \(apps.apps.filter(\.isProtected).count) protected")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}

private struct AppDetail: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let apps = model.applications
        if let app = apps.selectedApp {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.m) {
                        HStack(alignment: .center, spacing: Spacing.s) {
                            AppIconView(bundlePath: app.bundlePath, size: Dimensions.appIconLarge)
                                .opacity(apps.isRemoved(app) ? 0.5 : 1)
                            VStack(alignment: .leading, spacing: Spacing.xxs / 2) {
                                Text(app.displayName).font(.pageTitle).lineLimit(2)
                                Text(app.bundleId ?? "No bundle identifier").font(.smallPath).foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                        MetricGrid(items: [
                            MetricItem("App bundle", value: (app.sizeIsLowerBound ? "≥ " : "") + ByteFormat.string(app.bundleSizeBytes)),
                            MetricItem("Version", value: app.version ?? "Unknown"),
                        ])
                        // Side by side when they fit, otherwise stacked, so neither title is truncated.
                        ViewThatFits(in: .horizontal) {
                            HStack {
                                revealButton(app)
                                Spacer()
                                removeAppButton(app)
                            }
                            VStack(alignment: .leading, spacing: Spacing.xs) {
                                revealButton(app)
                                removeAppButton(app)
                            }
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
                    .padding(Spacing.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                dataFooter(app)
            }
        } else {
            EmptyState(title: "No app selected", symbol: "sidebar.right",
                       message: "Select an app to see its size and the data it keeps in your Library.")
        }
    }

    private func revealButton(_ app: ApplicationRecord) -> some View {
        Button("Reveal in Finder") { FinderActions.reveal([app.bundlePath]) }
            .fixedSize()
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
            .fixedSize()
            .disabled(model.operations.isExecuting)
            .help(model.operations.isExecuting
                  ? "Wait until items are moved to the Trash."
                  : "Opens a review of the app bundle. Its data in your Library is kept unless you remove it separately.")
        }
    }

    @ViewBuilder
    private func leftovers(_ app: ApplicationRecord) -> some View {
        let apps = model.applications
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(spacing: Spacing.xs) {
                Image(systemName: "folder.fill").foregroundStyle(Palette.applications).accessibilityHidden(true)
                Text("Data in your Library").font(.cardTitle)
                InfoGlyph(text: "Items matching the bundle identifier are likely the app’s; items matching only the app name are less certain and are never pre-selected. Login items and keychains are never listed.")
                Spacer()
                if apps.isLoadingAssociated { ProgressView().controlSize(.small) }
            }
            if apps.associated.isEmpty && !apps.isLoadingAssociated {
                Text(app.isProtected ? "Not reviewed for protected apps." : "Nothing found.").foregroundStyle(.secondary)
            }
            ForEach(apps.associated) { item in
                CandidateRow(candidate: item.candidate, isSelected: Binding(
                    get: { apps.leftoverSelection.contains(item.id) },
                    set: { if $0 { apps.leftoverSelection.insert(item.id) } else { apps.leftoverSelection.remove(item.id) } }),
                             note: item.confidence == .high
                                ? StatusBadge(text: item.confidence.displayName, symbol: "checkmark.seal.fill", tint: Palette.success, wraps: true)
                                : StatusBadge(text: item.confidence.displayName, symbol: "questionmark.circle.fill", tint: Palette.warning, wraps: true),
                             disabled: !OperationsModel.canModifyFiles)
                if item.id != apps.associated.last?.id { Divider() }
            }
        }
    }

    /// Docked review footer for the app's data; separate from removing the app itself.
    @ViewBuilder
    private func dataFooter(_ app: ApplicationRecord) -> some View {
        let apps = model.applications
        if !apps.associated.isEmpty || !OperationsModel.canModifyFiles {
            let selected = apps.associated.filter { apps.leftoverSelection.contains($0.id) }.map(\.candidate)
            // A short title fits the narrowest pane (230 pt); the help has the full description.
            ReviewFooter(count: selected.count, bytes: selected.reduce(0) { $0 + ($1.logicalBytes ?? 0) },
                         buttonTitle: "Move Data to Trash…",
                         disabled: model.operations.isExecuting,
                         help: "Review & move the selected data of \(app.displayName) to the Trash. Opens a review of exactly what will be moved; nothing changes until you approve it.",
                         horizontalPadding: Spacing.m) {
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
        }
    }
}
