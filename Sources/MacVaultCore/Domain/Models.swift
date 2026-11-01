import Foundation

// MARK: - Scan status

/// Lifecycle status of a scan session.
///
/// `completed` is only used when every reachable item was read without error.
/// A scan with inaccessible items or read errors is `partial`; it is never
/// promoted to `completed`.
public enum ScanStatus: String, Sendable, Codable, CaseIterable {
    case running
    case completed
    case partial
    case cancelled
    case failed
    /// The app stopped (crash, force quit) while the scan was running.
    /// Set during launch reconciliation.
    case interrupted

    public var isTerminal: Bool { self != .running }

    public var displayName: String {
        switch self {
        case .running: return "Running"
        case .completed: return "Completed"
        case .partial: return "Scan incomplete"
        case .cancelled: return "Cancelled"
        case .failed: return "Failed"
        case .interrupted: return "Interrupted"
        }
    }
}

// MARK: - Scan configuration

public struct ScanConfiguration: Sendable, Equatable {
    /// Canonical absolute path of the scan root (symlinks in the root path resolved).
    public let rootPath: String
    /// Canonical absolute path prefixes that are skipped entirely.
    public let exclusions: [String]
    /// Files at or above this logical size become large-file findings.
    public var largeFileThresholdBytes: Int64
    /// Upper bound on large-file findings kept in memory and persisted.
    public var maxLargeFileFindings: Int
    /// When false (default), directories on a different device than the root are not entered.
    public var crossMountPoints: Bool
    /// Minimum seconds between progress callbacks.
    public var progressInterval: Double
    /// Upper bound on individual issues retained (all issues are still counted).
    public var maxRecordedIssues: Int
    /// Directories up to this depth below the root get their own rolled-up size for drill-down (0 disables).
    public var maxTreeDepth: Int
    /// Upper bound on tree nodes kept in the result; the largest are kept, always with their ancestors.
    public var maxTreeNodes: Int

    public init(
        rootPath: String,
        exclusions: [String] = [],
        largeFileThresholdBytes: Int64 = 100 * 1_000_000,
        maxLargeFileFindings: Int = 500,
        crossMountPoints: Bool = false,
        progressInterval: Double = 0.25,
        maxRecordedIssues: Int = 200,
        maxTreeDepth: Int = 4,
        maxTreeNodes: Int = 4000
    ) {
        self.rootPath = PathUtilities.canonicalize(rootPath)
        self.exclusions = exclusions.map(PathUtilities.canonicalize).filter { !$0.isEmpty }
        self.largeFileThresholdBytes = max(0, largeFileThresholdBytes)
        self.maxLargeFileFindings = max(1, maxLargeFileFindings)
        self.crossMountPoints = crossMountPoints
        self.progressInterval = max(0, progressInterval)
        self.maxRecordedIssues = max(0, maxRecordedIssues)
        self.maxTreeDepth = max(0, maxTreeDepth)
        self.maxTreeNodes = max(0, maxTreeNodes)
    }

    public func isExcluded(_ path: String) -> Bool {
        exclusions.contains { PathUtilities.path(path, isWithin: $0) }
    }

    /// Root path that means "the whole startup disk".
    public static let wholeVolumeRoot = "/"

    /// Exclusions a scan of `root` needs to stay correct, independent of user settings.
    ///
    /// On macOS the startup disk is a volume group: `/` is the sealed System volume and user data lives
    /// on the Data volume, mounted at `/System/Volumes/Data` and firmlinked into `/Users`, `/Applications`,
    /// `/Library`, … The kernel reports the same device for both, so a scan of `/` would otherwise count
    /// everything twice (once through the firmlinks, once under `/System/Volumes/Data`). The other mounts
    /// under `/System/Volumes` (Preboot, VM, Update, …) are also reached through their firmlinks.
    public static func implicitExclusions(forRoot root: String) -> [String] {
        PathUtilities.canonicalize(root) == wholeVolumeRoot ? ["/System/Volumes"] : []
    }
}

// MARK: - Progress

public struct ScanProgress: Sendable, Equatable {
    public var filesVisited: Int
    public var directoriesVisited: Int
    public var logicalBytes: Int64
    public var inaccessibleItems: Int
    public var currentDirectory: String
    public var elapsedSeconds: Double

    public init(filesVisited: Int = 0, directoriesVisited: Int = 0, logicalBytes: Int64 = 0,
                inaccessibleItems: Int = 0, currentDirectory: String = "", elapsedSeconds: Double = 0) {
        self.filesVisited = filesVisited
        self.directoriesVisited = directoriesVisited
        self.logicalBytes = logicalBytes
        self.inaccessibleItems = inaccessibleItems
        self.currentDirectory = currentDirectory
        self.elapsedSeconds = elapsedSeconds
    }
}

// MARK: - Counters

public struct ScanCounters: Sendable, Equatable {
    public var filesVisited = 0
    public var directoriesVisited = 0
    /// Sum of logical (st_size) sizes of regular files, hard links counted once.
    public var logicalBytes: Int64 = 0
    /// Sum of allocated sizes (st_blocks × 512), hard links counted once.
    /// May overstate physical usage on APFS because clones share blocks.
    public var allocatedBytes: Int64 = 0
    public var inaccessibleItems = 0
    /// Errors other than permission/lookup failures (e.g. undecodable names, read errors).
    public var otherErrors = 0
    public var symlinksSkipped = 0
    public var excludedItems = 0
    public var mountPointsSkipped = 0
    public var hardLinkRepeats = 0
    /// Sockets, FIFOs, device nodes — counted but not sized.
    public var specialItems = 0

    public init() {}
}

// MARK: - Issues

public enum ScanIssueKind: String, Sendable, Codable {
    case unreadableDirectory
    case metadataUnavailable
    case undecodableName
    case mountPointSkipped
}

public struct ScanIssue: Sendable, Equatable, Codable {
    public let path: String
    public let kind: ScanIssueKind
    /// POSIX errno where applicable.
    public let errorCode: Int32?

    public init(path: String, kind: ScanIssueKind, errorCode: Int32?) {
        self.path = path
        self.kind = kind
        self.errorCode = errorCode
    }

    public var errorDescription: String? {
        errorCode.map { POSIXFailure(code: $0).message }
    }
}

// MARK: - Results

public struct LargeFileRecord: Sendable, Equatable, Identifiable {
    public var id: String { path }
    public let path: String
    public let logicalSizeBytes: Int64
    public let allocatedSizeBytes: Int64?
    public let modifiedAt: Date?
    /// "device:inode" observed during the scan.
    public let resourceIdentifier: String?

    public init(path: String, logicalSizeBytes: Int64, allocatedSizeBytes: Int64?, modifiedAt: Date?, resourceIdentifier: String?) {
        self.path = path
        self.logicalSizeBytes = logicalSizeBytes
        self.allocatedSizeBytes = allocatedSizeBytes
        self.modifiedAt = modifiedAt
        self.resourceIdentifier = resourceIdentifier
    }
}

/// Measured footprint of one immediate child of the scan root.
public struct DirectoryAggregate: Sendable, Equatable, Identifiable {
    public var id: String { path }
    public let name: String
    public let path: String
    public let isDirectory: Bool
    public var logicalBytes: Int64
    public var allocatedBytes: Int64
    public var fileCount: Int
    /// Items inside this entry that could not be read; > 0 means the size is a lower bound.
    public var inaccessibleItems: Int

    public init(name: String, path: String, isDirectory: Bool, logicalBytes: Int64 = 0,
                allocatedBytes: Int64 = 0, fileCount: Int = 0, inaccessibleItems: Int = 0) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.logicalBytes = logicalBytes
        self.allocatedBytes = allocatedBytes
        self.fileCount = fileCount
        self.inaccessibleItems = inaccessibleItems
    }

    public var isComplete: Bool { inaccessibleItems == 0 }
}

/// Rolled-up size of a directory below the scan root, used for drill-down and the treemap.
/// Sizes include everything measured beneath the directory (hard links counted once per scan).
public struct TreeNode: Sendable, Equatable, Identifiable {
    public var id: String { path }
    public let path: String
    /// Nil for depth-1 nodes (their parent is the scan root).
    public let parentPath: String?
    public let name: String
    /// 1 = immediate child of the scan root.
    public let depth: Int
    public var logicalBytes: Int64
    public var allocatedBytes: Int64
    public var fileCount: Int
    public var inaccessibleItems: Int

    public init(path: String, parentPath: String?, name: String, depth: Int, logicalBytes: Int64 = 0,
                allocatedBytes: Int64 = 0, fileCount: Int = 0, inaccessibleItems: Int = 0) {
        self.path = path
        self.parentPath = parentPath
        self.name = name
        self.depth = depth
        self.logicalBytes = logicalBytes
        self.allocatedBytes = allocatedBytes
        self.fileCount = fileCount
        self.inaccessibleItems = inaccessibleItems
    }

    public var isComplete: Bool { inaccessibleItems == 0 }
}

public struct ScanResult: Sendable {
    public let rootPath: String
    public let status: ScanStatus
    public let counters: ScanCounters
    /// Sorted by logical size, descending.
    public let largeFiles: [LargeFileRecord]
    /// Immediate children of the root, sorted by logical size, descending.
    public let topLevel: [DirectoryAggregate]
    /// Directory tree for drill-down, bounded by `maxTreeDepth`/`maxTreeNodes`. Sorted by size, descending;
    /// every node's ancestors are included.
    public let tree: [TreeNode]
    /// First `maxRecordedIssues` issues.
    public let issues: [ScanIssue]
    /// Total issues encountered (may exceed `issues.count`).
    public let issueCount: Int
    public let startedAt: Date
    public let finishedAt: Date
}

// MARK: - Findings (persisted)

public enum FindingCategory: String, Sendable, Codable {
    case largeFile
}

public enum RiskLevel: String, Sendable, Codable {
    /// No cleanup rule has evaluated this item. Large-file findings are informational.
    case notAssessed
    case low
    case medium
    case high
    case protected
}

public enum EligibilityStatus: String, Sendable, Codable {
    /// Shown for review only; no cleanup action is offered.
    case reviewOnly
    case eligible
    case ineligible
}

public struct FileFinding: Sendable, Equatable, Identifiable {
    public let id: String
    public let scanId: String
    public let path: String
    public let resourceIdentifier: String?
    public let category: FindingCategory
    public let logicalSizeBytes: Int64?
    public let allocatedSizeBytes: Int64?
    public let modifiedAt: Date?
    public let ruleId: String?
    public let riskLevel: RiskLevel
    public let eligibility: EligibilityStatus
    public let observedAt: Date

    public init(id: String = UUID().uuidString, scanId: String, path: String, resourceIdentifier: String?,
                category: FindingCategory, logicalSizeBytes: Int64?, allocatedSizeBytes: Int64?,
                modifiedAt: Date?, ruleId: String?, riskLevel: RiskLevel, eligibility: EligibilityStatus,
                observedAt: Date) {
        self.id = id
        self.scanId = scanId
        self.path = path
        self.resourceIdentifier = resourceIdentifier
        self.category = category
        self.logicalSizeBytes = logicalSizeBytes
        self.allocatedSizeBytes = allocatedSizeBytes
        self.modifiedAt = modifiedAt
        self.ruleId = ruleId
        self.riskLevel = riskLevel
        self.eligibility = eligibility
        self.observedAt = observedAt
    }

    public var name: String { (path as NSString).lastPathComponent }
}

// MARK: - Sessions

public struct ScanSessionRecord: Sendable, Equatable, Identifiable {
    public let id: String
    public let volumeId: String?
    public let scopeDescription: String
    public let rootPath: String?
    public let status: ScanStatus
    public let startedAt: Date
    public let completedAt: Date?
    public let filesVisited: Int
    public let directoriesVisited: Int
    public let bytesObserved: Int64
    public let allocatedBytesObserved: Int64?
    public let inaccessibleItems: Int
    public let errorCount: Int
    public let symlinksSkipped: Int
    public let excludedItems: Int
    public let mountPointsSkipped: Int
    public let failureReason: String?
}

// MARK: - Volumes

public struct VolumeObservation: Sendable, Equatable, Identifiable {
    public let id: String
    public let displayName: String
    public let mountPath: String?
    /// System-reported total capacity.
    public let totalBytes: Int64?
    /// System-reported available capacity.
    public let availableBytes: Int64?
    /// macOS "available for important usage" (may include purgeable space). Nil when unsupported.
    public let availableForImportantUsageBytes: Int64?
    public let isRemovable: Bool?
    public let isReadOnly: Bool?
    public let isInternal: Bool?
    public let formatDescription: String?
    /// Which API produced the values, e.g. "URLResourceValues" or "statvfs".
    public let source: String
    public let observedAt: Date

    public init(id: String, displayName: String, mountPath: String?, totalBytes: Int64?, availableBytes: Int64?,
                availableForImportantUsageBytes: Int64?, isRemovable: Bool?, isReadOnly: Bool?, isInternal: Bool?,
                formatDescription: String?, source: String, observedAt: Date) {
        self.id = id
        self.displayName = displayName
        self.mountPath = mountPath
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
        self.availableForImportantUsageBytes = availableForImportantUsageBytes
        self.isRemovable = isRemovable
        self.isReadOnly = isReadOnly
        self.isInternal = isInternal
        self.formatDescription = formatDescription
        self.source = source
        self.observedAt = observedAt
    }

    /// total − available, only when both are known.
    public var usedBytes: Int64? {
        guard let total = totalBytes, let available = availableBytes, total >= available else { return nil }
        return total - available
    }

    /// 0…1 used fraction, only when both values are known and total > 0.
    public var usedFraction: Double? {
        guard let used = usedBytes, let total = totalBytes, total > 0 else { return nil }
        return Double(used) / Double(total)
    }
}

public struct StorageSnapshot: Sendable, Equatable, Identifiable {
    public let id: String
    public let volumeId: String
    public let observedAt: Date
    public let totalBytes: Int64?
    public let availableBytes: Int64?
    public let scannedScopeBytes: Int64?
    public let scanId: String?
}

// MARK: - Audit

public enum AuditSeverity: String, Sendable, Codable, CaseIterable {
    case info
    case notice
    case warning
    case error
}

public struct AuditEvent: Sendable, Equatable, Identifiable {
    public let id: String
    public let operationId: String?
    public let eventType: String
    public let severity: AuditSeverity
    public let message: String
    public let detailsJSON: String?
    public let createdAt: Date

    public init(id: String = UUID().uuidString, operationId: String?, eventType: String,
                severity: AuditSeverity, message: String, details: [String: String]? = nil,
                createdAt: Date = Date()) {
        self.id = id
        self.operationId = operationId
        self.eventType = eventType
        self.severity = severity
        self.message = message
        if let details, !details.isEmpty,
           let data = try? JSONSerialization.data(withJSONObject: details, options: [.sortedKeys]) {
            self.detailsJSON = String(decoding: data, as: UTF8.self)
        } else {
            self.detailsJSON = nil
        }
        self.createdAt = createdAt
    }

    init(id: String, operationId: String?, eventType: String, severity: AuditSeverity,
         message: String, detailsJSON: String?, createdAt: Date) {
        self.id = id
        self.operationId = operationId
        self.eventType = eventType
        self.severity = severity
        self.message = message
        self.detailsJSON = detailsJSON
        self.createdAt = createdAt
    }
}
