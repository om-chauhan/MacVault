import Foundation
import XCTest
@testable import MacVaultCore

/// Read-only throughput check against a large real tree. Opt-in: MACVAULT_PERF_ROOT=/usr swift test --filter PerformanceSmoke
final class PerformanceSmokeTests: XCTestCase {
    func testThroughputOnRealTree() async throws {
        guard let root = ProcessInfo.processInfo.environment["MACVAULT_PERF_ROOT"] else {
            throw XCTSkip("Set MACVAULT_PERF_ROOT to run")
        }
        let start = Date()
        let result = try await FilesystemScanner().scan(ScanConfiguration(rootPath: root))
        let secs = Date().timeIntervalSince(start)
        print("PERF root=\(root) files=\(result.counters.filesVisited) dirs=\(result.counters.directoriesVisited) bytes=\(ByteFormat.string(result.counters.logicalBytes)) status=\(result.status.rawValue) seconds=\(String(format: "%.2f", secs)) files/sec=\(Int(Double(result.counters.filesVisited)/secs))")
    }
}
