import Foundation
import Observation
import MacVaultCore

@MainActor
@Observable
final class AppSettings {
    private let defaults = AppEnvironment.defaults

    var largeFileThresholdMB: Int {
        didSet { defaults.set(largeFileThresholdMB, forKey: "largeFileThresholdMB") }
    }
    var exclusions: [String] {
        didSet { defaults.set(exclusions, forKey: "scanExclusions") }
    }
    var crossMountPoints: Bool {
        didSet { defaults.set(crossMountPoints, forKey: "crossMountPoints") }
    }
    var keepScans: Int {
        didSet { defaults.set(keepScans, forKey: "keepScans") }
    }

    // Monitoring
    var scanSchedule: ScanSchedule {
        didSet { defaults.set(scanSchedule.rawValue, forKey: "scanSchedule") }
    }
    var lastScheduledScan: Date? {
        didSet { defaults.set(lastScheduledScan, forKey: "lastScheduledScan") }
    }
    var notifyScheduledScans: Bool {
        didSet { defaults.set(notifyScheduledScans, forKey: "notifyScheduledScans") }
    }
    var lowStorageAlerts: Bool {
        didSet { defaults.set(lowStorageAlerts, forKey: "lowStorageAlerts") }
    }
    var lowStorageThresholdPercent: Int {
        didSet { defaults.set(lowStorageThresholdPercent, forKey: "lowStorageThresholdPercent") }
    }
    /// Volumes with an outstanding low-space warning (re-armed when space recovers).
    var lowStorageWarnedVolumes: [String] {
        didSet { defaults.set(lowStorageWarnedVolumes, forKey: "lowStorageWarnedVolumes") }
    }
    var showMenuBarExtra: Bool {
        didSet { defaults.set(showMenuBarExtra, forKey: "showMenuBarExtra") }
    }
    /// The permissions sheet was shown once (first launch); afterwards it opens only on request.
    var permissionsConsentShown: Bool {
        didSet { defaults.set(permissionsConsentShown, forKey: "permissionsConsentShown") }
    }

    init() {
        let threshold = defaults.integer(forKey: "largeFileThresholdMB")
        largeFileThresholdMB = threshold > 0 ? threshold : 100
        exclusions = defaults.stringArray(forKey: "scanExclusions") ?? []
        crossMountPoints = defaults.bool(forKey: "crossMountPoints")
        let keep = defaults.integer(forKey: "keepScans")
        keepScans = keep > 0 ? keep : 20
        scanSchedule = defaults.string(forKey: "scanSchedule").flatMap(ScanSchedule.init(rawValue:)) ?? .off
        lastScheduledScan = defaults.object(forKey: "lastScheduledScan") as? Date
        notifyScheduledScans = defaults.object(forKey: "notifyScheduledScans") as? Bool ?? false
        lowStorageAlerts = defaults.object(forKey: "lowStorageAlerts") as? Bool ?? false
        let percent = defaults.integer(forKey: "lowStorageThresholdPercent")
        lowStorageThresholdPercent = (1...50).contains(percent) ? percent : 10
        lowStorageWarnedVolumes = defaults.stringArray(forKey: "lowStorageWarnedVolumes") ?? []
        showMenuBarExtra = defaults.object(forKey: "showMenuBarExtra") as? Bool ?? true
        permissionsConsentShown = defaults.bool(forKey: "permissionsConsentShown")
    }

    var largeFileThresholdBytes: Int64 { Int64(largeFileThresholdMB) * 1_000_000 }

    static var edition: String {
        #if APPSTORE
        return "App Store edition (sandboxed)"
        #else
        return "Direct edition"
        #endif
    }

    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String
        switch (short, build) {
        case let (s?, b?): return "\(s) (\(b))"
        case let (s?, nil): return s
        default: return "Development build"
        }
    }
}
