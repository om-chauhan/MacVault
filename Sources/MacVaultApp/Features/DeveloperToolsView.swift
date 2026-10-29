import SwiftUI
import MacVaultCore

struct DeveloperToolsView: View {
    @Environment(AppModel.self) private var model

    enum Area: String, CaseIterable, Identifiable {
        case caches = "Global Caches"
        case projects = "Project Build Folders"
        var id: String { rawValue }
    }

    @State private var section: Area = .caches

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Spacing.s) {
                Picker("Section", selection: $section) {
                    ForEach(Area.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 360)
                Spacer()
                switch section {
                case .caches: cachesControls
                case .projects: projectControls
                }
            }
            .padding(.horizontal, Spacing.l)
            .padding(.vertical, Spacing.s)
            Divider()

            VStack(alignment: .leading, spacing: Spacing.s) {
                OperationStatusPanel(types: [.developerCleanup])
                if let error = section == .caches ? model.developerCaches.error : model.projects.error {
                    InlineBanner(kind: .error, title: "Review could not finish", message: error)
                }
                OperationHistoryList(types: [.developerCleanup])
            }
            .padding(.horizontal, Spacing.l)
            .padding(.vertical, Spacing.xs)

            switch section {
            case .caches: cachesContent
            case .projects: projectsContent
            }

            Divider()
            footer
        }
        .navigationTitle("Developer Tools")
    }

    // MARK: Global caches

    private var cachesControls: some View {
        let scan = model.developerCaches
        return HStack {
            if scan.isScanning {
                ProgressView().controlSize(.small)
                Text(scan.currentRule ?? "").font(.caption).foregroundStyle(.secondary)
                Button("Stop") { scan.cancel() }
            } else {
                Button(scan.findings.isEmpty ? "Find Caches" : "Check Again") { scan.scan(policy: model.operations.policy) }
                    .disabled(model.operations.isExecuting)
            }
        }
    }

    @ViewBuilder
    private var cachesContent: some View {
        let scan = model.developerCaches
        if scan.findings.isEmpty {
            ContentUnavailableView {
                Label(scan.isScanning ? "Looking for developer caches…" : "Xcode, Simulator, Gradle, npm and Dart caches",
                      systemImage: "hammer")
            } description: {
                Text("Global caches are listed by tool, with what rebuilding them costs. Source code, Git data, signing assets and simulator devices are never offered.")
            } actions: {
                if !scan.isScanning {
                    Button("Find Caches") { scan.scan(policy: model.operations.policy) }.buttonStyle(.borderedProminent)
                }
            }
        } else {
            RuleFindingsList(scan: scan)
        }
    }

    // MARK: Projects

    private var projectControls: some View {
        let projects = model.projects
        return HStack {
            Menu {
                ForEach(model.access.locations) { location in
                    Button(location.displayPath) { projects.locationID = location.id }
                }
                if !model.access.locations.isEmpty { Divider() }
                Button("Choose Folder…") {
                    Task {
                        await model.chooseAndAddLocation()
                        projects.locationID = model.selectedLocationID
                    }
                }
            } label: {
                Label(projectLocation?.displayPath ?? "Choose a folder", systemImage: "folder")
            }
            .frame(maxWidth: 260)
            .disabled(projects.isScanning)
            if projects.isScanning {
                ProgressView().controlSize(.small)
                Button("Stop") { projects.cancel() }
            } else {
                Button("Find Build Folders") {
                    if let location = projectLocation {
                        projects.scan(location: location, access: model.access, policy: model.operations.policy)
                    }
                }
                .disabled(projectLocation == nil || model.operations.isExecuting)
            }
        }
    }

    private var projectLocation: AuthorizedLocation? {
        let id = model.projects.locationID ?? model.selectedLocationID
        return model.access.locations.first { $0.id == id } ?? model.access.locations.first
    }

    @ViewBuilder
    private var projectsContent: some View {
        let projects = model.projects
        if projects.candidates.isEmpty {
            ContentUnavailableView {
                Label(projects.isScanning ? "Looking for project build folders…" : "Build folders in your projects",
                      systemImage: "shippingbox")
            } description: {
                Text(projects.scannedPath == nil
                     ? "MacVault looks for node_modules, Flutter and Gradle build folders, .dart_tool and Rust target folders — only next to their project files, and never inside Git data."
                     : "No build folders were found in \(PathUtilities.abbreviatingHome(projects.scannedPath ?? "")).")
            }
        } else {
            List {
                Section {
                    ForEach(projects.candidates) { candidate in
                        CandidateRow(candidate: candidate, isSelected: Binding(
                            get: { projects.selection.contains(candidate.id) },
                            set: { if $0 { projects.selection.insert(candidate.id) } else { projects.selection.remove(candidate.id) } }),
                                     disabled: !OperationsModel.canModifyFiles)
                    }
                } footer: {
                    Text("Each folder is recreated by its build tool. Projects that are open in an editor may need to be rebuilt.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .listStyle(.inset)
        }
    }

    // MARK: Footer

    @ViewBuilder
    private var footer: some View {
        switch section {
        case .caches:
            let scan = model.developerCaches
            ReviewFooter(count: scan.selectedCandidates.count, bytes: scan.selectedBytes, buttonTitle: "Review & Move to Trash…",
                         disabled: model.operations.isExecuting || scan.isScanning) {
                Task {
                    await model.operations.review(.developerCleanup, title: "Developer caches", candidates: scan.selectedCandidates) {
                        if case .finished(let manifest) = model.operations.phase { scan.removeProcessed(manifest) }
                    }
                }
            }
        case .projects:
            let projects = model.projects
            ReviewFooter(count: projects.selectedCandidates.count, bytes: projects.selectedBytes,
                         buttonTitle: "Review & Move to Trash…", disabled: model.operations.isExecuting || projects.isScanning) {
                Task {
                    await model.operations.review(.developerCleanup, title: "Project build folders",
                                                  candidates: projects.selectedCandidates) {
                        if case .finished(let manifest) = model.operations.phase { projects.removeProcessed(manifest) }
                    }
                }
            }
        }
    }
}
