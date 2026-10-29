import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
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
    }

    private func row(_ item: SidebarItem) -> some View {
        Label {
            HStack {
                Text(item.title)
                if item.isPlanned {
                    Spacer()
                    Text("Planned").font(.caption2).foregroundStyle(.tertiary)
                }
            }
        } icon: {
            Image(systemName: item.symbol)
        }
        .tag(item)
        .accessibilityLabel(item.isPlanned ? "\(item.title), planned" : item.title)
    }

    @ViewBuilder
    private func detail(for item: SidebarItem) -> some View {
        switch item {
        case .overview: OverviewView()
        case .analyzer: StorageAnalyzerView()
        case .activity: ActivityView()
        case .settings: SettingsView()
        case .cleaner: PlannedFeatureView(feature: .cleaner)
        case .applications: PlannedFeatureView(feature: .applications)
        case .duplicates: PlannedFeatureView(feature: .duplicates)
        case .developer: PlannedFeatureView(feature: .developer)
        }
    }
}
