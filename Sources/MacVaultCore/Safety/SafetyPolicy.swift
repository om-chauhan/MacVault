import Foundation

/// Decides whether a path may ever be offered for, or moved to, the Trash.
///
/// The policy is pure path logic (no filesystem access) so it can be tested exhaustively.
/// It is applied twice: when candidates are generated and again by `OperationExecutor`
/// immediately before each item is moved. A `denied` verdict always wins over any rule.
public struct SafetyPolicy: Sendable {
    public enum Verdict: Sendable, Equatable {
        case allowed
        case denied(String)

        public var isAllowed: Bool { self == .allowed }
    }

    /// Canonical home directory.
    public let home: String
    /// Folders that hold installed applications (canonical).
    public let applicationRoots: [String]
    /// Absolute prefixes that are never touched.
    public let systemRoots: [String]
    /// MacVault's own data directory; never touched.
    public let ownDataDirectory: String?
    /// True when a path ending in `.app` is a real application bundle. Folders named after bundle
    /// identifiers (e.g. `~/Library/Caches/com.example.app`) also end in `.app` but are not bundles.
    /// Injected so the rest of the policy stays pure and testable.
    public let isApplicationBundle: @Sendable (String) -> Bool

    /// Default bundle check: the folder contains `Contents/Info.plist`.
    public static let bundleOnDisk: @Sendable (String) -> Bool = { path in
        FileManager.default.fileExists(atPath: path + "/Contents/Info.plist")
    }

    public static let defaultSystemRoots = [
        "/System", "/bin", "/sbin", "/usr", "/etc", "/var", "/private", "/dev", "/cores",
        "/Library", "/opt", "/Network", "/Users/Shared", "/Applications/Utilities",
    ]

    /// Path components that mark credentials, version control, sync roots or the Trash itself.
    static let sensitiveComponents: Set<String> = [
        ".git", ".hg", ".svn", ".ssh", ".gnupg", ".aws", ".azure", ".kube", ".docker", ".config",
        "Keychains", ".Trash", ".Trashes",
    ]

    /// File extensions for credentials, signing assets and libraries managed by other apps.
    static let protectedExtensions: Set<String> = [
        "keychain", "keychain-db", "p12", "pfx", "cer", "crt", "pem", "key", "mobileprovision",
        "provisionprofile", "keystore", "jks", "gpg", "asc", "photoslibrary", "musiclibrary",
        "tvlibrary", "photolibrary", "aplibrary", "fcpbundle", "logicx",
    ]

    /// Bundle-like directories whose contents must not be removed piecemeal.
    static let packageExtensions: Set<String> = [
        "app", "framework", "bundle", "plugin", "kext", "appex", "xpc", "photoslibrary", "musiclibrary",
    ]

    /// Home-relative locations that are never touched, nor anything inside them.
    static let protectedHomeRelative = [
        "Library/Keychains", "Library/Mail", "Library/Messages", "Library/Safari", "Library/Accounts",
        "Library/Mobile Documents", "Library/CloudStorage", "Library/Group Containers",
        "Library/Application Support/MobileSync", "Library/Application Support/AddressBook",
        "Library/Application Support/CallHistoryDB", "Library/Calendars", "Library/Photos",
        "Library/LaunchAgents", "Library/Autosave Information", "Library/Developer/Xcode/UserData",
        "Library/MobileDevice", "Library/Cookies/Cookies.binarycookies", "Library/Preferences/com.apple.",
        ".Trash",
    ]

    /// Top-level home folders that may never themselves be removed.
    static let standardHomeFolders = [
        "Desktop", "Documents", "Downloads", "Library", "Movies", "Music", "Pictures", "Public",
        "Applications", "Sites", "Developer",
    ]

    /// ~/Library subfolders that may contain an app's leftover data.
    public static let leftoverScopes = [
        "Library/Application Support", "Library/Caches", "Library/Preferences", "Library/Containers",
        "Library/Saved Application State", "Library/Logs", "Library/HTTPStorages", "Library/WebKit",
        "Library/Cookies",
    ]

    public init(home: String = NSHomeDirectory(), applicationRoots: [String]? = nil,
                systemRoots: [String] = SafetyPolicy.defaultSystemRoots, ownDataDirectory: String? = nil,
                isApplicationBundle: @escaping @Sendable (String) -> Bool = SafetyPolicy.bundleOnDisk) {
        let canonicalHome = PathUtilities.canonicalize(home)
        self.home = canonicalHome
        self.applicationRoots = (applicationRoots ?? ["/Applications", canonicalHome + "/Applications"])
            .map(PathUtilities.canonicalize)
        self.systemRoots = systemRoots
        self.ownDataDirectory = ownDataDirectory.map(PathUtilities.canonicalize)
        self.isApplicationBundle = isApplicationBundle
    }

    // MARK: Evaluation

    /// - Parameters:
    ///   - path: canonical absolute path of the item.
    ///   - type: the operation the item belongs to.
    ///   - scopeRoot: the folder the item was found in. The item must be strictly inside it.
    ///     Required for every type except `appUninstall`.
    public func evaluate(_ path: String, for type: OperationType, scopeRoot: String?) -> Verdict {
        if let structural = structuralProblem(path) { return .denied(structural) }

        let components = path.split(separator: "/").map(String.init)
        let name = components.last ?? ""
        let ext = (name as NSString).pathExtension.lowercased()

        if isWithinSystemRoot(path) {
            return .denied("System location")
        }
        if PathUtilities.path(home, isWithin: path) {
            return .denied("Home folder or one of its parents")
        }
        if PathUtilities.path(path, isWithin: "/Users") && !PathUtilities.path(path, isWithin: home) {
            return .denied("Another user’s folder")
        }
        if path == "/Volumes" || (path.hasPrefix("/Volumes/") && components.count == 2) {
            return .denied("Root of a volume")
        }
        for folder in Self.standardHomeFolders where path == home + "/" + folder {
            return .denied("Standard folder in your home")
        }
        if path.hasPrefix(home + "/Library/"), !path.dropFirst(home.count + "/Library/".count).contains("/") {
            return .denied("Top-level Library folder")
        }
        for relative in Self.protectedHomeRelative {
            let protected = home + "/" + relative
            if relative.hasSuffix(".") ? path.hasPrefix(protected) : PathUtilities.path(path, isWithin: protected) {
                return .denied("Protected personal data or system configuration")
            }
        }
        if let component = components.first(where: Self.sensitiveComponents.contains) {
            return .denied("Inside \(component), which may hold credentials, history or sync data")
        }
        if Self.protectedExtensions.contains(ext) {
            return .denied("Credential, signing asset or managed library")
        }
        if let own = ownDataDirectory, PathUtilities.path(path, isWithin: own) || PathUtilities.path(own, isWithin: path) {
            return .denied("MacVault’s own data")
        }
        for root in applicationRoots where path == root {
            return .denied("Applications folder")
        }
        // Nothing inside an app, framework or library package is removed piecemeal.
        var prefix = ""
        for component in components.dropLast() {
            prefix += "/" + component
            let componentExt = (component as NSString).pathExtension.lowercased()
            guard Self.packageExtensions.contains(componentExt) else { continue }
            if componentExt != "app" || isApplicationBundle(prefix) {
                return .denied("Inside the package \(component)")
            }
        }

        switch type {
        case .appUninstall:
            return evaluateAppBundle(path, ext: ext)
        case .cleanup, .developerCleanup, .appLeftovers, .duplicateRemoval:
            if applicationRoots.contains(where: { PathUtilities.path(path, isWithin: $0) }) {
                return .denied("Applications are removed only with App removal")
            }
            if ext == "app" && isApplicationBundle(path) {
                return .denied("Applications are removed only with App removal")
            }
            return evaluateScoped(path, type: type, scopeRoot: scopeRoot)
        }
    }

    private func structuralProblem(_ path: String) -> String? {
        if path.isEmpty || !path.hasPrefix("/") { return "Not an absolute path" }
        if path == "/" { return "Root of the disk" }
        if path.contains("\0") { return "Invalid path" }
        if path.hasSuffix("/") { return "Not a canonical path" }
        let components = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        if components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) { return "Not a canonical path" }
        return nil
    }

    private func isWithinSystemRoot(_ path: String) -> Bool {
        systemRoots.contains { PathUtilities.path(path, isWithin: $0) }
    }

    private func evaluateAppBundle(_ path: String, ext: String) -> Verdict {
        guard ext == "app" else { return .denied("Not an application bundle") }
        let parent = (path as NSString).deletingLastPathComponent
        let grandparent = (parent as NSString).deletingLastPathComponent
        let inRoot = applicationRoots.contains(parent)
        let inSubfolder = applicationRoots.contains(grandparent) && (parent as NSString).lastPathComponent != "Utilities"
        guard inRoot || inSubfolder else { return .denied("Not in an Applications folder") }
        return .allowed
    }

    private func evaluateScoped(_ path: String, type: OperationType, scopeRoot: String?) -> Verdict {
        guard let scopeRoot, structuralProblem(scopeRoot) == nil else {
            return .denied("No review scope recorded for this item")
        }
        guard path != scopeRoot, PathUtilities.path(path, isWithin: scopeRoot) else {
            return .denied("Outside the reviewed folder")
        }
        switch type {
        case .cleanup, .developerCleanup:
            guard PathUtilities.path(scopeRoot, isWithin: home) || type == .developerCleanup else {
                return .denied("Cleanup rules only apply inside your home folder")
            }
        case .appLeftovers:
            let allowed = Self.leftoverScopes.map { home + "/" + $0 }
            guard allowed.contains(scopeRoot) else { return .denied("Not an app-data location") }
        case .duplicateRemoval:
            if PathUtilities.path(path, isWithin: home + "/Library") {
                return .denied("App data in Library is never deduplicated")
            }
        case .appUninstall:
            break
        }
        return .allowed
    }
}
