import Foundation

/// A build-output folder that can be recreated from a project's sources.
public struct ProjectArtifactKind: Sendable, Equatable {
    public let ruleId: String
    public let ecosystem: String
    /// Name of the artifact folder inside the project, e.g. "node_modules".
    public let folderName: String
    /// The project folder must contain at least one of these files.
    public let markers: [String]
    public let consequence: String

    public static let all: [ProjectArtifactKind] = [
        ProjectArtifactKind(ruleId: "project-node-modules", ecosystem: "Node.js", folderName: "node_modules",
                            markers: ["package.json"],
                            consequence: "Run npm install (or yarn / pnpm install) in the project to restore it."),
        ProjectArtifactKind(ruleId: "project-flutter-build", ecosystem: "Flutter", folderName: "build",
                            markers: ["pubspec.yaml"], consequence: "Recreated by the next flutter build or run."),
        ProjectArtifactKind(ruleId: "project-dart-tool", ecosystem: "Dart", folderName: ".dart_tool",
                            markers: ["pubspec.yaml"], consequence: "Recreated by flutter pub get / dart pub get."),
        ProjectArtifactKind(ruleId: "project-gradle-build", ecosystem: "Gradle", folderName: "build",
                            markers: ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"],
                            consequence: "Recreated by the next Gradle build."),
        ProjectArtifactKind(ruleId: "project-gradle-cache", ecosystem: "Gradle", folderName: ".gradle",
                            markers: ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"],
                            consequence: "Gradle recreates its per-project cache on the next build."),
        ProjectArtifactKind(ruleId: "project-rust-target", ecosystem: "Rust", folderName: "target",
                            markers: ["Cargo.toml"], consequence: "Recreated by the next cargo build."),
    ]
}

/// Finds per-project build artifacts inside a folder the user chose. Read-only.
///
/// An artifact is offered only when it is a real folder next to its project's marker file
/// (e.g. `node_modules` beside `package.json`), does not itself contain version control data,
/// and `SafetyPolicy` allows it. The finder never descends into artifacts, hidden folders,
/// app or library packages, or ~/Library.
public struct ProjectArtifactFinder: Sendable {
    public let policy: SafetyPolicy
    public let probe: FileSystemProbe
    public let maxDepth: Int

    public init(policy: SafetyPolicy, probe: FileSystemProbe = .posix, maxDepth: Int = 8) {
        self.policy = policy
        self.probe = probe
        self.maxDepth = maxDepth
    }

    public func find(in root: String, progress: @Sendable (String) async -> Void = { _ in }) async throws -> [RemovalCandidate] {
        let root = PathUtilities.canonicalize(root)
        guard case .success(let rootStat) = probe.stat(root), rootStat.kind == .directory else { return [] }
        let measurer = ItemMeasurer(probe: probe)
        let skipInside = policy.home + "/Library"

        var found: [RemovalCandidate] = []
        var stack: [(String, Int)] = [(root, 0)]
        var visited = 0
        while let (dir, depth) = stack.popLast() {
            try Task.checkCancellation()
            guard case .success(let listing) = probe.list(dir) else { continue }
            visited += 1
            if visited % 200 == 0 { await progress(dir) }
            let names = Set(listing.names)

            var artifactNames = Set<String>()
            for kind in ProjectArtifactKind.all where names.contains(kind.folderName) && !artifactNames.contains(kind.folderName) {
                guard let marker = kind.markers.first(where: names.contains) else { continue }
                let path = PathUtilities.join(dir, kind.folderName)
                guard let candidate = try artifact(kind, at: path, project: dir, marker: marker, scopeRoot: root,
                                                   measurer: measurer) else { continue }
                artifactNames.insert(kind.folderName)
                found.append(candidate)
            }

            guard depth < maxDepth else { continue }
            for name in listing.names.sorted().reversed() {
                if artifactNames.contains(name) || name.hasPrefix(".") || name == "node_modules" { continue }
                let ext = (name as NSString).pathExtension.lowercased()
                if SafetyPolicy.packageExtensions.contains(ext) { continue }
                let child = PathUtilities.join(dir, name)
                if child == skipInside { continue }
                guard case .success(let st) = probe.stat(child), st.kind == .directory, st.device == rootStat.device else { continue }
                stack.append((child, depth + 1))
            }
        }
        return found.sorted { ($0.logicalBytes ?? 0) > ($1.logicalBytes ?? 0) }
    }

    private func artifact(_ kind: ProjectArtifactKind, at path: String, project: String, marker: String, scopeRoot: String,
                          measurer: ItemMeasurer) throws -> RemovalCandidate? {
        guard policy.evaluate(path, for: .developerCleanup, scopeRoot: scopeRoot).isAllowed,
              case .success(let st) = probe.stat(path), st.kind == .directory else { return nil }
        // Something that holds version control data is not a disposable build folder.
        if case .success(let inner) = probe.list(path), inner.names.contains(where: { [".git", ".hg", ".svn"].contains($0) }) {
            return nil
        }
        let measured: ItemMeasurement
        do { measured = try measurer.measure(path) }
        catch is CancellationError { throw CancellationError() }
        catch { return nil }
        guard measured.logicalBytes > 0 || measured.isLowerBound else { return nil }
        let projectName = (project as NSString).lastPathComponent
        return RemovalCandidate(
            path: path, resourceIdentifier: st.resourceIdentifier, isDirectory: true,
            logicalBytes: measured.logicalBytes, sizeIsLowerBound: measured.isLowerBound,
            modifiedAt: measured.newestModification, ruleId: kind.ruleId, category: "\(kind.ecosystem) project",
            riskLevel: .low, reason: "\(kind.ecosystem) build output of “\(projectName)”, next to \(marker).",
            consequence: kind.consequence, selectedByDefault: !measured.isLowerBound, scopeRoot: scopeRoot)
    }
}
