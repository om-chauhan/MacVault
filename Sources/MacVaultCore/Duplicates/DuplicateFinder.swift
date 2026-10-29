import Foundation

public struct DuplicateFile: Sendable, Equatable, Identifiable, Hashable {
    public var id: String { path }
    public let path: String
    public let resourceIdentifier: String
    public let modifiedAt: Date?

    public init(path: String, resourceIdentifier: String, modifiedAt: Date?) {
        self.path = path
        self.resourceIdentifier = resourceIdentifier
        self.modifiedAt = modifiedAt
    }

    public var name: String { (path as NSString).lastPathComponent }
}

/// Two or more different files (not hard links) with identical content, verified by SHA-256.
public struct DuplicateGroup: Sendable, Equatable, Identifiable {
    public var id: String { contentHash }
    public let contentHash: String
    public let sizeBytes: Int64
    public let files: [DuplicateFile]

    public init(contentHash: String, sizeBytes: Int64, files: [DuplicateFile]) {
        self.contentHash = contentHash
        self.sizeBytes = sizeBytes
        self.files = files
    }

    /// Space that would be freed (after the Trash is emptied) by keeping one copy — an estimate:
    /// APFS clones share storage, and MacVault cannot tell whether two files are clones.
    public var reclaimableBytes: Int64 { sizeBytes * Int64(max(0, files.count - 1)) }

    /// Default copy to keep: the oldest, then the shortest path, then alphabetical.
    public var suggestedKeeper: DuplicateFile {
        files.min { a, b in
            let ma = a.modifiedAt ?? .distantFuture, mb = b.modifiedAt ?? .distantFuture
            if ma != mb { return ma < mb }
            if a.path.count != b.path.count { return a.path.count < b.path.count }
            return a.path < b.path
        }!
    }

    /// Removal candidates for every copy except `keeper`. Each carries the verified hash and the
    /// keeper's path so the executor can re-verify both immediately before moving.
    public func removalItems(keeping keeper: String, manifestId: String, scopeRoot: String) -> [OperationItem] {
        guard files.contains(where: { $0.path == keeper }) else { return [] }
        return files.filter { $0.path != keeper }.map { file in
            OperationItem(manifestId: manifestId, originalPath: file.path, resourceIdentifier: file.resourceIdentifier,
                          expectedSizeBytes: sizeBytes, ruleId: "duplicate-sha256", riskLevel: .low,
                          reason: "Identical content to \(PathUtilities.abbreviatingHome(keeper)), which is kept.",
                          scopeRoot: scopeRoot, contentHash: contentHash, keeperPath: keeper)
        }
    }
}

public struct DuplicateScanResult: Sendable, Equatable {
    public let rootPath: String
    /// Sorted by reclaimable bytes, descending.
    public let groups: [DuplicateGroup]
    public let filesConsidered: Int
    public let bytesHashed: Int64
    public let inaccessibleItems: Int
    /// Names of hard-linked files (several names, one file). Never offered: removing one name frees nothing.
    public let hardLinksIgnored: Int

    public init(rootPath: String, groups: [DuplicateGroup], filesConsidered: Int, bytesHashed: Int64,
                inaccessibleItems: Int, hardLinksIgnored: Int) {
        self.rootPath = rootPath
        self.groups = groups
        self.filesConsidered = filesConsidered
        self.bytesHashed = bytesHashed
        self.inaccessibleItems = inaccessibleItems
        self.hardLinksIgnored = hardLinksIgnored
    }

    public var reclaimableBytes: Int64 { groups.reduce(0) { $0 + $1.reclaimableBytes } }
    public var isComplete: Bool { inaccessibleItems == 0 }
}

public struct DuplicateProgress: Sendable, Equatable {
    public enum Stage: String, Sendable { case listing, comparing, verifying }
    public let stage: Stage
    public let processed: Int
    public let total: Int
}

/// Finds files with identical content inside one folder. Read-only.
///
/// Stages: list files ≥ `minimumSize` (same traversal rules as the scanner) → group by size →
/// compare a 64 KiB prefix hash → verify with a full SHA-256. Hard-linked files are skipped. Files inside app or library
/// packages, version control folders, `node_modules`, ~/Library or protected locations are
/// never considered.
public struct DuplicateFinder: Sendable {
    public let policy: SafetyPolicy
    public let probe: FileSystemProbe
    public let hasher: ContentHasher
    public static let prefixBytes = 64 * 1024

    public init(policy: SafetyPolicy, probe: FileSystemProbe = .posix, hasher: ContentHasher = ContentHasher()) {
        self.policy = policy
        self.probe = probe
        self.hasher = hasher
    }

    public func find(in root: String, minimumSize: Int64 = 1_000_000, exclusions: [String] = [],
                     progress: @Sendable (DuplicateProgress) async -> Void = { _ in }) async throws -> DuplicateScanResult {
        let root = PathUtilities.canonicalize(root)
        let exclusions = exclusions.map(PathUtilities.canonicalize)
        guard case .success(let rootStat) = probe.stat(root), rootStat.kind == .directory else {
            throw ScanError.rootNotDirectory(path: root)
        }

        // 1. List candidate files.
        var bySize: [Int64: [DuplicateFile]] = [:]
        var seenInodes = Set<String>()
        var considered = 0
        var inaccessible = 0
        var hardLinks = 0
        var stack = [root]
        var listedDirs = 0
        let library = policy.home + "/Library"
        while let dir = stack.popLast() {
            try Task.checkCancellation()
            guard case .success(let listing) = probe.list(dir) else { inaccessible += 1; continue }
            inaccessible += listing.undecodableCount
            listedDirs += 1
            if listedDirs % 100 == 0 { await progress(DuplicateProgress(stage: .listing, processed: considered, total: 0)) }
            for name in listing.names {
                let path = PathUtilities.join(dir, name)
                if exclusions.contains(where: { PathUtilities.path(path, isWithin: $0) }) { continue }
                guard case .success(let st) = probe.stat(path) else { inaccessible += 1; continue }
                switch st.kind {
                case .directory:
                    let ext = (name as NSString).pathExtension.lowercased()
                    if st.device != rootStat.device || path == library || name == "node_modules"
                        || SafetyPolicy.sensitiveComponents.contains(name) || SafetyPolicy.packageExtensions.contains(ext)
                        || SafetyPolicy.protectedExtensions.contains(ext) { continue }
                    stack.append(path)
                case .regular:
                    guard st.logicalSize >= max(1, minimumSize) else { continue }
                    // A file with several names (hard links) frees nothing unless every name is removed,
                    // so it is never offered as a duplicate.
                    guard st.linkCount <= 1 else { hardLinks += 1; continue }
                    guard seenInodes.insert(st.resourceIdentifier).inserted else { continue }
                    guard policy.evaluate(path, for: .duplicateRemoval, scopeRoot: root).isAllowed else { continue }
                    considered += 1
                    bySize[st.logicalSize, default: []].append(
                        DuplicateFile(path: path, resourceIdentifier: st.resourceIdentifier, modifiedAt: st.modifiedAt))
                case .symlink, .other:
                    continue
                }
            }
        }

        // 2. Same size → same prefix hash.
        let sizeGroups = bySize.filter { $0.value.count > 1 }
        var hashed: Int64 = 0
        var prefixGroups: [(size: Int64, files: [DuplicateFile])] = []
        let prefixTotal = sizeGroups.values.reduce(0) { $0 + $1.count }
        var prefixDone = 0
        for (size, files) in sizeGroups.sorted(by: { $0.key > $1.key }) {
            var byPrefix: [String: [DuplicateFile]] = [:]
            for file in files {
                try Task.checkCancellation()
                prefixDone += 1
                if prefixDone % 50 == 0 { await progress(DuplicateProgress(stage: .comparing, processed: prefixDone, total: prefixTotal)) }
                do {
                    let digest = try hasher.prefixSHA256(path: file.path, bytes: Self.prefixBytes)
                    hashed += min(size, Int64(Self.prefixBytes))
                    byPrefix[digest, default: []].append(file)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    inaccessible += 1
                }
            }
            for group in byPrefix.values where group.count > 1 { prefixGroups.append((size, group)) }
        }

        // 3. Verify with a full hash (the prefix hash is already the full hash for small files).
        var groups: [DuplicateGroup] = []
        let verifyTotal = prefixGroups.reduce(0) { $0 + $1.files.count }
        var verified = 0
        for (size, files) in prefixGroups {
            var byHash: [String: [DuplicateFile]] = [:]
            for file in files {
                try Task.checkCancellation()
                verified += 1
                await progress(DuplicateProgress(stage: .verifying, processed: verified, total: verifyTotal))
                do {
                    let digest = try hasher.sha256(path: file.path)
                    if size > Int64(Self.prefixBytes) { hashed += size }
                    byHash[digest, default: []].append(file)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    inaccessible += 1
                }
            }
            for (digest, same) in byHash where same.count > 1 {
                groups.append(DuplicateGroup(contentHash: digest, sizeBytes: size, files: same.sorted { $0.path < $1.path }))
            }
        }

        groups.sort {
            if $0.reclaimableBytes != $1.reclaimableBytes { return $0.reclaimableBytes > $1.reclaimableBytes }
            return $0.contentHash < $1.contentHash
        }
        return DuplicateScanResult(rootPath: root, groups: groups, filesConsidered: considered, bytesHashed: hashed,
                                   inaccessibleItems: inaccessible, hardLinksIgnored: hardLinks)
    }
}
