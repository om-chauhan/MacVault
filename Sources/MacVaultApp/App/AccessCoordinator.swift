import Foundation
import AppKit
import Observation
import MacVaultCore

/// A folder the user explicitly chose. Stored as a bookmark so access survives relaunch
/// (security-scoped in the sandboxed App Store edition).
struct AuthorizedLocation: Identifiable, Codable, Hashable {
    let id: UUID
    var path: String
    var bookmark: Data
    var isSecurityScoped: Bool
    let addedAt: Date

    /// True for the startup disk as a whole (root path "/").
    var isWholeVolume: Bool { path == ScanConfiguration.wholeVolumeRoot }

    var displayName: String {
        if isWholeVolume { return Self.startupDiskName }
        let last = (path as NSString).lastPathComponent
        return last.isEmpty ? path : last
    }
    var displayPath: String { isWholeVolume ? "\(Self.startupDiskName) — whole Mac" : PathUtilities.abbreviatingHome(path) }

    /// The Finder name of the startup disk, e.g. "Macintosh HD".
    static var startupDiskName: String {
        let name = FileManager.default.displayName(atPath: ScanConfiguration.wholeVolumeRoot)
        return name.isEmpty ? "Startup Disk" : name
    }
}

enum LocationStatus: Error, Equatable {
    case available
    /// The bookmark resolved but is stale and could not be refreshed — the user must choose the folder again.
    case needsReselection
    case unavailable(String)

    var label: String {
        switch self {
        case .available: return "Accessible"
        case .needsReselection: return "Choose again"
        case .unavailable: return "Unavailable"
        }
    }
}

/// Holds security-scoped access open for the duration of a scan.
final class ScopedAccess: @unchecked Sendable {
    let url: URL
    private var active: Bool
    private let lock = NSLock()

    init(url: URL, active: Bool) {
        self.url = url
        self.active = active
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        if active { url.stopAccessingSecurityScopedResource(); active = false }
    }

    deinit { stop() }
}

@MainActor
@Observable
final class AccessCoordinator {
    private(set) var locations: [AuthorizedLocation] = []
    private let defaultsKey = "authorizedLocations.v1"

    init() {
        if let data = AppEnvironment.defaults.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode([AuthorizedLocation].self, from: data) {
            locations = decoded
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(locations) {
            AppEnvironment.defaults.set(data, forKey: defaultsKey)
        }
    }

    /// Presents an open panel; returns the new or existing location for the chosen folder.
    func chooseFolder(message: String) -> AuthorizedLocation? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Choose"
        panel.message = message
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return add(url)
    }

    /// Why a typed path could not be added, with a message the user can act on.
    struct PathError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Adds a folder from a typed path ("~" is expanded).
    func addPath(_ rawPath: String) -> Result<AuthorizedLocation, PathError> {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(PathError(message: "Enter a folder path.")) }
        let path = PathUtilities.canonicalize(trimmed)
        let shown = PathUtilities.abbreviatingHome(path)
        guard path.hasPrefix("/") else {
            return .failure(PathError(message: "Enter an absolute path, such as /Users/Shared or ~/Downloads."))
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return .failure(PathError(message: "No folder exists at \(shown)."))
        }
        guard isDirectory.boolValue else {
            return .failure(PathError(message: "\(shown) is a file. Enter the folder that contains it."))
        }
        guard FileManager.default.isReadableFile(atPath: path) else {
            return .failure(PathError(message: "MacVault is not allowed to read \(shown). Use Choose Folder… so macOS can grant access."))
        }
        guard let location = add(URL(fileURLWithPath: path, isDirectory: true)) else {
            return .failure(PathError(message: "Access to \(shown) could not be saved. Use Choose Folder… so macOS can grant access."))
        }
        return .success(location)
    }

    @discardableResult
    func add(_ url: URL) -> AuthorizedLocation? {
        let path = PathUtilities.canonicalize(url.path)
        let made = Self.makeBookmark(url)
        guard let (bookmark, scoped) = made else { return nil }
        if let index = locations.firstIndex(where: { $0.path == path }) {
            locations[index].bookmark = bookmark
            locations[index].isSecurityScoped = scoped
            persist()
            return locations[index]
        }
        let location = AuthorizedLocation(id: UUID(), path: path, bookmark: bookmark, isSecurityScoped: scoped, addedAt: Date())
        locations.append(location)
        persist()
        return location
    }

    func remove(_ location: AuthorizedLocation) {
        locations.removeAll { $0.id == location.id }
        persist()
    }

    /// Read-only check, safe to call while rendering views (never mutates stored bookmarks).
    func status(of location: AuthorizedLocation) -> LocationStatus {
        switch resolve(location, refreshIfStale: false) {
        case .success(let url):
            return FileManager.default.fileExists(atPath: url.path) ? .available : .unavailable("Folder not found")
        case .failure(let failure):
            return failure
        }
    }

    /// Starts access for a scan. The caller must call `stop()` when done.
    func beginAccess(_ location: AuthorizedLocation) -> Result<ScopedAccess, LocationStatus> {
        switch resolve(location, refreshIfStale: true) {
        case .failure(let status):
            return .failure(status)
        case .success(let url):
            let started = location.isSecurityScoped ? url.startAccessingSecurityScopedResource() : false
            #if APPSTORE
            if location.isSecurityScoped && !started { return .failure(.needsReselection) }
            #endif
            return .success(ScopedAccess(url: url, active: started))
        }
    }

    private func resolve(_ location: AuthorizedLocation, refreshIfStale: Bool) -> Result<URL, LocationStatus> {
        var stale = false
        let options: URL.BookmarkResolutionOptions = location.isSecurityScoped ? [.withSecurityScope, .withoutUI] : [.withoutUI]
        do {
            let url = try URL(resolvingBookmarkData: location.bookmark, options: options, relativeTo: nil, bookmarkDataIsStale: &stale)
            if stale && refreshIfStale {
                // Try to refresh the bookmark while we still have access; otherwise ask the user.
                let accessing = location.isSecurityScoped ? url.startAccessingSecurityScopedResource() : false
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                guard let (fresh, scoped) = Self.makeBookmark(url),
                      let index = locations.firstIndex(where: { $0.id == location.id }) else {
                    return .failure(.needsReselection)
                }
                locations[index].bookmark = fresh
                locations[index].isSecurityScoped = scoped
                locations[index].path = PathUtilities.canonicalize(url.path)
                persist()
            }
            return .success(url)
        } catch {
            return .failure(.unavailable(error.localizedDescription))
        }
    }

    private static func makeBookmark(_ url: URL) -> (Data, Bool)? {
        if let scoped = try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                              includingResourceValuesForKeys: nil, relativeTo: nil) {
            return (scoped, true)
        }
        #if APPSTORE
        return nil
        #else
        // Direct edition (not sandboxed): a plain bookmark is sufficient.
        guard let plain = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) else { return nil }
        return (plain, false)
        #endif
    }
}
