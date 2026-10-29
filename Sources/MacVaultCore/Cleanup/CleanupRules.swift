import Foundation

public enum CleanupCategory: String, Sendable, Codable, CaseIterable {
    case caches
    case logs
    case developer

    public var displayName: String {
        switch self {
        case .caches: return "App caches"
        case .logs: return "Logs"
        case .developer: return "Developer caches"
        }
    }
}

/// A versioned, declarative rule. Rules only describe *where* to look and *why*; they cannot
/// override `SafetyPolicy`, which is checked for every candidate they produce.
public struct CleanupRule: Sendable, Identifiable, Equatable {
    public enum Target: Sendable, Equatable {
        /// Each immediate child of this home-relative folder is a separate candidate.
        case childrenOf(String)
        /// This single home-relative item is the candidate.
        case item(String)
    }

    public let id: String
    public let title: String
    /// Why these items are offered.
    public let explanation: String
    /// What happens after they are removed.
    public let consequence: String
    public let category: CleanupCategory
    public let operation: OperationType
    public let risk: RiskLevel
    public let target: Target
    /// Only items with nothing modified within this many days are offered.
    public let minimumAgeDays: Int?
    /// Child names starting with any of these are never offered.
    public let excludedPrefixes: [String]
    /// Pre-select candidates in review. Never true for medium or high risk.
    public let selectedByDefault: Bool

    public init(id: String, title: String, explanation: String, consequence: String, category: CleanupCategory,
                operation: OperationType, risk: RiskLevel, target: Target, minimumAgeDays: Int? = nil,
                excludedPrefixes: [String] = [], selectedByDefault: Bool) {
        self.id = id
        self.title = title
        self.explanation = explanation
        self.consequence = consequence
        self.category = category
        self.operation = operation
        self.risk = risk
        self.target = target
        self.minimumAgeDays = minimumAgeDays
        self.excludedPrefixes = excludedPrefixes
        self.selectedByDefault = selectedByDefault && risk == .low
    }
}

public enum RuleCatalog {
    /// Recorded on every manifest so the rule set that produced an item is always known.
    public static let version = "2026.10.1"

    public static let userCaches = CleanupRule(
        id: "user-caches", title: "App caches",
        explanation: "Data apps saved to speed things up. Apps rebuild caches when they need them.",
        consequence: "Apps may start more slowly the first time. Offline content some apps keep in their cache (for example downloaded maps or music) would need to be downloaded again.",
        category: .caches, operation: .cleanup, risk: .low, target: .childrenOf("Library/Caches"),
        excludedPrefixes: ["com.apple.", "CloudKit", "com.macvault.", "FamilyCircle", "GeoServices"],
        selectedByDefault: true)

    public static let userLogs = CleanupRule(
        id: "user-logs", title: "Old app logs",
        explanation: "Diagnostic logs written by apps that have not been updated for at least 7 days.",
        consequence: "Older diagnostic history is no longer available for troubleshooting.",
        category: .logs, operation: .cleanup, risk: .low, target: .childrenOf("Library/Logs"),
        minimumAgeDays: 7, excludedPrefixes: ["com.apple."], selectedByDefault: true)

    public static let derivedData = CleanupRule(
        id: "xcode-derived-data", title: "Xcode DerivedData",
        explanation: "Build products and indexes Xcode creates for each project.",
        consequence: "Xcode rebuilds them; the next build and indexing of each project take longer.",
        category: .developer, operation: .developerCleanup, risk: .low,
        target: .childrenOf("Library/Developer/Xcode/DerivedData"), selectedByDefault: true)

    public static let xcodeArchives = CleanupRule(
        id: "xcode-archives", title: "Xcode archives",
        explanation: "Builds you archived for distribution.",
        consequence: "Archives contain the debug symbols needed to read crash reports from builds you shipped. Export what you still support first.",
        category: .developer, operation: .developerCleanup, risk: .high,
        target: .childrenOf("Library/Developer/Xcode/Archives"), selectedByDefault: false)

    public static let deviceSupport = CleanupRule(
        id: "xcode-device-support", title: "iOS device support files",
        explanation: "Symbols Xcode copied from devices you connected, one folder per OS version.",
        consequence: "Xcode copies them again the next time you connect a device with that version, which can take several minutes.",
        category: .developer, operation: .developerCleanup, risk: .medium,
        target: .childrenOf("Library/Developer/Xcode/iOS DeviceSupport"), selectedByDefault: false)

    public static let simulatorCaches = CleanupRule(
        id: "simulator-caches", title: "Simulator caches",
        explanation: "Caches the iOS Simulator creates. Your simulator devices and their apps are not included.",
        consequence: "Simulators rebuild these caches; the next launch is slower.",
        category: .developer, operation: .developerCleanup, risk: .low,
        target: .childrenOf("Library/Developer/CoreSimulator/Caches"), selectedByDefault: true)

    public static let gradleCaches = CleanupRule(
        id: "gradle-caches", title: "Gradle caches",
        explanation: "Dependencies and build caches Gradle downloaded for Android and JVM projects.",
        consequence: "Gradle downloads dependencies again on the next build; offline builds fail until then.",
        category: .developer, operation: .developerCleanup, risk: .medium,
        target: .childrenOf(".gradle/caches"), selectedByDefault: false)

    public static let npmCache = CleanupRule(
        id: "npm-cache", title: "npm cache",
        explanation: "Package downloads npm keeps to speed up installs.",
        consequence: "npm downloads packages again when they are next installed.",
        category: .developer, operation: .developerCleanup, risk: .low,
        target: .item(".npm/_cacache"), selectedByDefault: true)

    public static let pubCache = CleanupRule(
        id: "pub-cache", title: "Dart and Flutter package cache",
        explanation: "Packages downloaded by `dart pub` and `flutter pub get`.",
        consequence: "Packages are downloaded again on the next `pub get`; offline builds fail until then.",
        category: .developer, operation: .developerCleanup, risk: .medium,
        target: .childrenOf(".pub-cache/hosted"), selectedByDefault: false)

    public static let cleanerRules: [CleanupRule] = [userCaches, userLogs]
    public static let developerRules: [CleanupRule] = [derivedData, simulatorCaches, npmCache, deviceSupport,
                                                       gradleCaches, pubCache, xcodeArchives]
    public static let all: [CleanupRule] = cleanerRules + developerRules
}
