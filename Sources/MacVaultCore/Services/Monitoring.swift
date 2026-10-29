import Foundation

/// How often MacVault runs read-only scans of your folders while it is open.
public enum ScanSchedule: String, Sendable, CaseIterable, Codable {
    case off
    case daily
    case weekly

    public var interval: TimeInterval? {
        switch self {
        case .off: return nil
        case .daily: return 86_400
        case .weekly: return 7 * 86_400
        }
    }

    public var displayName: String {
        switch self {
        case .off: return "Off"
        case .daily: return "Daily"
        case .weekly: return "Weekly"
        }
    }

    /// Due when the schedule is on and no scan of this kind has run within the interval.
    /// A last-run date in the future (clock change) counts as due so the schedule cannot stall.
    public func isDue(lastRun: Date?, now: Date) -> Bool {
        guard let interval else { return false }
        guard let lastRun else { return true }
        if lastRun > now { return true }
        return now.timeIntervalSince(lastRun) >= interval
    }
}

/// Decides when to warn about low free space. Warns once when a volume drops below the threshold,
/// then stays quiet until free space recovers above the threshold plus a margin (hysteresis).
public struct LowStorageMonitor: Sendable, Equatable {
    /// Warn when available space is below this fraction of capacity (e.g. 0.10 = 10%).
    public var thresholdFraction: Double
    /// Re-arm only after available space is above threshold + margin.
    public var recoveryMargin: Double

    public init(thresholdFraction: Double = 0.10, recoveryMargin: Double = 0.02) {
        self.thresholdFraction = min(max(thresholdFraction, 0.01), 0.5)
        self.recoveryMargin = max(0, recoveryMargin)
    }

    public enum Decision: Sendable, Equatable {
        /// Below the threshold and not yet warned.
        case warn(availableFraction: Double)
        /// Recovered; the next drop below the threshold should warn again.
        case rearm
        case none
    }

    /// - Parameter alreadyWarned: whether a warning for this volume is currently outstanding.
    public func evaluate(_ volume: VolumeObservation, alreadyWarned: Bool) -> Decision {
        guard let total = volume.totalBytes, total > 0, let available = volume.availableBytes else { return .none }
        let fraction = Double(available) / Double(total)
        if fraction < thresholdFraction {
            return alreadyWarned ? .none : .warn(availableFraction: fraction)
        }
        if alreadyWarned && fraction >= thresholdFraction + recoveryMargin { return .rearm }
        return .none
    }
}
