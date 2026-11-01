import Foundation

public enum CleanupCategory: String, Sendable, Codable, CaseIterable {
    case caches
    case logs
    case developer
    /// Disk images and installer packages left after installing.
    case installers
    /// Data left behind by apps that are no longer installed.
    case leftovers

    public var displayName: String {
        switch self {
        case .caches: return "App caches"
        case .logs: return "Logs"
        case .developer: return "Developer caches"
        case .installers: return "Installers"
        case .leftovers: return "Leftovers of uninstalled apps"
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
    /// When set, only files with one of these (lowercase) extensions are offered; folders are skipped.
    public let includedExtensions: [String]?
    /// When true, a child is offered only if its name (without extension) is a bundle identifier of an
    /// app that is not installed. Needs an installed-app lookup; without one the rule offers nothing.
    public let onlyOrphanedOwners: Bool
    /// Pre-select candidates in review. Never true for medium or high risk.
    public let selectedByDefault: Bool

    public init(id: String, title: String, explanation: String, consequence: String, category: CleanupCategory,
                operation: OperationType, risk: RiskLevel, target: Target, minimumAgeDays: Int? = nil,
                excludedPrefixes: [String] = [], includedExtensions: [String]? = nil,
                onlyOrphanedOwners: Bool = false, selectedByDefault: Bool) {
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
        self.includedExtensions = includedExtensions?.map { $0.lowercased() }
        self.onlyOrphanedOwners = onlyOrphanedOwners
        self.selectedByDefault = selectedByDefault && risk == .low
    }

    /// "com.vendor.app": at least three dot-separated parts, no spaces, and not Apple's.
    public static func looksLikeBundleIdentifier(_ name: String) -> Bool {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts.allSatisfy({ !$0.isEmpty }) else { return false }
        guard !name.contains(where: { $0.isWhitespace }) else { return false }
        return !name.lowercased().hasPrefix("com.apple.")
    }
}

public enum RuleCatalog {
    /// Recorded on every manifest so the rule set that produced an item is always known.
    public static let version = "2026.11.1"

    /// Installers people forget in Downloads and on the Desktop.
    public static let installerExtensions = ["dmg", "pkg", "mpkg", "iso", "xip"]
    /// Leftovers are offered only when nothing in them changed for this long.
    public static let leftoverAgeDays = 30

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

    public static let mailDownloads = CleanupRule(
        id: "mail-downloads", title: "Mail attachment copies",
        explanation: "Copies Mail saved when you opened attachments from messages. The originals stay in your mailboxes.",
        consequence: "Mail saves a fresh copy the next time you open an attachment.",
        category: .caches, operation: .cleanup, risk: .low,
        target: .childrenOf("Library/Containers/com.apple.mail/Data/Library/Mail Downloads"), selectedByDefault: true)

    public static let savedState = CleanupRule(
        id: "saved-state", title: "Saved window state",
        explanation: "Window positions and Resume snapshots of apps you have not used for \(leftoverAgeDays) days.",
        consequence: "Those apps open with default windows next time. Quit them first: an app with unsaved changes relies on this state.",
        category: .caches, operation: .cleanup, risk: .medium, target: .childrenOf("Library/Saved Application State"),
        minimumAgeDays: leftoverAgeDays, excludedPrefixes: ["com.apple."], selectedByDefault: false)

    public static let installersInDownloads = CleanupRule(
        id: "installers-downloads", title: "Installers in Downloads",
        explanation: "Disk images and installer packages downloaded more than \(leftoverAgeDays) days ago. What they installed is already on your Mac.",
        consequence: "Download the installer again if you ever need to reinstall.",
        category: .installers, operation: .cleanup, risk: .medium, target: .childrenOf("Downloads"),
        minimumAgeDays: leftoverAgeDays, includedExtensions: installerExtensions, selectedByDefault: false)

    public static let installersOnDesktop = CleanupRule(
        id: "installers-desktop", title: "Installers on the Desktop",
        explanation: "Disk images and installer packages left on the Desktop for more than \(leftoverAgeDays) days.",
        consequence: "Download the installer again if you ever need to reinstall.",
        category: .installers, operation: .cleanup, risk: .medium, target: .childrenOf("Desktop"),
        minimumAgeDays: leftoverAgeDays, includedExtensions: installerExtensions, selectedByDefault: false)

    public static let orphanedApplicationSupport = CleanupRule(
        id: "orphaned-application-support", title: "Application Support of uninstalled apps",
        explanation: "Folders named after an app’s bundle identifier whose app is no longer installed anywhere on this Mac, untouched for \(leftoverAgeDays) days.",
        consequence: "If you reinstall that app it starts fresh: settings, licenses or local data it kept here are gone.",
        category: .leftovers, operation: .cleanup, risk: .medium, target: .childrenOf("Library/Application Support"),
        minimumAgeDays: leftoverAgeDays, excludedPrefixes: ["com.apple."], onlyOrphanedOwners: true, selectedByDefault: false)

    public static let orphanedContainers = CleanupRule(
        id: "orphaned-containers", title: "Containers of uninstalled apps",
        explanation: "Sandbox containers whose app is no longer installed anywhere on this Mac, untouched for \(leftoverAgeDays) days.",
        consequence: "If you reinstall that app it starts fresh: documents it kept in its container are gone.",
        category: .leftovers, operation: .cleanup, risk: .medium, target: .childrenOf("Library/Containers"),
        minimumAgeDays: leftoverAgeDays, excludedPrefixes: ["com.apple."], onlyOrphanedOwners: true, selectedByDefault: false)

    public static let orphanedPreferences = CleanupRule(
        id: "orphaned-preferences", title: "Preferences of uninstalled apps",
        explanation: "Preference files of apps that are no longer installed anywhere on this Mac, untouched for \(leftoverAgeDays) days. Files are kept while any app of the same vendor is installed, since suites share them.",
        consequence: "If you reinstall that app, its settings start from defaults.",
        category: .leftovers, operation: .cleanup, risk: .low, target: .childrenOf("Library/Preferences"),
        minimumAgeDays: leftoverAgeDays, excludedPrefixes: ["com.apple."], includedExtensions: ["plist"],
        onlyOrphanedOwners: true, selectedByDefault: false)

    public static let cargoRegistry = CleanupRule(
        id: "cargo-registry", title: "Cargo registry",
        explanation: "Crates Cargo downloaded for Rust projects, their extracted sources and the registry index.",
        consequence: "Cargo downloads crates again on the next build; offline builds fail until then.",
        category: .developer, operation: .developerCleanup, risk: .low,
        target: .childrenOf(".cargo/registry"), selectedByDefault: true)

    public static let goModuleCache = CleanupRule(
        id: "go-module-cache", title: "Go module cache",
        explanation: "Modules the Go toolchain downloaded for your projects.",
        consequence: "Go downloads modules again on the next build; offline builds fail until then.",
        category: .developer, operation: .developerCleanup, risk: .medium,
        target: .item("go/pkg/mod"), selectedByDefault: false)

    public static let pnpmStore = CleanupRule(
        id: "pnpm-store", title: "pnpm store",
        explanation: "Packages pnpm keeps once and links into every project.",
        consequence: "pnpm downloads packages again on the next install; projects keep working until then.",
        category: .developer, operation: .developerCleanup, risk: .medium,
        target: .item("Library/pnpm/store"), selectedByDefault: false)

    public static let mavenRepository = CleanupRule(
        id: "maven-repository", title: "Maven local repository",
        explanation: "Dependencies Maven downloaded for JVM projects.",
        consequence: "Maven downloads dependencies again on the next build; offline builds fail until then.",
        category: .developer, operation: .developerCleanup, risk: .medium,
        target: .item(".m2/repository"), selectedByDefault: false)

    public static let cleanerRules: [CleanupRule] = [userCaches, userLogs, mailDownloads, savedState,
                                                     installersInDownloads, installersOnDesktop,
                                                     orphanedApplicationSupport, orphanedContainers, orphanedPreferences]
    public static let developerRules: [CleanupRule] = [derivedData, simulatorCaches, npmCache, cargoRegistry, deviceSupport,
                                                       gradleCaches, pubCache, goModuleCache, pnpmStore, mavenRepository,
                                                       xcodeArchives]
    public static let all: [CleanupRule] = cleanerRules + developerRules
}
