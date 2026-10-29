import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Reads system-reported volume capacity. Every value comes from a native API and is
/// stamped with its source and observation time; values the API does not report stay nil.
public struct VolumeInfoService: Sendable {
    public init() {}

    #if os(macOS)
    private static let keys: [URLResourceKey] = [
        .volumeNameKey,
        .volumeLocalizedNameKey,
        .volumeTotalCapacityKey,
        .volumeAvailableCapacityKey,
        .volumeAvailableCapacityForImportantUsageKey,
        .volumeIsRemovableKey,
        .volumeIsReadOnlyKey,
        .volumeIsInternalKey,
        .volumeUUIDStringKey,
        .volumeURLKey,
        .volumeLocalizedFormatDescriptionKey,
    ]
    #endif

    /// Visible mounted volumes. On non-macOS platforms only the root volume is reported.
    public func mountedVolumes() -> [VolumeObservation] {
        #if os(macOS)
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: Self.keys,
            options: [.skipHiddenVolumes]
        ) ?? []
        return urls.compactMap { try? observeVolume(containing: $0.path) }
        #else
        return [(try? observeVolume(containing: "/"))].compactMap { $0 }
        #endif
    }

    /// Observes the volume that contains `path`.
    public func observeVolume(containing path: String) throws -> VolumeObservation {
        let now = Date()
        #if os(macOS)
        let url = URL(fileURLWithPath: path)
        let values = try url.resourceValues(forKeys: Set(Self.keys))
        let mountPath = values.volume?.path
        let total = values.volumeTotalCapacity.map(Int64.init)
        let available = values.volumeAvailableCapacity.map(Int64.init)
        if total != nil || available != nil {
            let name = values.volumeLocalizedName ?? values.volumeName ?? mountPath ?? path
            let id = values.volumeUUIDString ?? "mount:\(mountPath ?? path)"
            return VolumeObservation(
                id: id,
                displayName: name,
                mountPath: mountPath,
                totalBytes: total,
                availableBytes: available,
                availableForImportantUsageBytes: values.volumeAvailableCapacityForImportantUsage,
                isRemovable: values.volumeIsRemovable,
                isReadOnly: values.volumeIsReadOnly,
                isInternal: values.volumeIsInternal,
                formatDescription: values.volumeLocalizedFormatDescription,
                source: "URLResourceValues",
                observedAt: now
            )
        }
        #endif
        return try statvfsObservation(path: path, observedAt: now)
    }

    func statvfsObservation(path: String, observedAt: Date) throws -> VolumeObservation {
        var info = statvfs()
        guard statvfs(path, &info) == 0 else { throw POSIXFailure(code: errno) }
        let fragment = Int64(info.f_frsize)
        let total = Int64(info.f_blocks) * fragment
        let available = Int64(info.f_bavail) * fragment
        let readOnly = (UInt(info.f_flag) & UInt(ST_RDONLY)) != 0
        return VolumeObservation(
            id: "fsid:\(info.f_fsid)",
            displayName: path,
            mountPath: path,
            totalBytes: total,
            availableBytes: available,
            availableForImportantUsageBytes: nil,
            isRemovable: nil,
            isReadOnly: readOnly,
            isInternal: nil,
            formatDescription: nil,
            source: "statvfs",
            observedAt: observedAt
        )
    }
}
