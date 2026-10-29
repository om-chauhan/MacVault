import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum PathUtilities {
    /// Absolute, symlink-resolved path. Falls back to a standardized path when the
    /// item does not exist (e.g. an exclusion for a folder that was removed).
    public static func canonicalize(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        if let resolved = realpath(expanded, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        var standardized = (expanded as NSString).standardizingPath
        while standardized.count > 1 && standardized.hasSuffix("/") { standardized.removeLast() }
        return standardized
    }

    /// True when `path` equals `ancestor` or is located inside it (component-aware: "/a/bc" is not inside "/a/b").
    public static func path(_ path: String, isWithin ancestor: String) -> Bool {
        if path == ancestor { return true }
        if ancestor == "/" { return path.hasPrefix("/") }
        return path.hasPrefix(ancestor + "/")
    }

    public static func join(_ directory: String, _ name: String) -> String {
        directory == "/" ? "/" + name : directory + "/" + name
    }

    /// Replaces the home directory with "~" for display and exports.
    public static func abbreviatingHome(_ path: String, home: String = NSHomeDirectory()) -> String {
        guard !home.isEmpty, home != "/" else { return path }
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}
