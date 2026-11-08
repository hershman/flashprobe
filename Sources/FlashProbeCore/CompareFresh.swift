import Foundation
import Darwin
import CryptoKit

/// `scan --compare-fresh`: the ONLY mode in flashprobe that writes, and it
/// writes only a new temporary file on the mounted volume (free space), after
/// interactive confirmation, and deletes it afterwards.
///
/// Fast fresh reads + slow old reads => the old data has aged (charge loss),
/// not that the memory is worn out.
public struct CompareFreshOptions: Sendable {
    public var freshBytes: UInt64 = 1 << 30
    public var oldBytes: UInt64 = 1 << 30
    public var minOldFileSize: UInt64 = 8 << 20
    public var oldFiles: [String] = []
    public var chunkSize: Int = 4 << 20
    public var settleSeconds: Double = 5
    public init() {}
}

public struct OldFileSample: Codable, Equatable, Sendable {
    public var path: String
    public var size: UInt64
    public var created: Date?
    public var modified: Date?
    public var seconds: Double
    public var mbps: Double?
    public var error: String?
}

public struct CompareFreshResult: Codable, Equatable, Sendable {
    public var device: DeviceSummary
    public var volume: String
    public var createdAt: Date
    public var freshBytes: UInt64
    public var freshWriteMBps: Double?
    public var freshReadChunkMBps: [Double]
    public var freshReadMedianMBps: Double?
    public var integrityOK: Bool
    public var oldFiles: [OldFileSample]
    public var oldReadChunkMBps: [Double]
    public var oldReadMedianMBps: Double?
    public var ratioOldOverFresh: Double?
    public var verdict: Verdict
    public var interrupted: Bool

    public func jsonData() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return try enc.encode(self)
    }
}

public struct Verdict: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case integrityFailure, insufficientData, likelyCached, freshAlsoSlow, agingData, mildlySlower, noDifference
    }
    public var kind: Kind
    public var text: String
}

public enum CompareFresh {
    /// Pure decision logic (unit-tested).
    public static func verdict(freshMedian: Double?, oldMedian: Double?, integrityOK: Bool) -> Verdict {
        guard integrityOK else {
            return Verdict(kind: .integrityFailure,
                text: "The test file did NOT read back identically to what was written. Treat the drive as unreliable: copy your data off it now.")
        }
        guard let f = freshMedian, let o = oldMedian else {
            return Verdict(kind: .insufficientData, text: "Not enough data to compare (no fresh or no old reads).")
        }
        if o > 1500 {
            return Verdict(kind: .likelyCached,
                text: "Old-file reads ran at \(Fmt.mbps(o)), faster than USB 3 allows: they came from the Mac's memory cache. Re-run after `sudo purge`, or pick files you haven't opened recently.")
        }
        if f < 60 {
            return Verdict(kind: .freshAlsoSlow,
                text: "Freshly written data also reads slowly (\(Fmt.mbps(f))). That points to worn memory, a controller problem or the connection, not only to aged data.")
        }
        let ratio = o / f
        if ratio < 0.5 {
            return Verdict(kind: .agingData,
                text: String(format: "Fresh data reads at %@, old data at %@ (%.0f%% of fresh). That fits charge loss in old data (retention aging) rather than worn-out memory. Rewriting the data (copy off, then back) should restore speed.", Fmt.mbps(f), Fmt.mbps(o), ratio * 100))
        }
        if ratio < 0.8 {
            return Verdict(kind: .mildlySlower,
                text: String(format: "Old data reads somewhat slower (%.0f%% of fresh speed). Mild aging, or the chosen files aren't the slow ones; try the slow regions from the full scan.", ratio * 100))
        }
        return Verdict(kind: .noDifference,
            text: String(format: "Old and fresh data read at similar speeds (%.0f%%). The files sampled are not where the slowness is; compare with the scan heatmap.", ratio * 100))
    }

    /// Pick the oldest large files by *creation* date (on exFAT that is when the
    /// file was written to this drive; modification dates survive copying).
    public static func pickOldFiles(root: URL, budget: UInt64, minSize: UInt64, exclude: Set<String> = []) -> [OldFileSample] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey]
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                     options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var cands: [OldFileSample] = []
        for case let url as URL in en {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true,
                  let size = v.fileSize, UInt64(size) >= minSize, !exclude.contains(url.path) else { continue }
            cands.append(OldFileSample(path: url.path, size: UInt64(size), created: v.creationDate,
                                       modified: v.contentModificationDate, seconds: 0, mbps: nil, error: nil))
        }
        cands.sort { ($0.created ?? .distantFuture) < ($1.created ?? .distantFuture) }
        var out: [OldFileSample] = []
        var total: UInt64 = 0
        for c in cands where total < budget {
            out.append(c); total += c.size
        }
        return out
    }

    /// Volume must be mounted from a partition of the serial-selected disk.
    public static func checkVolume(_ volume: String, target: Target, requireWritable: Bool = true) throws -> (root: String, freeBytes: UInt64) {
        var s = statfs()
        guard statfs(volume, &s) == 0 else { throw FlashProbeError.posix("statfs \(volume)", errno) }
        let from = withUnsafeBytes(of: s.f_mntfromname) { String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self)) }
        let on = withUnsafeBytes(of: s.f_mntonname) { String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self)) }
        guard DeviceLocator.partition(from, belongsTo: target.disk.bsdName) else {
            throw FlashProbeError.refused("\(volume) is mounted from \(from), which is not part of \(target.disk.bsdName) (serial \(target.device.serial ?? "?"))")
        }
        if requireWritable, (s.f_flags & UInt32(MNT_RDONLY)) != 0 {
            throw FlashProbeError.refused("\(on) is mounted read-only")
        }
        return (on, UInt64(s.f_bavail) * UInt64(s.f_bsize))
    }

    public static func defaultVolume(target: Target) throws -> String {
        let mounted = target.disk.partitions.compactMap(\.mountPoint)
        guard mounted.count == 1 else {
            throw FlashProbeError.invalidArgument(mounted.isEmpty
                ? "No mounted volume on \(target.disk.bsdName). Mount it, or pass --volume."
                : "Several volumes on \(target.disk.bsdName) (\(mounted.joined(separator: ", "))); pass --volume.")
        }
        return mounted[0]
    }

    /// Run the comparison. `confirm` gets the exact plan and must return true
    /// before anything is written.
    public static func run(target: Target, volume: String, options: CompareFreshOptions,
                           confirm: (String) -> Bool,
                           log: (String) -> Void = { fputs($0 + "\n", stderr) }) throws -> CompareFreshResult {
        let (root, free) = try checkVolume(volume, target: target)
        let margin = max(UInt64(1) << 30, free / 20)
        guard free > options.freshBytes + margin else {
            throw FlashProbeError.refused("only \(Fmt.bytes(free)) free on \(root); need \(Fmt.bytes(options.freshBytes)) plus \(Fmt.bytes(margin)) headroom. Use a smaller --fresh-mib.")
        }

        let tmp = (root as NSString).appendingPathComponent(".flashprobe-fresh-\(UUID().uuidString.prefix(8)).tmp")
        let olds: [OldFileSample]
        if options.oldFiles.isEmpty {
            olds = pickOldFiles(root: URL(fileURLWithPath: root), budget: options.oldBytes,
                                minSize: options.minOldFileSize, exclude: [tmp])
        } else {
            olds = try options.oldFiles.map { p in
                let attrs = try FileManager.default.attributesOfItem(atPath: p)
                var s = statfs()
                guard statfs(p, &s) == 0 else { throw FlashProbeError.posix("statfs \(p)", errno) }
                let from = withUnsafeBytes(of: s.f_mntfromname) { String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self)) }
                guard DeviceLocator.partition(from, belongsTo: target.disk.bsdName) else {
                    throw FlashProbeError.refused("\(p) is not on \(target.disk.bsdName)")
                }
                return OldFileSample(path: p, size: (attrs[.size] as? NSNumber)?.uint64Value ?? 0,
                                     created: attrs[.creationDate] as? Date, modified: attrs[.modificationDate] as? Date,
                                     seconds: 0, mbps: nil, error: nil)
            }
        }

        let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .none
        var plan = """
        compare-fresh will WRITE to the drive:
          volume      \(root)  (mounted from a partition of \(target.disk.bsdName), serial \(target.device.serial ?? "?"))
          new file    \(tmp)
          size        \(Fmt.bytes(options.freshBytes)) of random data (free space now \(Fmt.bytes(free)))
          afterwards  the file is read back, checked, and deleted. No existing file is modified.
        It will also READ \(olds.count) existing file(s), \(Fmt.bytes(olds.reduce(0) { $0 + $1.size })) total, oldest first:
        """
        for o in olds.prefix(8) {
            plan += "\n    \(o.created.map { df.string(from: $0) } ?? "?")  \(Fmt.bytes(o.size))  \(o.path)"
        }
        if olds.count > 8 { plan += "\n    … and \(olds.count - 8) more" }
        guard !olds.isEmpty else {
            throw FlashProbeError.invalidArgument("No existing files ≥ \(Fmt.bytes(options.minOldFileSize)) found on \(root) to compare against.")
        }
        guard confirm(plan) else { throw FlashProbeError.aborted("not confirmed; nothing was written") }

        let buf = AlignedBuffer(count: options.chunkSize)
        let interrupt = InterruptFlag.shared
        var interrupted = false

        // 1) Old files first (pure reads).
        var oldSamples: [OldFileSample] = []
        var oldChunk: [Double] = []
        for var o in olds {
            if interrupt.requested { interrupted = true; break }
            log("reading old file \(o.path)")
            let fd = open(o.path, O_RDONLY | O_CLOEXEC)
            guard fd >= 0 else { o.error = String(cString: strerror(errno)); oldSamples.append(o); continue }
            _ = fcntl(fd, F_NOCACHE, 1)
            var off: UInt64 = 0
            var total = 0.0
            while off < o.size, !interrupt.requested {
                let len = Int(min(UInt64(options.chunkSize), o.size - off))
                let t = monotonicSeconds()
                let n = preadFully(fd, buf.pointer, len, off)
                let dt = monotonicSeconds() - t
                if n <= 0 { o.error = n < 0 ? String(cString: strerror(Int32(-n))) : "unexpected EOF"; break }
                total += dt
                if n == options.chunkSize { oldChunk.append(mbPerSecond(bytes: n, seconds: dt)) }
                off += UInt64(n)
            }
            close(fd)
            o.seconds = total
            o.mbps = total > 0 ? Double(off) / 1e6 / total : nil
            oldSamples.append(o)
        }

        // 2) Write the fresh file.
        var writeMBps: Double?
        var readChunk: [Double] = []
        var integrityOK = true
        if !interrupt.requested {
            interrupt.registerCleanup(tmp)
            defer { unlink(tmp); interrupt.unregisterCleanup(tmp) }

            log("writing \(Fmt.bytes(options.freshBytes)) to \(tmp)")
            let wfd = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
            guard wfd >= 0 else { throw FlashProbeError.posix("create \(tmp)", errno) }
            _ = fcntl(wfd, F_NOCACHE, 1)
            var hasher = SHA256()
            var written: UInt64 = 0
            let tw = monotonicSeconds()
            while written < options.freshBytes, !interrupt.requested {
                let len = Int(min(UInt64(options.chunkSize), options.freshBytes - written))
                arc4random_buf(buf.pointer, len)
                hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buf.pointer, count: len))
                var done = 0
                while done < len {
                    let r = pwrite(wfd, buf.pointer + done, len - done, off_t(written) + off_t(done))
                    if r < 0 { if errno == EINTR { continue }; let e = errno; close(wfd); throw FlashProbeError.posix("write \(tmp)", e) }
                    done += r
                }
                written += UInt64(len)
            }
            if fcntl(wfd, F_FULLFSYNC) != 0 { _ = fsync(wfd) }
            writeMBps = mbPerSecond(bytes: Int(written), seconds: monotonicSeconds() - tw)
            close(wfd)
            let wroteDigest = hasher.finalize()

            if interrupt.requested {
                interrupted = true
            } else {
                if options.settleSeconds > 0 { Thread.sleep(forTimeInterval: options.settleSeconds) }
                // 3) Read it back uncached.
                log("reading back the fresh file")
                let rfd = open(tmp, O_RDONLY | O_CLOEXEC)
                guard rfd >= 0 else { throw FlashProbeError.posix("open \(tmp)", errno) }
                _ = fcntl(rfd, F_NOCACHE, 1)
                var rh = SHA256()
                var off: UInt64 = 0
                while off < written, !interrupt.requested {
                    let len = Int(min(UInt64(options.chunkSize), written - off))
                    let t = monotonicSeconds()
                    let n = preadFully(rfd, buf.pointer, len, off)
                    let dt = monotonicSeconds() - t
                    if n != len { integrityOK = false; break }
                    rh.update(bufferPointer: UnsafeRawBufferPointer(start: buf.pointer, count: n))
                    if n == options.chunkSize { readChunk.append(mbPerSecond(bytes: n, seconds: dt)) }
                    off += UInt64(n)
                }
                close(rfd)
                if interrupt.requested { interrupted = true } else if integrityOK {
                    integrityOK = rh.finalize() == wroteDigest
                }
            }
        } else {
            interrupted = true
        }

        let freshMed = Stats.percentile(readChunk.sorted(), 50)
        let oldMed = Stats.percentile(oldChunk.sorted(), 50)
        return CompareFreshResult(
            device: DeviceSummary(target: target, blockSize: target.disk.preferredBlockSize),
            volume: root, createdAt: Date(), freshBytes: options.freshBytes,
            freshWriteMBps: writeMBps, freshReadChunkMBps: readChunk, freshReadMedianMBps: freshMed,
            integrityOK: integrityOK, oldFiles: oldSamples, oldReadChunkMBps: oldChunk, oldReadMedianMBps: oldMed,
            ratioOldOverFresh: (freshMed ?? 0) > 0 ? oldMed.map { $0 / freshMed! } : nil,
            verdict: interrupted
                ? Verdict(kind: .insufficientData, text: "Interrupted before both measurements finished.")
                : verdict(freshMedian: freshMed, oldMedian: oldMed, integrityOK: integrityOK),
            interrupted: interrupted)
    }
}
