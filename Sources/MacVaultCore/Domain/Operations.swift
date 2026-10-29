import Foundation

// MARK: - Operation manifests
//
// Every change MacVault makes to user files goes through a manifest:
//   draft (reviewed list) → approved (explicit user action) → executing → completed / partial / failed / cancelled.
// Each item is revalidated immediately before it is moved, and every outcome is recorded.

public enum OperationType: String, Sendable, Codable, CaseIterable {
    /// Caches, logs and temporary items found by cleanup rules.
    case cleanup
    /// Developer caches and per-project build artifacts.
    case developerCleanup
    /// Moving an application bundle to the Trash.
    case appUninstall
    /// Data an application left in ~/Library. Always a separate operation from `appUninstall`.
    case appLeftovers
    /// Extra copies of files with identical content.
    case duplicateRemoval

    public var displayName: String {
        switch self {
        case .cleanup: return "Cleanup"
        case .developerCleanup: return "Developer cleanup"
        case .appUninstall: return "App removal"
        case .appLeftovers: return "App data removal"
        case .duplicateRemoval: return "Duplicate removal"
        }
    }
}

public enum ManifestStatus: String, Sendable, Codable, CaseIterable {
    case draft
    case approved
    case executing
    /// Every item was moved to the Trash.
    case completed
    /// Some items were moved; others were skipped or failed.
    case partial
    /// No item was moved because of errors.
    case failed
    /// No item was moved: every item was skipped by revalidation (changed, missing, in use…). Not an error.
    case nothingMoved
    /// The user stopped execution; remaining items were not touched.
    case cancelled
    /// The draft was discarded without approval.
    case discarded
    /// The app stopped while the manifest was executing. Set during launch reconciliation.
    case interrupted

    public var isTerminal: Bool {
        switch self {
        case .draft, .approved, .executing: return false
        default: return true
        }
    }

    public var displayName: String {
        switch self {
        case .draft: return "Awaiting approval"
        case .approved: return "Approved"
        case .executing: return "In progress"
        case .completed: return "Completed"
        case .partial: return "Partially completed"
        case .failed: return "Failed"
        case .nothingMoved: return "Nothing moved"
        case .cancelled: return "Cancelled"
        case .discarded: return "Discarded"
        case .interrupted: return "Interrupted"
        }
    }
}

public enum OperationAction: String, Sendable, Codable {
    /// The only action MacVault performs. Items can be restored from the Trash until it is emptied.
    case moveToTrash
}

public enum OperationItemStatus: String, Sendable, Codable {
    case pending
    case trashed
    /// Not moved because revalidation failed (changed, missing, protected, in use…). Not an error.
    case skipped
    case failed
}

public struct OperationItem: Sendable, Equatable, Identifiable {
    public let id: String
    public let manifestId: String
    public let originalPath: String
    public var resultingPath: String?
    /// "device:inode" observed when the item was reviewed. Revalidated before moving.
    public let resourceIdentifier: String?
    public let expectedSizeBytes: Int64?
    public let action: OperationAction
    public var status: OperationItemStatus
    public let ruleId: String?
    public let riskLevel: RiskLevel
    /// Plain-language reason the item was offered.
    public let reason: String
    /// The folder the item was found in. `SafetyPolicy` requires the item to still be strictly inside it.
    public let scopeRoot: String?
    /// Duplicates only: SHA-256 of the content that was reviewed.
    public let contentHash: String?
    /// Duplicates only: the copy that must still exist (with the same content) for this item to be moved.
    public let keeperPath: String?
    public var errorDomain: String?
    public var errorCode: Int?
    public var message: String?
    public var startedAt: Date?
    public var completedAt: Date?

    public init(id: String = UUID().uuidString, manifestId: String, originalPath: String, resultingPath: String? = nil,
                resourceIdentifier: String?, expectedSizeBytes: Int64?, action: OperationAction = .moveToTrash,
                status: OperationItemStatus = .pending, ruleId: String?, riskLevel: RiskLevel, reason: String,
                scopeRoot: String?, contentHash: String? = nil, keeperPath: String? = nil, errorDomain: String? = nil,
                errorCode: Int? = nil, message: String? = nil, startedAt: Date? = nil, completedAt: Date? = nil) {
        self.id = id
        self.manifestId = manifestId
        self.originalPath = originalPath
        self.resultingPath = resultingPath
        self.resourceIdentifier = resourceIdentifier
        self.expectedSizeBytes = expectedSizeBytes
        self.action = action
        self.status = status
        self.ruleId = ruleId
        self.riskLevel = riskLevel
        self.reason = reason
        self.scopeRoot = scopeRoot
        self.contentHash = contentHash
        self.keeperPath = keeperPath
        self.errorDomain = errorDomain
        self.errorCode = errorCode
        self.message = message
        self.startedAt = startedAt
        self.completedAt = completedAt
    }

    public var name: String { (originalPath as NSString).lastPathComponent }
}

public struct OperationManifest: Sendable, Equatable, Identifiable {
    public let id: String
    public let type: OperationType
    public var status: ManifestStatus
    public let title: String
    public let createdAt: Date
    public var approvedAt: Date?
    public var completedAt: Date?
    /// Version of the rule catalog that produced the items, when rules were involved.
    public let ruleVersion: String?
    public let estimatedBytes: Int64?
    /// Always nil today: moving to the Trash does not free space until the Trash is emptied,
    /// so MacVault does not report a measured saving.
    public var measuredBytesDelta: Int64?
    /// True: items go to the Trash and can be put back from Finder until it is emptied.
    public let recoverySupported: Bool
    public var failureReason: String?
    public var items: [OperationItem]

    public init(id: String = UUID().uuidString, type: OperationType, status: ManifestStatus = .draft, title: String,
                createdAt: Date = Date(), approvedAt: Date? = nil, completedAt: Date? = nil, ruleVersion: String?,
                estimatedBytes: Int64?, measuredBytesDelta: Int64? = nil, recoverySupported: Bool = true,
                failureReason: String? = nil, items: [OperationItem]) {
        self.id = id
        self.type = type
        self.status = status
        self.title = title
        self.createdAt = createdAt
        self.approvedAt = approvedAt
        self.completedAt = completedAt
        self.ruleVersion = ruleVersion
        self.estimatedBytes = estimatedBytes
        self.measuredBytesDelta = measuredBytesDelta
        self.recoverySupported = recoverySupported
        self.failureReason = failureReason
        self.items = items
    }

    public func count(_ status: OperationItemStatus) -> Int { items.filter { $0.status == status }.count }

    public var trashedBytes: Int64 {
        items.filter { $0.status == .trashed }.reduce(0) { $0 + ($1.expectedSizeBytes ?? 0) }
    }
}

// MARK: - Review candidates

/// Something MacVault offers for removal. Produced read-only by finders; turned into
/// `OperationItem`s only for the candidates the user selects.
public struct RemovalCandidate: Sendable, Equatable, Identifiable, Hashable {
    public var id: String { path }
    public let path: String
    public let resourceIdentifier: String?
    public let isDirectory: Bool
    /// Measured logical size; nil when it could not be measured.
    public let logicalBytes: Int64?
    /// True when part of the item could not be read; the size is then a lower bound.
    public let sizeIsLowerBound: Bool
    public let modifiedAt: Date?
    public let ruleId: String?
    public let category: String
    public let riskLevel: RiskLevel
    public let reason: String
    /// What happens after removal, e.g. "Recreated automatically on next build."
    public let consequence: String
    /// Whether the item should be pre-selected for review. Only low-risk, high-confidence items are.
    public let selectedByDefault: Bool
    /// The folder the item was found in (see `OperationItem.scopeRoot`).
    public let scopeRoot: String?

    public init(path: String, resourceIdentifier: String?, isDirectory: Bool, logicalBytes: Int64?,
                sizeIsLowerBound: Bool, modifiedAt: Date?, ruleId: String?, category: String, riskLevel: RiskLevel,
                reason: String, consequence: String, selectedByDefault: Bool, scopeRoot: String?) {
        self.path = path
        self.resourceIdentifier = resourceIdentifier
        self.isDirectory = isDirectory
        self.logicalBytes = logicalBytes
        self.sizeIsLowerBound = sizeIsLowerBound
        self.modifiedAt = modifiedAt
        self.ruleId = ruleId
        self.category = category
        self.riskLevel = riskLevel
        self.reason = reason
        self.consequence = consequence
        self.selectedByDefault = selectedByDefault
        self.scopeRoot = scopeRoot
    }

    public var name: String { (path as NSString).lastPathComponent }

    public func operationItem(manifestId: String) -> OperationItem {
        OperationItem(manifestId: manifestId, originalPath: path, resourceIdentifier: resourceIdentifier,
                      expectedSizeBytes: logicalBytes, ruleId: ruleId, riskLevel: riskLevel, reason: reason,
                      scopeRoot: scopeRoot)
    }
}

extension RiskLevel {
    public var displayName: String {
        switch self {
        case .notAssessed: return "Not assessed"
        case .low: return "Low risk"
        case .medium: return "Review carefully"
        case .high: return "High risk"
        case .protected: return "Protected"
        }
    }
}
