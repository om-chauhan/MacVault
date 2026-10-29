import Foundation
import Observation

@MainActor
@Observable
final class AppSettings {
    private let defaults = UserDefaults.standard

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

    init() {
        let threshold = defaults.integer(forKey: "largeFileThresholdMB")
        largeFileThresholdMB = threshold > 0 ? threshold : 100
        exclusions = defaults.stringArray(forKey: "scanExclusions") ?? []
        crossMountPoints = defaults.bool(forKey: "crossMountPoints")
        let keep = defaults.integer(forKey: "keepScans")
        keepScans = keep > 0 ? keep : 20
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
