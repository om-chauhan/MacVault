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
            ScreenHeader(item: .developer, subtitle: section == .caches
                         ? "Xcode, Simulator, Gradle, npm and Dart caches"
                         : "Build folders inside your projects") {
                switch section {
                case .caches: cachesControls
                case .projects: projectControls
                }
            }

            VStack(alignment: .leading, spacing: Spacing.s) {
                HStack(spacing: Spacing.s) {
                    Picker("Section", selection: $section) {
                        ForEach(Area.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    Spacer(minLength: Spacing.s)
                    if section == .projects { projectFolderMenu }
                }
                OperationStatusPanel(types: [.developerCleanup])
                if let error = section == .caches ? model.developerCaches.error : model.projects.error {
                    InlineBanner(kind: .error, title: "Review could not finish", message: error)
                }
                OperationHistoryList(types: [.developerCleanup])
                switch section {
                case .caches: cachesContent
                case .projects: projectsContent
                }
            }
            .padding(.horizontal, Spacing.l)
            .padding(.bottom, Spacing.m)
            .frame(maxHeight: .infinity, alignment: .top)

            footer
        }
        .navigationTitle("Developer Tools")
    }

    // MARK: Global caches

    private var cachesControls: some View {
        let scan = model.developerCaches
        return HStack(spacing: Spacing.xs) {
            if scan.isScanning {
                ProgressView().controlSize(.small)
                Text(scan.currentRule ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Button("Stop") { scan.cancel() }
                    .help("Stop looking. Nothing has been changed.")
            } else if !scan.findings.isEmpty {
                // Before the first check the start screen holds the only button.
                Button("Check Again") { scan.scan(policy: model.operations.policy) }
                    .disabled(model.operations.isExecuting)
                    .help(model.operations.isExecuting ? "Wait until items are moved to the Trash." : "Look for developer caches again. Read-only.")
            }
        }
    }

    @ViewBuilder
    private var cachesContent: some View {
        let scan = model.developerCaches
        if scan.findings.isEmpty && scan.isScanning {
            LoadingState(title: "Looking for developer caches…", message: scan.currentRule)
        } else if scan.findings.isEmpty {
            StartScreen(
                item: .developer, title: "Reclaim developer caches",
                message: "Xcode, Simulator, Gradle, npm and Dart caches are listed by tool, with what rebuilding each one costs. Higher-risk items such as archives are never pre-selected.",
                actionTitle: "Find Caches", actionDisabled: model.operations.isExecuting,
                actionHelp: model.operations.isExecuting ? "Wait until items are moved to the Trash." : "Look for developer caches. Read-only.",
                note: "Read-only · rules \(RuleCatalog.version)",
                checksTitle: "What it looks for",
                checks: RuleCatalog.developerRules.map(StartFact.init(rule:)),
                safety: [
                    StartFact("Source code and Git data", symbol: "chevron.left.forwardslash.chevron.right",
                              detail: "Only caches and build products are offered; projects and version control data are never listed."),
                    StartFact("Signing assets", symbol: "key.fill",
                              detail: "Certificates, provisioning profiles and keychains are never listed."),
                    StartFact("Simulator devices", symbol: "iphone",
                              detail: "Your simulators and the apps installed on them stay; only their caches are offered."),
                    StartFact("Tools in use", symbol: "play.circle.fill",
                              detail: "Xcode and Simulator caches are skipped while those tools are running."),
                ]) { scan.scan(policy: model.operations.policy) }
        } else {
            ReviewSummaryCard(title: "Found", symbol: "hammer.fill", tint: Palette.developer,
                              totalBytes: scan.findings.reduce(0) { $0 + $1.totalBytes },
                              itemCount: scan.allCandidates.count,
                              selectedCount: scan.selectedCandidates.count, selectedBytes: scan.selectedBytes,
                              segments: RuleFindingsList.segments(scan, tint: Palette.developer),
                              info: "Measured size per tool. Archives are high risk and never pre-selected; Xcode and Simulator caches are skipped while those tools run.")
            RuleFindingsList(scan: scan)
        }
    }

    // MARK: Projects

    private var projectFolderMenu: some View {
        let projects = model.projects
        return Menu {
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
            Label((projectLocation?.displayPath ?? "Choose a folder").middleTruncated(36), systemImage: "folder")
        }
        .fixedSize()
        .disabled(projects.isScanning)
        .help(projectLocation.map { "Projects folder: \($0.path)" } ?? "Choose the folder that contains your projects")
    }

    private var projectControls: some View {
        let projects = model.projects
        return HStack(spacing: Spacing.xs) {
            if projects.isScanning {
                ProgressView().controlSize(.small)
                Button("Stop") { projects.cancel() }
                    .help("Stop looking. Nothing has been changed.")
            } else if projectSearched {
                // Before the first search the start screen holds the only button.
                Button("Search Again") {
                    if let location = projectLocation {
                        projects.scan(location: location, access: model.access, policy: model.operations.policy)
                    }
                }
                .disabled(projectLocation == nil || model.operations.isExecuting)
                .help(projectLocation == nil ? "Choose a projects folder first." : "Look for build folders next to project files again. Read-only.")
            }
        }
    }

    /// The chosen projects folder has been searched (its results, possibly none, are shown).
    private var projectSearched: Bool {
        model.projects.scannedPath != nil && model.projects.scannedPath == projectLocation?.path
    }

    private var projectLocation: AuthorizedLocation? {
        let id = model.projects.locationID ?? model.selectedLocationID
        return model.access.locations.first { $0.id == id } ?? model.access.locations.first
    }

    @ViewBuilder
    private var projectsContent: some View {
        let projects = model.projects
        if projects.candidates.isEmpty && projects.isScanning {
            LoadingState(title: "Looking for project build folders…",
                         message: "Only folders next to their project files are listed. Nothing is changed.")
        } else if projects.candidates.isEmpty && projectSearched {
            // "Search Again" is in the header.
            EmptyState(title: "No build folders found", symbol: "shippingbox",
                       message: "No build folders were found next to project files in \(PathUtilities.abbreviatingHome(projects.scannedPath ?? "")).")
        } else if projects.candidates.isEmpty {
            StartScreen(
                item: .developer, title: "Find build folders in your projects",
                message: "Build output a tool can recreate (node_modules, build, target, …) is listed only when it sits next to its project file, so your sources are never mistaken for output.",
                actionTitle: "Find Build Folders",
                actionDisabled: projectLocation == nil || model.operations.isExecuting,
                actionHelp: projectLocation == nil ? "Choose a projects folder first." : "Look for build folders next to project files. Read-only.",
                note: projectLocation.map { "In \($0.displayPath)" } ?? "Choose a projects folder above",
                checksTitle: "Folders it recognises",
                checks: ProjectArtifactKind.all.map { kind in
                    StartFact("\(kind.ecosystem) · \(kind.folderName)", symbol: "shippingbox.fill",
                              detail: "Next to \(kind.markers.joined(separator: " or ")). \(kind.consequence)")
                },
                safety: [
                    StartFact("Your source files", symbol: "chevron.left.forwardslash.chevron.right",
                              detail: "Only the build output folder is offered; the project itself is never listed."),
                    StartFact("Git data", symbol: "arrow.triangle.branch",
                              detail: "Folders that contain version control data are never offered, and .git is never entered."),
                    StartFact("Packages and your Library", symbol: "shippingbox",
                              detail: "App and library packages, hidden folders and ~/Library are never searched."),
                ]) {
                    if let location = projectLocation {
                        projects.scan(location: location, access: model.access, policy: model.operations.policy)
                    }
                }
        } else {
            ReviewSummaryCard(title: "Found", symbol: "shippingbox.fill", tint: Palette.developer,
                              totalBytes: projects.candidates.reduce(0) { $0 + ($1.logicalBytes ?? 0) },
                              itemCount: projects.candidates.count,
                              selectedCount: projects.selectedCandidates.count, selectedBytes: projects.selectedBytes,
                              segments: projectSegments(projects.candidates),
                              info: "Measured size per kind of build folder, found only next to its project files.")
            List {
                Section {
                    ForEach(projects.candidates) { candidate in
                        CandidateRow(candidate: candidate, isSelected: Binding(
                            get: { projects.selection.contains(candidate.id) },
                            set: { if $0 { projects.selection.insert(candidate.id) } else { projects.selection.remove(candidate.id) } }),
                                     disabled: !OperationsModel.canModifyFiles)
                    }
                    // A row rather than a section footer, so it wraps in narrow windows.
                    Text("Each folder is recreated by its build tool. Projects that are open in an editor may need to be rebuilt.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .listRowSeparator(.hidden)
                }
            }
            .listStyle(.inset)
            .listInCard()
        }
    }

    /// Size per kind of build folder (node_modules, build, target, …).
    private func projectSegments(_ candidates: [RemovalCandidate]) -> [ChartSegment] {
        let byName = Dictionary(grouping: candidates, by: \.name)
        return byName.keys.sorted().enumerated().map { index, name in
            ChartSegment(id: name, label: name, bytes: byName[name]!.reduce(0) { $0 + ($1.logicalBytes ?? 0) },
                         color: index == 0 ? Palette.developer : Palette.series[(index + 1) % Palette.series.count])
        }
    }

    // MARK: Footer

    /// Shown only once there is something to review.
    @ViewBuilder
    private var footer: some View {
        switch section {
        case .caches:
            let scan = model.developerCaches
            if !scan.findings.isEmpty {
                ReviewFooter(count: scan.selectedCandidates.count, bytes: scan.selectedBytes, buttonTitle: "Review & Move to Trash…",
                             disabled: model.operations.isExecuting || scan.isScanning) {
                    Task {
                        await model.operations.review(.developerCleanup, title: "Developer caches", candidates: scan.selectedCandidates,
                                                      inUseCheck: { RunningApps.cleanupConflict($0) }) {
                            if case .finished(let manifest) = model.operations.phase { scan.removeProcessed(manifest) }
                        }
                    }
                }
            }
        case .projects:
            let projects = model.projects
            if !projects.candidates.isEmpty {
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
}
