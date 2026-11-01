import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Candidates one rule produced, plus anything the rule could not see.
public struct RuleFindings: Sendable, Equatable, Identifiable {
    public var id: String { rule.id }
    public let rule: CleanupRule
    public let candidates: [RemovalCandidate]
    /// The rule's folder does not exist (nothing to do — not an error).
    public let locationMissing: Bool
    /// The rule's folder exists but could not be read (e.g. permission).
    public let locationError: String?
    /// Items the rule matched but `SafetyPolicy` refused or the rule excluded.
    public let protectedCount: Int
    /// Items skipped because they were modified too recently.
    public let tooRecentCount: Int

    public var totalBytes: Int64 { candidates.reduce(0) { $0 + ($1.logicalBytes ?? 0) } }

    public init(rule: CleanupRule, candidates: [RemovalCandidate], locationMissing: Bool, locationError: String?,
                protectedCount: Int, tooRecentCount: Int) {
        self.rule = rule
        self.candidates = candidates
        self.locationMissing = locationMissing
        self.locationError = locationError
        self.protectedCount = protectedCount
        self.tooRecentCount = tooRecentCount
    }
}

/// Evaluates cleanup rules read-only. Produces candidates; never changes anything.
public struct CleanupCandidateFinder: Sendable {
    public let home: String
    public let policy: SafetyPolicy
    public let probe: FileSystemProbe
    public let now: @Sendable () -> Date
    /// Whether an app with this bundle identifier is installed (or running). Needed by rules that
    /// offer leftovers of uninstalled apps; without it those rules offer nothing.
    public let isInstalled: (@Sendable (String) -> Bool)?
    /// Bundle identifiers of the apps installed in the Applications folders, for the vendor check
    /// on preference files (a shared "com.vendor.suite" file belongs to whichever vendor app is installed).
    public let installedBundleIdentifiers: Set<String>

    public init(home: String = NSHomeDirectory(), policy: SafetyPolicy? = nil, probe: FileSystemProbe = .posix,
                now: @escaping @Sendable () -> Date = { Date() }, isInstalled: (@Sendable (String) -> Bool)? = nil,
                installedBundleIdentifiers: Set<String> = []) {
        let canonicalHome = PathUtilities.canonicalize(home)
        self.home = canonicalHome
        self.policy = policy ?? SafetyPolicy(home: canonicalHome)
        self.probe = probe
        self.now = now
        self.isInstalled = isInstalled
        self.installedBundleIdentifiers = installedBundleIdentifiers
    }

    /// An owner counts as installed when it, or the app it extends, is installed: "com.vendor.app.Widgets"
    /// belongs to "com.vendor.app". For shared files (`vendorWide`), any installed app of the same vendor
    /// ("com.vendor.*") counts, because "com.vendor.suite" preferences are shared by the suite's apps.
    func ownerIsInstalled(_ owner: String, vendorWide: Bool) -> Bool {
        guard let isInstalled else { return true }
        let parts = owner.split(separator: ".").map(String.init)
        for count in stride(from: parts.count, through: 3, by: -1) {
            let candidate = parts.prefix(count).joined(separator: ".")
            if installedBundleIdentifiers.contains(candidate) || isInstalled(candidate) { return true }
        }
        if vendorWide, parts.count >= 2 {
            let vendor = parts.prefix(2).joined(separator: ".") + "."
            if installedBundleIdentifiers.contains(where: { $0.hasPrefix(vendor) }) { return true }
        }
        return false
    }

    public func evaluate(_ rules: [CleanupRule],
                         progress: @Sendable (CleanupRule) async -> Void = { _ in }) async throws -> [RuleFindings] {
        var results: [RuleFindings] = []
        for rule in rules {
            try Task.checkCancellation()
            await progress(rule)
            results.append(try evaluate(rule))
        }
        return results
    }

    public func evaluate(_ rule: CleanupRule) throws -> RuleFindings {
        if rule.onlyOrphanedOwners && isInstalled == nil {
            return RuleFindings(rule: rule, candidates: [], locationMissing: false,
                                locationError: "Installed applications could not be determined", protectedCount: 0, tooRecentCount: 0)
        }
        let measurer = ItemMeasurer(probe: probe)
        let scopeRoot: String
        var paths: [String] = []

        switch rule.target {
        case .childrenOf(let relative):
            scopeRoot = PathUtilities.join(home, relative)
            switch probe.list(scopeRoot) {
            case .failure(let failure):
                return RuleFindings(rule: rule, candidates: [], locationMissing: failure.code == ENOENT,
                                    locationError: failure.code == ENOENT ? nil : failure.message,
                                    protectedCount: 0, tooRecentCount: 0)
            case .success(let listing):
                paths = listing.names.sorted().map { PathUtilities.join(scopeRoot, $0) }
            }
        case .item(let relative):
            let path = PathUtilities.join(home, relative)
            scopeRoot = (path as NSString).deletingLastPathComponent
            if case .failure(let failure) = probe.stat(path) {
                return RuleFindings(rule: rule, candidates: [], locationMissing: failure.code == ENOENT,
                                    locationError: failure.code == ENOENT ? nil : failure.message,
                                    protectedCount: 0, tooRecentCount: 0)
            }
            paths = [path]
        }

        var candidates: [RemovalCandidate] = []
        var protectedCount = 0
        var tooRecent = 0
        let cutoff = rule.minimumAgeDays.map { now().addingTimeInterval(-Double($0) * 86_400) }

        for path in paths {
            try Task.checkCancellation()
            let name = (path as NSString).lastPathComponent
            if rule.excludedPrefixes.contains(where: { name.hasPrefix($0) }) || name == ".DS_Store" {
                protectedCount += 1
                continue
            }
            guard policy.evaluate(path, for: rule.operation, scopeRoot: scopeRoot).isAllowed else {
                protectedCount += 1
                continue
            }
            guard case .success(let st) = probe.stat(path), st.kind == .directory || st.kind == .regular else {
                continue // symlinks and special files are never offered
            }
            if let extensions = rule.includedExtensions {
                // Files of the listed kinds only; anything else in the folder is simply not this rule's business.
                guard st.kind == .regular, extensions.contains((name as NSString).pathExtension.lowercased()) else { continue }
            }
            if rule.onlyOrphanedOwners {
                // Only names that are clearly an app's bundle identifier are judged; "Slack" or "Adobe" are left alone.
                let isFile = rule.includedExtensions != nil
                let owner = isFile ? (name as NSString).deletingPathExtension : name
                guard CleanupRule.looksLikeBundleIdentifier(owner) else { continue }
                if ownerIsInstalled(owner, vendorWide: isFile) {
                    protectedCount += 1
                    continue
                }
            }
            let measured: ItemMeasurement
            do { measured = try measurer.measure(path) }
            catch is CancellationError { throw CancellationError() }
            catch { continue }

            if let cutoff, let newest = measured.newestModification, newest > cutoff {
                tooRecent += 1
                continue
            }
            if measured.logicalBytes == 0 && measured.allocatedBytes == 0 && !measured.isLowerBound { continue }

            candidates.append(RemovalCandidate(
                path: path, resourceIdentifier: st.resourceIdentifier, isDirectory: st.kind == .directory,
                logicalBytes: measured.logicalBytes, sizeIsLowerBound: measured.isLowerBound,
                modifiedAt: measured.newestModification, ruleId: rule.id, category: rule.category.displayName,
                riskLevel: rule.risk, reason: rule.explanation, consequence: rule.consequence,
                selectedByDefault: rule.selectedByDefault && !measured.isLowerBound, scopeRoot: scopeRoot))
        }
        candidates.sort { ($0.logicalBytes ?? 0) > ($1.logicalBytes ?? 0) }
        return RuleFindings(rule: rule, candidates: candidates, locationMissing: false, locationError: nil,
                            protectedCount: protectedCount, tooRecentCount: tooRecent)
    }
}
