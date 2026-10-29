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
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
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
            detail(for: model.selection ?? .overview)
        }
        .sheet(item: $operations.pendingReview) { pending in
            ApprovalSheet(pending: pending,
                          onApprove: { Task { await model.operations.approvePending() } },
                          onCancel: { Task { await model.operations.discardPending() } })
                .interactiveDismissDisabled()
        }
    }

    private func row(_ item: SidebarItem) -> some View {
        Label(item.title, systemImage: item.symbol)
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
