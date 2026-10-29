import Foundation

/// Read-only recursive scanner.
///
/// - Iterative depth-first traversal with an explicit stack (no task-per-file).
/// - Uses `lstat`: symlinks are counted and never followed.
/// - Does not enter directories on another device unless `crossMountPoints` is set.
/// - Hard-linked files are sized once per (device, inode).
/// - Large-file findings are bounded by `maxLargeFileFindings`.
/// - Cooperative cancellation: a cancelled scan returns a `.cancelled` result with
///   everything observed so far rather than throwing, so partial data can be recorded honestly.
/// - Progress callbacks are throttled and awaited, which applies backpressure.
///
/// A recursive scan is a series of observations over time, not an atomic snapshot of the disk.
public struct FilesystemScanner: Sendable {
    public let probe: FileSystemProbe

    public init(probe: FileSystemProbe = .posix) {
        self.probe = probe
    }

    public func scan(
        _ config: ScanConfiguration,
        progress: @Sendable (ScanProgress) async -> Void = { _ in }
    ) async throws -> ScanResult {
        let startedAt = Date()
        let clock = ContinuousClock()
        let start = clock.now
        let root = config.rootPath

        let rootStat: FileStat
        switch probe.stat(root) {
        case .failure(let failure):
            throw ScanError.rootUnavailable(path: root, code: failure.code)
        case .success(let st):
            rootStat = st
        }
        guard rootStat.kind == .directory else { throw ScanError.rootNotDirectory(path: root) }

        var counters = ScanCounters()
        var topLevel: [DirectoryAggregate] = []
        var tree: [TreeNode] = []
        // Hard cap on nodes tracked in memory; deeper directories then roll into their nearest tracked ancestor.
        let treeTrackingCap = max(config.maxTreeNodes * 25, 10_000)
        var largeFiles: [LargeFileRecord] = []
        var issues: [ScanIssue] = []
        var issueCount = 0
        var seenHardLinks = Set<String>()
        var cancelled = false
        var lastEmit = start
        var sinceCheck = 0
        let interval = Duration.milliseconds(Int64(config.progressInterval * 1000))

        func record(_ issue: ScanIssue) {
            issueCount += 1
            if issues.count < config.maxRecordedIssues { issues.append(issue) }
        }

        func trimLargeFiles() {
            largeFiles.sort { $0.logicalSizeBytes > $1.logicalSizeBytes }
            if largeFiles.count > config.maxLargeFileFindings {
                largeFiles.removeLast(largeFiles.count - config.maxLargeFileFindings)
            }
        }

        func snapshot(_ dir: String) -> ScanProgress {
            ScanProgress(
                filesVisited: counters.filesVisited,
                directoriesVisited: counters.directoriesVisited,
                logicalBytes: counters.logicalBytes,
                inaccessibleItems: counters.inaccessibleItems,
                currentDirectory: dir,
                elapsedSeconds: Self.seconds(clock.now - start)
            )
        }

        // Stack entries: directory path, index into topLevel (nil for the root itself), depth below the root,
        // and indices of the tree nodes that this directory's contents roll up into.
        var stack: [(path: String, top: Int?, depth: Int, chain: [Int])] = [(root, nil, 0, [])]

        traversal: while let (dir, topIndex, depth, chain) = stack.popLast() {
            if Task.isCancelled { cancelled = true; break }

            let listing: DirectoryListing
            switch probe.list(dir) {
            case .failure(let failure):
                counters.inaccessibleItems += 1
                if let topIndex { topLevel[topIndex].inaccessibleItems += 1 }
                for node in chain { tree[node].inaccessibleItems += 1 }
                record(ScanIssue(path: dir, kind: .unreadableDirectory, errorCode: failure.code))
                continue traversal
            case .success(let value):
                listing = value
            }

            counters.directoriesVisited += 1
            if listing.undecodableCount > 0 {
                counters.otherErrors += listing.undecodableCount
                if let topIndex { topLevel[topIndex].inaccessibleItems += listing.undecodableCount }
                for node in chain { tree[node].inaccessibleItems += listing.undecodableCount }
                record(ScanIssue(path: dir, kind: .undecodableName, errorCode: nil))
            }

            for name in listing.names {
                let path = PathUtilities.join(dir, name)

                if config.isExcluded(path) {
                    counters.excludedItems += 1
                    continue
                }

                let st: FileStat
                switch probe.stat(path) {
                case .failure(let failure):
                    counters.inaccessibleItems += 1
                    if let topIndex { topLevel[topIndex].inaccessibleItems += 1 }
                    for node in chain { tree[node].inaccessibleItems += 1 }
                    record(ScanIssue(path: path, kind: .metadataUnavailable, errorCode: failure.code))
                    continue
                case .success(let value):
                    st = value
                }

                var index = topIndex
                if index == nil {
                    topLevel.append(DirectoryAggregate(name: name, path: path, isDirectory: st.kind == .directory))
                    index = topLevel.count - 1
                }
                let top = index!

                switch st.kind {
                case .symlink:
                    counters.symlinksSkipped += 1

                case .directory:
                    if st.device != rootStat.device && !config.crossMountPoints {
                        counters.mountPointsSkipped += 1
                        record(ScanIssue(path: path, kind: .mountPointSkipped, errorCode: nil))
                    } else {
                        var childChain = chain
                        if depth + 1 <= config.maxTreeDepth && tree.count < treeTrackingCap {
                            tree.append(TreeNode(path: path, parentPath: depth == 0 ? nil : dir, name: name, depth: depth + 1))
                            childChain.append(tree.count - 1)
                        }
                        stack.append((path, top, depth + 1, childChain))
                    }

                case .regular:
                    counters.filesVisited += 1
                    topLevel[top].fileCount += 1
                    for node in chain { tree[node].fileCount += 1 }
                    if st.linkCount > 1 && !seenHardLinks.insert(st.resourceIdentifier).inserted {
                        counters.hardLinkRepeats += 1
                        break
                    }
                    counters.logicalBytes += st.logicalSize
                    counters.allocatedBytes += st.allocatedSize
                    topLevel[top].logicalBytes += st.logicalSize
                    topLevel[top].allocatedBytes += st.allocatedSize
                    for node in chain {
                        tree[node].logicalBytes += st.logicalSize
                        tree[node].allocatedBytes += st.allocatedSize
                    }

                    if st.logicalSize >= config.largeFileThresholdBytes {
                        largeFiles.append(LargeFileRecord(
                            path: path,
                            logicalSizeBytes: st.logicalSize,
                            allocatedSizeBytes: st.allocatedSize,
                            modifiedAt: st.modifiedAt,
                            resourceIdentifier: st.resourceIdentifier
                        ))
                        if largeFiles.count >= config.maxLargeFileFindings * 2 { trimLargeFiles() }
                    }

                case .other:
                    counters.specialItems += 1
                }

                sinceCheck += 1
                if sinceCheck >= 256 {
                    sinceCheck = 0
                    if Task.isCancelled { cancelled = true; break traversal }
                    let now = clock.now
                    if now - lastEmit >= interval {
                        lastEmit = now
                        await progress(snapshot(dir))
                        if Task.isCancelled { cancelled = true; break traversal }
                    }
                }
            }

            // Also emit at directory boundaries so sparse trees still report progress.
            let now = clock.now
            if now - lastEmit >= interval {
                lastEmit = now
                await progress(snapshot(dir))
                if Task.isCancelled { cancelled = true; break traversal }
            }
        }

        trimLargeFiles()
        topLevel.sort { $0.logicalBytes > $1.logicalBytes }
        let keptTree = Self.pruneTree(tree, limit: config.maxTreeNodes)

        let status: ScanStatus
        if cancelled {
            status = .cancelled
        } else if counters.inaccessibleItems > 0 || counters.otherErrors > 0 {
            status = .partial
        } else {
            status = .completed
        }

        await progress(snapshot(root))
        Log.scanner.info("Scan finished: \(status.rawValue) files=\(counters.filesVisited) inaccessible=\(counters.inaccessibleItems)")

        return ScanResult(
            rootPath: root,
            status: status,
            counters: counters,
            largeFiles: largeFiles,
            topLevel: topLevel,
            tree: keptTree,
            issues: issues,
            issueCount: issueCount,
            startedAt: startedAt,
            finishedAt: Date()
        )
    }

    /// Keeps the `limit` largest nodes. A directory's rolled-up size is never smaller than any of its
    /// descendants', so ordering by (size desc, depth asc) places every ancestor before its descendants
    /// and the kept set is always closed under "parent of".
    static func pruneTree(_ nodes: [TreeNode], limit: Int) -> [TreeNode] {
        let sorted = nodes.sorted {
            if $0.logicalBytes != $1.logicalBytes { return $0.logicalBytes > $1.logicalBytes }
            if $0.depth != $1.depth { return $0.depth < $1.depth }
            return $0.path < $1.path
        }
        return Array(sorted.prefix(limit))
    }

    static func seconds(_ duration: Duration) -> Double {
        let c = duration.components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }
}
