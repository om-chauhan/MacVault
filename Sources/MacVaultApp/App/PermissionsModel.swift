import Foundation
import AppKit
import Observation
import UserNotifications
import MacVaultCore

/// What MacVault may do on this Mac, as macOS currently allows it.
enum PermissionStatus: Equatable, Sendable {
    case granted
    /// macOS has not been asked yet (it will show its own dialog when MacVault asks).
    case notRequested
    /// Asked and refused, or never granted in System Settings.
    case denied
    /// Cannot apply here (for example notifications outside a bundled app).
    case unavailable(String)

    var needsAttention: Bool { self == .notRequested || self == .denied }

    var label: String {
        switch self {
        case .granted: return "Allowed"
        case .notRequested: return "Not asked yet"
        case .denied: return "Not allowed"
        case .unavailable: return "Unavailable"
        }
    }
}

enum PermissionKind: String, CaseIterable, Identifiable, Sendable {
    /// Lets scans read every folder, including macOS-protected ones (Mail, Messages, Safari, other users).
    case fullDiskAccess
    /// Desktop, Documents and Downloads: macOS asks the first time an app reads each of them.
    case protectedFolders
    /// At least one place to scan (the whole Mac or a folder).
    case scanLocations
    case notifications

    var id: String { rawValue }
}

/// One row of the permissions sheet: real status plus the action that can change it.
struct PermissionItem: Identifiable {
    let kind: PermissionKind
    let title: String
    let detail: String
    let symbol: String
    let status: PermissionStatus
    /// Title of the per-row button, or nil when nothing can be done here.
    let actionTitle: String?

    var id: String { kind.id }
}

/// Reads and requests MacVault's permissions in one place, so the user can review and grant all of them
/// at once instead of meeting system dialogs one by one in the middle of a scan.
///
/// Status is observed, never assumed: Full Disk Access and the protected folders are probed by trying
/// to list a folder (the probe for the protected folders runs only after the user agreed, because that
/// is exactly what makes macOS show its dialogs). Nothing here reads file contents.
@MainActor
@Observable
final class PermissionsModel {
    private(set) var fullDiskAccess: PermissionStatus = .notRequested
    private(set) var protectedFolders: PermissionStatus = .notRequested
    private(set) var notifications: PermissionStatus = .notRequested
    private(set) var isRequesting = false
    private(set) var lastRefreshed: Date?

    private let defaults = AppEnvironment.defaults
    private let requestedKey = "permissions.protectedFoldersRequested"
    private var observer: NSObjectProtocol?

    /// Folders macOS guards with a one-time dialog per app.
    nonisolated static let protectedFolderNames = ["Desktop", "Documents", "Downloads"]

    /// Whether the user has already let MacVault ask for the protected folders (the dialogs appear once).
    private(set) var protectedFoldersRequested: Bool {
        get { defaults.bool(forKey: requestedKey) }
        set { defaults.set(newValue, forKey: requestedKey) }
    }

    init() {
        // Coming back from System Settings: show the new state without a manual refresh.
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    // MARK: Status

    /// The Direct edition can be granted Full Disk Access; the sandboxed App Store edition reads only chosen folders.
    static var supportsFullDiskAccess: Bool {
        #if APPSTORE
        return false
        #else
        return true
        #endif
    }

    func refresh() async {
        let home = AppEnvironment.home
        let requested = protectedFoldersRequested
        async let fda = Task.detached(priority: .userInitiated) { Self.probeFullDiskAccess(home: home) }.value
        async let folders = Task.detached(priority: .userInitiated) {
            requested ? Self.probeProtectedFolders(home: home) : PermissionStatus.notRequested
        }.value
        let (fdaStatus, folderStatus) = await (fda, folders)
        fullDiskAccess = Self.supportsFullDiskAccess ? fdaStatus : .unavailable("Not used by the App Store edition")
        protectedFolders = folderStatus
        notifications = await Self.readNotificationStatus()
        lastRefreshed = Date()
    }

    func items(hasScanLocations: Bool) -> [PermissionItem] {
        var result: [PermissionItem] = []
        if Self.supportsFullDiskAccess {
            result.append(PermissionItem(
                kind: .fullDiskAccess, title: "Full Disk Access",
                detail: "Lets scans measure every folder, including ones macOS protects (Mail, Messages, Safari, other users). Granted in System Settings › Privacy & Security; MacVault cannot turn it on itself.",
                symbol: "internaldrive.fill", status: fullDiskAccess,
                actionTitle: fullDiskAccess == .denied ? "System Settings…" : nil))
        }
        result.append(PermissionItem(
            kind: .protectedFolders, title: "Desktop, Documents and Downloads",
            detail: "macOS asks once per folder before an app can read it. Allowing now avoids three separate dialogs in the middle of a scan.",
            symbol: "folder.fill", status: protectedFolders,
            actionTitle: protectedFolders == .notRequested ? "Allow" : (protectedFolders == .denied ? "System Settings…" : nil)))
        result.append(PermissionItem(
            kind: .scanLocations, title: Self.supportsFullDiskAccess ? "Whole Mac or a folder to scan" : "Folders to scan",
            detail: Self.supportsFullDiskAccess
                ? "The Storage Analyzer scans the whole startup disk or any folder you pick. Scans only read; nothing is changed."
                : "The App Store edition reads only folders you choose in the open panel. Access is remembered between launches.",
            symbol: "chart.bar.doc.horizontal", status: hasScanLocations ? .granted : .notRequested,
            actionTitle: hasScanLocations ? nil : (Self.supportsFullDiskAccess ? "Use Whole Mac" : "Choose Folder…")))
        result.append(PermissionItem(
            kind: .notifications, title: "Notifications",
            detail: "A short notice when a scheduled scan finishes or a disk runs low on space. Optional; every event is also recorded in Activity.",
            symbol: "bell.badge.fill", status: notifications,
            actionTitle: notifications == .notRequested ? "Allow" : (notifications == .denied ? "System Settings…" : nil)))
        return result
    }

    /// Access permissions that still block a complete scan (notifications are optional).
    func accessNeedsAttention(hasScanLocations: Bool) -> Bool {
        fullDiskAccess.needsAttention || protectedFolders.needsAttention || !hasScanLocations
    }

    // MARK: Requests

    /// Asks macOS for everything that can be asked, in one pass: notifications and the protected
    /// folders show system dialogs; Full Disk Access can only be granted in System Settings, which
    /// opens last so the dialogs are not hidden behind it.
    func requestAll(addScanLocation: () async -> Void) async {
        guard !isRequesting else { return }
        isRequesting = true
        defer { isRequesting = false }
        if notifications == .notRequested { await requestNotifications() }
        if protectedFolders == .notRequested { await requestProtectedFolders() }
        await addScanLocation()
        await refresh()
        if fullDiskAccess == .denied { Self.openSystemSettings(.fullDiskAccess) }
    }

    func requestNotifications() async {
        guard Notifier.isAvailable else { return }
        _ = await Notifier.requestAuthorization()
        notifications = await Self.readNotificationStatus()
    }

    /// Lists Desktop, Documents and Downloads once, which makes macOS show its dialog for each.
    func requestProtectedFolders() async {
        let home = AppEnvironment.home
        protectedFoldersRequested = true
        protectedFolders = await Task.detached(priority: .userInitiated) { Self.probeProtectedFolders(home: home) }.value
    }

    enum SettingsPane { case fullDiskAccess, filesAndFolders, notifications }

    static func openSystemSettings(_ pane: SettingsPane) {
        let url: String
        switch pane {
        case .fullDiskAccess: url = "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        case .filesAndFolders: url = "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders"
        case .notifications: url = "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        }
        if let url = URL(string: url) { NSWorkspace.shared.open(url) }
    }

    // MARK: Probes (read-only: they list a folder and nothing else)

    /// Listing a TCC-protected folder fails with EPERM unless Full Disk Access is granted.
    nonisolated static func probeFullDiskAccess(home: String) -> PermissionStatus {
        var sawProtected = false
        for name in ["Library/Safari", "Library/Mail", "Library/Messages"] {
            switch listability(of: home + "/" + name) {
            case .listable: return .granted
            case .forbidden: sawProtected = true
            case .missing: continue
            }
        }
        return sawProtected ? .denied : .unavailable("No protected folder to check")
    }

    nonisolated static func probeProtectedFolders(home: String) -> PermissionStatus {
        var checked = 0
        for name in protectedFolderNames {
            switch listability(of: home + "/" + name) {
            case .listable: checked += 1
            case .forbidden: return .denied
            case .missing: continue
            }
        }
        return checked > 0 ? .granted : .unavailable("These folders do not exist here")
    }

    private enum Listability { case listable, forbidden, missing }

    private nonisolated static func listability(of path: String) -> Listability {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return .missing }
        if let dir = opendir(path) {
            closedir(dir)
            return .listable
        }
        return (errno == EPERM || errno == EACCES) ? .forbidden : .missing
    }

    private static func readNotificationStatus() async -> PermissionStatus {
        guard Notifier.isAvailable else { return .unavailable("Needs the bundled app") }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional: return .granted
        case .notDetermined: return .notRequested
        default: return .denied
        }
    }
}
