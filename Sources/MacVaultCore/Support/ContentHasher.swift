import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Read-only SHA-256 of file contents. Files are opened `O_RDONLY | O_NOFOLLOW`, so a symlink
/// is never hashed in place of the file it replaced.
public struct ContentHasher: Sendable {
    public var chunkSize: Int

    public init(chunkSize: Int = 1 << 20) {
        self.chunkSize = max(4096, chunkSize)
    }

    /// Hex SHA-256 of the whole file. Checks for task cancellation between chunks.
    public func sha256(path: String) throws -> String {
        try hash(path: path, limit: nil)
    }

    /// Hex SHA-256 of at most the first `bytes` bytes — a cheap pre-filter before a full hash.
    public func prefixSHA256(path: String, bytes: Int) throws -> String {
        try hash(path: path, limit: max(0, bytes))
    }

    private func hash(path: String, limit: Int?) throws -> String {
        let fd = open(path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw POSIXFailure(code: errno) }
        defer { close(fd) }

        var hasher = SHA256Hasher()
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        var remaining = limit ?? Int.max
        while remaining > 0 {
            if Task.isCancelled { throw CancellationError() }
            let want = min(buffer.count, remaining)
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, want) }
            if n < 0 {
                if errno == EINTR { continue }
                throw POSIXFailure(code: errno)
            }
            if n == 0 { break }
            buffer.withUnsafeBytes { hasher.update(UnsafeRawBufferPointer(rebasing: $0[0..<n])) }
            remaining -= n
        }
        return hasher.finalizeHex()
    }
}

/// SHA-256 using CryptoKit where available, otherwise a portable implementation.
struct SHA256Hasher {
    #if canImport(CryptoKit)
    private var inner = CryptoKit.SHA256()
    mutating func update(_ bytes: UnsafeRawBufferPointer) { inner.update(bufferPointer: bytes) }
    mutating func finalizeHex() -> String { inner.finalize().map { String(format: "%02x", $0) }.joined() }
    #else
    private var inner = PortableSHA256()
    mutating func update(_ bytes: UnsafeRawBufferPointer) { inner.update(bytes) }
    mutating func finalizeHex() -> String { inner.finalize().map { String(format: "%02x", $0) }.joined() }
    #endif
}

/// FIPS 180-4 SHA-256. Used on platforms without CryptoKit; tested against known vectors everywhere.
struct PortableSHA256 {
    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    private var state: [UInt32] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    ]
    private var pending: [UInt8] = []
    private var length: UInt64 = 0

    mutating func update(_ bytes: UnsafeRawBufferPointer) {
        length &+= UInt64(bytes.count)
        pending.append(contentsOf: bytes)
        var offset = 0
        while pending.count - offset >= 64 {
            compress(pending[offset..<offset + 64])
            offset += 64
        }
        pending.removeFirst(offset)
    }

    mutating func update(_ bytes: [UInt8]) {
        bytes.withUnsafeBytes { update($0) }
    }

    mutating func finalize() -> [UInt8] {
        let bitLength = length &* 8
        var tail = pending
        tail.append(0x80)
        while tail.count % 64 != 56 { tail.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) { tail.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(shift))) }
        for start in stride(from: 0, to: tail.count, by: 64) { compress(tail[start..<start + 64]) }
        pending = []
        return state.flatMap { word in (0..<4).map { UInt8(truncatingIfNeeded: word >> UInt32(24 - $0 * 8)) } }
    }

    private mutating func compress(_ block: ArraySlice<UInt8>) {
        var w = [UInt32](repeating: 0, count: 64)
        let base = block.startIndex
        for i in 0..<16 {
            w[i] = UInt32(block[base + i * 4]) << 24 | UInt32(block[base + i * 4 + 1]) << 16
                | UInt32(block[base + i * 4 + 2]) << 8 | UInt32(block[base + i * 4 + 3])
        }
        for i in 16..<64 {
            let s0 = w[i - 15].rotr(7) ^ w[i - 15].rotr(18) ^ (w[i - 15] >> 3)
            let s1 = w[i - 2].rotr(17) ^ w[i - 2].rotr(19) ^ (w[i - 2] >> 10)
            w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
        }
        var (a, b, c, d, e, f, g, h) = (state[0], state[1], state[2], state[3], state[4], state[5], state[6], state[7])
        for i in 0..<64 {
            let s1 = e.rotr(6) ^ e.rotr(11) ^ e.rotr(25)
            let ch = (e & f) ^ (~e & g)
            let t1 = h &+ s1 &+ ch &+ Self.k[i] &+ w[i]
            let s0 = a.rotr(2) ^ a.rotr(13) ^ a.rotr(22)
            let maj = (a & b) ^ (a & c) ^ (b & c)
            let t2 = s0 &+ maj
            (h, g, f, e, d, c, b, a) = (g, f, e, d &+ t1, c, b, a, t1 &+ t2)
        }
        state[0] &+= a; state[1] &+= b; state[2] &+= c; state[3] &+= d
        state[4] &+= e; state[5] &+= f; state[6] &+= g; state[7] &+= h
    }
}

private extension UInt32 {
    func rotr(_ n: UInt32) -> UInt32 { (self >> n) | (self << (32 - n)) }
}
