import Foundation

/// An installed application bundle observed by `ApplicationInventory`.
public struct ApplicationRecord: Sendable, Equatable, Identifiable, Hashable {
    public var id: String { bundlePath }
    public let bundlePath: String
    public let bundleId: String?
    public let displayName: String
    public let version: String?
    /// Measured size of the bundle itself (not its data in ~/Library). Nil when it could not be measured.
    public let bundleSizeBytes: Int64?
    public let sizeIsLowerBound: Bool
    /// Apple apps and MacVault itself are listed but can never be removed.
    public let isProtected: Bool
    public let protectionReason: String?
    public let resourceIdentifier: String?
    public let observedAt: Date

    public init(bundlePath: String, bundleId: String?, displayName: String, version: String?, bundleSizeBytes: Int64?,
                sizeIsLowerBound: Bool, isProtected: Bool, protectionReason: String?, resourceIdentifier: String?,
                observedAt: Date) {
        self.bundlePath = bundlePath
        self.bundleId = bundleId
        self.displayName = displayName
        self.version = version
        self.bundleSizeBytes = bundleSizeBytes
        self.sizeIsLowerBound = sizeIsLowerBound
        self.isProtected = isProtected
        self.protectionReason = protectionReason
        self.resourceIdentifier = resourceIdentifier
        self.observedAt = observedAt
    }
}

/// How sure MacVault is that a ~/Library item belongs to an application.
public enum MatchConfidence: String, Sendable, Codable, Comparable {
    /// Named after the app's bundle identifier.
    case high
    /// Named after the app's display name; another app could use the same name.
    case medium

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs == .medium && rhs == .high }

    public var displayName: String {
        switch self {
        case .high: return "Matches bundle identifier"
        case .medium: return "Matches app name"
        }
    }
}

/// Data in ~/Library that probably belongs to an app. Never removed together with the app itself.
public struct AssociatedItem: Sendable, Equatable, Identifiable, Hashable {
    public var id: String { candidate.path }
    public let candidate: RemovalCandidate
    public let confidence: MatchConfidence
    public let kind: String

    public init(candidate: RemovalCandidate, confidence: MatchConfidence, kind: String) {
        self.candidate = candidate
        self.confidence = confidence
        self.kind = kind
    }
}
