import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum FileKind: Sendable, Equatable {
    case directory
    case regular
    case symlink
    case other
}

/// Metadata from `lstat` — symlinks are described, never followed.
public struct FileStat: Sendable, Equatable {
    public var kind: FileKind
    public var logicalSize: Int64
    public var allocatedSize: Int64
    public var device: UInt64
    public var inode: UInt64
    public var linkCount: UInt64
    public var modifiedAt: Date?

    public init(kind: FileKind, logicalSize: Int64, allocatedSize: Int64, device: UInt64,
                inode: UInt64, linkCount: UInt64, modifiedAt: Date?) {
        self.kind = kind
        self.logicalSize = logicalSize
        self.allocatedSize = allocatedSize
        self.device = device
        self.inode = inode
        self.linkCount = linkCount
        self.modifiedAt = modifiedAt
    }

    public var resourceIdentifier: String { "\(device):\(inode)" }
}

public struct DirectoryListing: Sendable, Equatable {
    public var names: [String]
    /// Entries whose names were not valid UTF-8 and therefore could not be addressed safely.
    public var undecodableCount: Int

    public init(names: [String], undecodableCount: Int = 0) {
        self.names = names
        self.undecodableCount = undecodableCount
    }
}

/// Read-only filesystem access used by the scanner. It has no mutating operations by design:
/// the scanner cannot delete, move or write files. Tests inject fakes to simulate failures.
public struct FileSystemProbe: Sendable {
    public var stat: @Sendable (String) -> Result<FileStat, POSIXFailure>
    public var list: @Sendable (String) -> Result<DirectoryListing, POSIXFailure>

    public init(stat: @escaping @Sendable (String) -> Result<FileStat, POSIXFailure>,
                list: @escaping @Sendable (String) -> Result<DirectoryListing, POSIXFailure>) {
        self.stat = stat
        self.list = list
    }

    public static let posix = FileSystemProbe(stat: POSIXFileSystem.statEntry, list: POSIXFileSystem.listEntries)
}

enum POSIXFileSystem {
    @Sendable
    static func statEntry(_ path: String) -> Result<FileStat, POSIXFailure> {
        var st = stat()
        guard lstat(path, &st) == 0 else { return .failure(POSIXFailure(code: errno)) }

        let format = st.st_mode & mode_t(S_IFMT)
        let kind: FileKind
        if format == mode_t(S_IFDIR) {
            kind = .directory
        } else if format == mode_t(S_IFREG) {
            kind = .regular
        } else if format == mode_t(S_IFLNK) {
            kind = .symlink
        } else {
            kind = .other
        }

        #if canImport(Darwin)
        let mtime = st.st_mtimespec
        #else
        let mtime = st.st_mtim
        #endif
        let modified = Date(timeIntervalSince1970: TimeInterval(mtime.tv_sec) + TimeInterval(mtime.tv_nsec) / 1_000_000_000)

        return .success(FileStat(
            kind: kind,
            logicalSize: Int64(st.st_size),
            // POSIX st_blocks is in 512-byte units on both macOS and Linux.
            allocatedSize: Int64(st.st_blocks) * 512,
            device: UInt64(truncatingIfNeeded: st.st_dev),
            inode: UInt64(truncatingIfNeeded: st.st_ino),
            linkCount: UInt64(truncatingIfNeeded: st.st_nlink),
            modifiedAt: modified
        ))
    }

    @Sendable
    static func listEntries(_ path: String) -> Result<DirectoryListing, POSIXFailure> {
        guard let dir = opendir(path) else { return .failure(POSIXFailure(code: errno)) }
        defer { closedir(dir) }

        var names: [String] = []
        var undecodable = 0
        while true {
            errno = 0
            guard let entry = readdir(dir) else {
                if errno != 0 { return .failure(POSIXFailure(code: errno)) }
                break
            }
            let decoded: String? = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                let bytes = raw.prefix { $0 != 0 }
                // Reject names that are not valid UTF-8 instead of producing a lossy (wrong) path.
                return String(strictUTF8: bytes)
            }
            guard let name = decoded else {
                undecodable += 1
                continue
            }
            if name == "." || name == ".." { continue }
            names.append(name)
        }
        return .success(DirectoryListing(names: names, undecodableCount: undecodable))
    }
}

private extension String {
    init?<C: Collection>(strictUTF8 bytes: C) where C.Element == UInt8 {
        var iterator = bytes.makeIterator()
        var decoder = UTF8()
        var scalars = String.UnicodeScalarView()
        loop: while true {
            switch decoder.decode(&iterator) {
            case .scalarValue(let scalar): scalars.append(scalar)
            case .emptyInput: break loop
            case .error: return nil
            }
        }
        self.init(scalars)
    }
}
