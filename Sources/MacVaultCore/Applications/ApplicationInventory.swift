import Foundation

/// Lists installed application bundles and the ~/Library data that probably belongs to them. Read-only.
///
/// App removal and leftover-data removal are deliberately separate: `uninstallCandidate(for:)`
/// returns only the bundle, and `associatedItems(for:)` returns data candidates for a separate review.
/// Login items (LaunchAgents), keychains and group containers are never offered.
public struct ApplicationInventory: Sendable {
    public let roots: [String]
    public let policy: SafetyPolicy
    public let probe: FileSystemProbe
    /// MacVault's own bundle identifier; listed as protected.
    public let ownBundleId: String?

    public init(roots: [String]? = nil, policy: SafetyPolicy, probe: FileSystemProbe = .posix, ownBundleId: String? = nil) {
        self.roots = (roots ?? policy.applicationRoots).map(PathUtilities.canonicalize)
        self.policy = policy
        self.probe = probe
        self.ownBundleId = ownBundleId
    }

    /// Application bundles directly inside each root and one folder level below (e.g. /Applications/Utilities).
    public func bundlePaths() -> [String] {
        var paths: [String] = []
        for root in roots {
            guard case .success(let listing) = probe.list(root) else { continue }
            for name in listing.names.sorted() {
                let path = PathUtilities.join(root, name)
                guard case .success(let st) = probe.stat(path), st.kind == .directory else { continue }
                if name.lowercased().hasSuffix(".app") {
                    paths.append(path)
                } else if case .success(let inner) = probe.list(path) {
                    for innerName in inner.names.sorted() where innerName.lowercased().hasSuffix(".app") {
                        let innerPath = PathUtilities.join(path, innerName)
                        if case .success(let ist) = probe.stat(innerPath), ist.kind == .directory { paths.append(innerPath) }
                    }
                }
            }
        }
        return paths
    }

    /// Reads every bundle's Info.plist and (optionally) measures its size.
    public func scan(measureSizes: Bool = true, now: Date = Date(),
                     progress: @Sendable (Int, Int) async -> Void = { _, _ in }) async throws -> [ApplicationRecord] {
        let paths = bundlePaths()
        let measurer = ItemMeasurer(probe: probe)
        var records: [ApplicationRecord] = []
        for (index, path) in paths.enumerated() {
            try Task.checkCancellation()
            await progress(index, paths.count)
            let info = Self.readInfo(bundlePath: path)
            let fileName = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            let bundleId = info?["CFBundleIdentifier"] as? String
            let name = (info?["CFBundleDisplayName"] as? String) ?? (info?["CFBundleName"] as? String) ?? fileName
            let version = (info?["CFBundleShortVersionString"] as? String) ?? (info?["CFBundleVersion"] as? String)

            var size: Int64?
            var lowerBound = false
            var resourceId: String?
            if case .success(let st) = probe.stat(path) { resourceId = st.resourceIdentifier }
            if measureSizes {
                do {
                    let measured = try measurer.measure(path)
                    size = measured.logicalBytes
                    lowerBound = measured.isLowerBound
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    size = nil
                }
            }
            let protection = protectionReason(path: path, bundleId: bundleId)
            records.append(ApplicationRecord(
                bundlePath: path, bundleId: bundleId, displayName: name.isEmpty ? fileName : name, version: version,
                bundleSizeBytes: size, sizeIsLowerBound: lowerBound, isProtected: protection != nil,
                protectionReason: protection, resourceIdentifier: resourceId, observedAt: now))
        }
        await progress(paths.count, paths.count)
        return records.sorted { ($0.bundleSizeBytes ?? -1) > ($1.bundleSizeBytes ?? -1) }
    }

    func protectionReason(path: String, bundleId: String?) -> String? {
        if let bundleId {
            if bundleId.lowercased().hasPrefix("com.apple.") { return "Apple app — part of macOS or managed by Apple" }
            if let ownBundleId, bundleId == ownBundleId { return "MacVault itself" }
        }
        if case .denied(let why) = policy.evaluate(path, for: .appUninstall, scopeRoot: nil) { return why }
        return nil
    }

    static func readInfo(bundlePath: String) -> [String: Any]? {
        let plist = bundlePath + "/Contents/Info.plist"
        guard let data = FileManager.default.contents(atPath: plist),
              let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else { return nil }
        return object as? [String: Any]
    }

    // MARK: Removal candidates

    /// The bundle itself, for the App removal review. Nil for protected apps.
    public func uninstallCandidate(for app: ApplicationRecord) -> RemovalCandidate? {
        guard !app.isProtected, policy.evaluate(app.bundlePath, for: .appUninstall, scopeRoot: nil).isAllowed,
              case .success(let st) = probe.stat(app.bundlePath), st.kind == .directory else { return nil }
        return RemovalCandidate(
            path: app.bundlePath, resourceIdentifier: st.resourceIdentifier, isDirectory: true,
            logicalBytes: app.bundleSizeBytes, sizeIsLowerBound: app.sizeIsLowerBound, modifiedAt: st.modifiedAt,
            ruleId: "app-bundle", category: "Application", riskLevel: .medium,
            reason: "The \(app.displayName) application bundle.",
            consequence: "The app can no longer be opened. Its settings and data in your Library are kept unless you remove them separately.",
            selectedByDefault: true, scopeRoot: nil)
    }

    private struct Location {
        let relative: String
        let kind: String
        let risk: RiskLevel
        let consequence: String
    }

    /// ~/Library data that probably belongs to `app`. Only items named exactly after its bundle
    /// identifier are high confidence; name matches are medium and never pre-selected.
    public func associatedItems(for app: ApplicationRecord) -> [AssociatedItem] {
        guard !app.isProtected else { return [] }
        let home = policy.home
        var names: [(String, MatchConfidence)] = []
        if let id = app.bundleId, !id.isEmpty { names.append((id, .high)) }
        let display = app.displayName.trimmingCharacters(in: .whitespaces)
        if display.count >= 4, !Self.genericNames.contains(display.lowercased()), display != app.bundleId {
            names.append((display, .medium))
        }

        var items: [AssociatedItem] = []
        var seen = Set<String>()
        for (name, confidence) in names {
            var locations = [
                Location(relative: "Library/Application Support/\(name)", kind: "Application Support", risk: .medium,
                         consequence: "Documents, libraries or settings you created in the app may be lost."),
                Location(relative: "Library/Caches/\(name)", kind: "Cache", risk: .low,
                         consequence: "Recreated if the app is installed again."),
                Location(relative: "Library/Logs/\(name)", kind: "Logs", risk: .low,
                         consequence: "Diagnostic history is no longer available."),
            ]
            if confidence == .high {
                locations += [
                    Location(relative: "Library/Preferences/\(name).plist", kind: "Preferences", risk: .low,
                             consequence: "The app’s settings are reset if it is installed again."),
                    Location(relative: "Library/Containers/\(name)", kind: "Container", risk: .medium,
                             consequence: "Everything the sandboxed app stored, which may include your documents, is removed."),
                    Location(relative: "Library/Saved Application State/\(name).savedState", kind: "Saved state", risk: .low,
                             consequence: "Open windows are not restored on next launch."),
                    Location(relative: "Library/HTTPStorages/\(name)", kind: "Web storage", risk: .low,
                             consequence: "Website data stored by the app is removed; you may need to sign in again."),
                    Location(relative: "Library/HTTPStorages/\(name).binarycookies", kind: "Cookies", risk: .low,
                             consequence: "You may need to sign in again."),
                    Location(relative: "Library/WebKit/\(name)", kind: "WebKit data", risk: .low,
                             consequence: "Website data stored by the app is removed."),
                    Location(relative: "Library/Cookies/\(name).binarycookies", kind: "Cookies", risk: .low,
                             consequence: "You may need to sign in again."),
                ]
            }
            for location in locations {
                let path = PathUtilities.join(home, location.relative)
                guard !seen.contains(path) else { continue }
                let scope = SafetyPolicy.leftoverScopes.map { home + "/" + $0 }
                    .first { PathUtilities.path(path, isWithin: $0) && path != $0 }
                guard let scope, policy.evaluate(path, for: .appLeftovers, scopeRoot: scope).isAllowed,
                      case .success(let st) = probe.stat(path), st.kind == .directory || st.kind == .regular else { continue }
                seen.insert(path)
                let measured = try? ItemMeasurer(probe: probe).measure(path)
                let candidate = RemovalCandidate(
                    path: path, resourceIdentifier: st.resourceIdentifier, isDirectory: st.kind == .directory,
                    logicalBytes: measured?.logicalBytes, sizeIsLowerBound: measured?.isLowerBound ?? true,
                    modifiedAt: measured?.newestModification, ruleId: "app-leftover-\(confidence.rawValue)",
                    category: location.kind, riskLevel: location.risk,
                    reason: "\(location.kind) named after \(confidence == .high ? "the bundle identifier" : "the app name") “\(name)”.",
                    consequence: location.consequence,
                    selectedByDefault: confidence == .high && location.risk == .low, scopeRoot: scope)
                items.append(AssociatedItem(candidate: candidate, confidence: confidence, kind: location.kind))
            }
        }
        return items.sorted { ($0.candidate.logicalBytes ?? 0) > ($1.candidate.logicalBytes ?? 0) }
    }

    /// Display names too common to match data folders on.
    static let genericNames: Set<String> = [
        "google", "microsoft", "adobe", "apple", "app", "application", "helper", "updater", "setup", "install",
        "installer", "launcher", "agent", "service", "tools", "utility", "utilities", "default", "shared", "common",
    ]
}
