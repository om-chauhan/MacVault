import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic

    /// With the sidebar collapsed, the window controls and the sidebar toggle move into the detail's
    /// title bar row, so the screen header must sit below that row instead of inside it.
    private var sidebarCollapsed: Bool { columnVisibility == .detailOnly }

    var body: some View {
        @Bindable var model = model
        @Bindable var operations = model.operations
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: $model.selection) {
                Section {
                    ForEach([SidebarItem.overview, .analyzer]) { row($0) }
                }
                Section("Maintenance") {
                    ForEach([SidebarItem.cleaner, .applications, .duplicates, .developer]) { row($0) }
                }
                Section {
                    ForEach([SidebarItem.activity, .settings]) { row($0) }
                }
            }
            // The max keeps the detail at least 720 pt wide at the minimum window, which the fixed-width
            // inspector cards (Applications, Activity) and their tables are sized for.
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 240)
            // MacVault's own toggle (on the detail) replaces the system one: when the window is restored
            // with the sidebar collapsed, the system toggle, which lives in the sidebar column, never
            // appears, leaving no way to bring the sidebar back.
            .toolbar(removing: .sidebarToggle)
            .safeAreaInset(edge: .bottom) {
                if model.operations.isExecuting {
                    HStack(spacing: Spacing.xs) {
                        ProgressView().controlSize(.small)
                        Text("Moving to the Trash…").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(Spacing.s)
                    .accessibilityElement(children: .combine)
                }
                if model.isScanning {
                    HStack(spacing: Spacing.xs) {
                        ProgressView().controlSize(.small)
                        Text("Scanning…").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(Spacing.s)
                    .accessibilityElement(children: .combine)
                }
            }
        } detail: {
            // The split view measures the detail's minimum height at a near-zero width, where wrapping
            // text (`fixedSize(horizontal: false, vertical: true)`) reports a huge height and the screen
            // would grow taller than the window. A zero minimum lets the detail take the window's height.
            // Top alignment: a screen that is still too tall overflows at the bottom, not under the toolbar.
            detail(for: model.selection ?? .overview)
                .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
                .canvasBackground()
                // The compact toolbar row holds only the window controls and the sidebar toggle; its
                // background is hidden so the canvas runs up to the window edge and every screen header
                // sits just below it, whether the sidebar is shown or collapsed.
                .toolbarBackground(.hidden, for: .windowToolbar)
                .toolbar {
                    ToolbarItem(placement: .navigation) { sidebarToggle }
                }
                .modifier(InContentTitle())
        }
        .sheet(isPresented: $model.showPermissions) {
            PermissionsSheet()
        }
        .sheet(item: $operations.pendingReview) { pending in
            ApprovalSheet(pending: pending,
                          onApprove: { Task { await model.operations.approvePending() } },
                          onCancel: { Task { await model.operations.discardPending() } })
                .interactiveDismissDisabled()
        }
    }

    private var sidebarToggle: some View {
        Button {
            withAnimation(Motion.standard(reduceMotion: reduceMotion)) {
                columnVisibility = sidebarCollapsed ? .all : .detailOnly
            }
        } label: {
            Label(sidebarCollapsed ? "Show Sidebar" : "Hide Sidebar", systemImage: "sidebar.leading")
        }
        .help(sidebarCollapsed ? "Show the sidebar" : "Hide the sidebar")
        .accessibilityIdentifier("sidebarToggle")
    }

    private func row(_ item: SidebarItem) -> some View {
        Label {
            Text(item.title)
        } icon: {
            Image(systemName: item.symbol).foregroundStyle(item.tint)
        }
        .tag(item)
    }

    @ViewBuilder
    private func detail(for item: SidebarItem) -> some View {
        switch item {
        case .overview: OverviewView()
        case .analyzer: StorageAnalyzerView()
        case .activity: ActivityView()
        case .settings: SettingsView()
        case .cleaner: CleanerView()
        case .applications: ApplicationsView()
        case .duplicates: DuplicatesView()
        case .developer: DeveloperToolsView()
        }
    }
}

/// Each screen shows its title in its `ScreenHeader`, so the toolbar doesn't repeat it (macOS 15+;
/// the window keeps its title for the Window menu and Mission Control).
private struct InContentTitle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.toolbar(removing: .title)
        } else {
            content
        }
    }
}
