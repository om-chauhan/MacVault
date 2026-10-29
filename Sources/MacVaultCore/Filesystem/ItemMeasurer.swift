import Foundation

/// Measured footprint of one file or folder.
public struct ItemMeasurement: Sendable, Equatable {
    public var logicalBytes: Int64 = 0
    public var allocatedBytes: Int64 = 0
    public var fileCount = 0
    /// Items inside that could not be read; > 0 means the sizes are lower bounds.
    public var inaccessibleItems = 0
    /// Most recent modification time of anything measured inside (including the item itself).
    public var newestModification: Date?
    /// True when the item is a folder.
    public var isDirectory = false
    public var resourceIdentifier: String?

    public var isLowerBound: Bool { inaccessibleItems > 0 }
}

/// Read-only recursive size of a single item: same traversal rules as `FilesystemScanner`
/// (lstat, symlinks not followed, other volumes not entered, hard links counted once).
public struct ItemMeasurer: Sendable {
    public let probe: FileSystemProbe

    public init(probe: FileSystemProbe = .posix) {
        self.probe = probe
    }

    /// Throws `CancellationError` if the task is cancelled, or the stat failure for the item itself.
    public func measure(_ path: String) throws -> ItemMeasurement {
        let root: FileStat
        switch probe.stat(path) {
        case .failure(let failure): throw failure
        case .success(let value): root = value
        }

        var result = ItemMeasurement()
        result.resourceIdentifier = root.resourceIdentifier
        result.newestModification = root.modifiedAt
        guard root.kind == .directory else {
            if root.kind == .regular {
                result.logicalBytes = root.logicalSize
                result.allocatedBytes = root.allocatedSize
                result.fileCount = 1
            }
            return result
        }
        result.isDirectory = true

        var seen = Set<String>()
        var stack = [path]
        var sinceCheck = 0
        while let dir = stack.popLast() {
            let listing: DirectoryListing
            switch probe.list(dir) {
            case .failure:
                result.inaccessibleItems += 1
                continue
            case .success(let value):
                listing = value
            }
            result.inaccessibleItems += listing.undecodableCount
            for name in listing.names {
                sinceCheck += 1
                if sinceCheck >= 512 {
                    sinceCheck = 0
                    if Task.isCancelled { throw CancellationError() }
                }
                let child = PathUtilities.join(dir, name)
                guard case .success(let st) = probe.stat(child) else {
                    result.inaccessibleItems += 1
                    continue
                }
                if let modified = st.modifiedAt, modified > (result.newestModification ?? .distantPast) {
                    result.newestModification = modified
                }
                switch st.kind {
                case .directory:
                    if st.device == root.device { stack.append(child) }
                case .regular:
                    result.fileCount += 1
                    if st.linkCount > 1 && !seen.insert(st.resourceIdentifier).inserted { continue }
                    result.logicalBytes += st.logicalSize
                    result.allocatedBytes += st.allocatedSize
                case .symlink, .other:
                    break
                }
            }
        }
        return result
    }
}
