import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        @Bindable var operations = model.operations
        NavigationSplitView {
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
            // The max also bounds HSplitViews in the detail, which count the sidebar twice (see ApplicationsView).
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 240)
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
                // The canvas continues under the (empty) toolbar instead of a separate bar above it.
                .toolbarBackground(.hidden, for: .windowToolbar)
                .modifier(InContentTitle())
        }
        .sheet(item: $operations.pendingReview) { pending in
            ApprovalSheet(pending: pending,
                          onApprove: { Task { await model.operations.approvePending() } },
                          onCancel: { Task { await model.operations.discardPending() } })
                .interactiveDismissDisabled()
        }
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
