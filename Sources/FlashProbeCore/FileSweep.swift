import Foundation
import Darwin

/// `flashprobe files`: time an uncached read of every file on the drive's
/// volume, so slow regions from the raw scan can be tied to actual files and
/// their dates. Read-only: files are opened O_RDONLY and nothing is written
/// to the volume.
public struct FileSweepOptions: Sendable {
    public var chunkSize: Int = 4 << 20
    /// Files smaller than this are listed but not timed (latency dominates).
    public var minSize: UInt64 = 4 << 20
    /// Read at most this many bytes per file, as chunks spread evenly over the
    /// file. nil = read every byte.
    public var perFileBudget: UInt64? = 64 << 20
    public var includeHidden = false
    public init() {}
}

public struct FileSpeed: Codable, Equatable, Sendable {
    public var path: String
    public var relativePath: String
    public var size: UInt64
    public var created: Date?
    public var modified: Date?
    public var bytesRead: UInt64 = 0
    public var seconds: Double = 0
    public var mbps: Double?
    public var minChunkMBps: Double?
    public var chunks: Int = 0
    public var error: String?

    public init(path: String, relativePath: String, size: UInt64, created: Date?, modified: Date?) {
        self.path = path; self.relativePath = relativePath; self.size = size
        self.created = created; self.modified = modified
    }

    /// First path component under the volume root ("(root)" for top-level files).
    public var topFolder: String {
        let parts = relativePath.split(separator: "/")
        return parts.count > 1 ? String(parts[0]) : "(root)"
    }
}

public struct GroupStat: Codable, Equatable, Sendable {
    public var key: String
    public var files: Int
    public var bytes: UInt64
    public var medianMBps: Double?
    public var slowFiles: Int
    public var slowBytes: UInt64
}

public struct FileSweepSummary: Codable, Equatable, Sendable {
    public var tool = "flashprobe"
    public var version = flashprobeVersion
    public var createdAt: Date
    public var device: DeviceSummary
    public var volume: String
    public var perFileBudget: UInt64?
    public var minSize: UInt64
    public var filesFound: Int
    public var filesTimed: Int
    public var filesSkippedSmall: Int
    public var errors: Int
    public var bytesRead: UInt64
    public var elapsedSeconds: Double
    public var interrupted: Bool
    public var likelyCached: Int
    /// Median per-file speed (of files with ≥ 4 MiB read): the typical file.
    public var referenceMBps: Double?
    /// p90 per-file speed, reported for context only.
    public var p90MBps: Double?
    public var thresholdMBps: Double?
    public var slowFiles: Int
    public var slowBytes: UInt64
    public var slowCreatedFirst: Date?
    public var slowCreatedLast: Date?
    /// Normal-speed files whose creation date falls inside the slow files' range.
    public var fastFilesInsideSlowRange: Int
    /// Normal-speed files created before the oldest slow file.
    public var fastFilesOlderThanAllSlow: Int
    public var byFolder: [GroupStat]
    public var byCreatedMonth: [GroupStat]
    public var byModifiedMonth: [GroupStat]
    public var slowest: [FileSpeed]

    public func jsonData() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return try enc.encode(self)
    }
}

public enum FileSweep {
    /// Chunk-aligned offsets to read: every chunk, or `budget / chunk` chunks
    /// spread evenly from the first to the last chunk of the file.
    public static func chunkOffsets(fileSize: UInt64, chunk: Int, budget: UInt64?) -> [UInt64] {
        guard fileSize > 0, chunk > 0 else { return [] }
        let c = UInt64(chunk)
        let n = Int((fileSize + c - 1) / c)
        guard let budget, UInt64(n) * c > budget else { return (0..<n).map { UInt64($0) * c } }
        let k = max(2, Int(budget / c))
        if k >= n { return (0..<n).map { UInt64($0) * c } }
        // include the first and last chunk, spread the rest evenly
        return (0..<k).map { UInt64(Int((Double($0) * Double(n - 1) / Double(k - 1)).rounded())) * c }
    }

    public static func enumerate(root: URL, options: FileSweepOptions) -> [FileSpeed] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey]
        var opts: FileManager.DirectoryEnumerationOptions = []
        if !options.includeHidden { opts.insert(.skipsHiddenFiles) }
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: opts) else { return [] }
        let rootPath = root.standardizedFileURL.path
        var out: [FileSpeed] = []
        for case let url as URL in en {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            let p = url.standardizedFileURL.path
            var rel = p.hasPrefix(rootPath) ? String(p.dropFirst(rootPath.count)) : p
            if rel.hasPrefix("/") { rel.removeFirst() }
            out.append(FileSpeed(path: p, relativePath: rel, size: UInt64(v.fileSize ?? 0),
                                 created: v.creationDate, modified: v.contentModificationDate))
        }
        return out.sorted { $0.relativePath < $1.relativePath }
    }

    public struct Progress: Sendable {
        public let filesDone: Int, filesTotal: Int, bytesDone: UInt64, bytesTotal: UInt64, elapsed: Double
        public let current: String
    }

    /// Time reads of every file >= minSize. Returns all files (small ones untimed).
    public static func run(files: [FileSpeed], options: FileSweepOptions,
                           shouldStop: () -> Bool = { InterruptFlag.shared.requested },
                           progress: ((Progress) -> Void)? = nil) -> (files: [FileSpeed], interrupted: Bool, elapsed: Double) {
        let buf = AlignedBuffer(count: options.chunkSize)
        let plans = files.map { f in
            f.size >= options.minSize ? chunkOffsets(fileSize: f.size, chunk: options.chunkSize, budget: options.perFileBudget) : []
        }
        let bytesTotal = zip(files, plans).reduce(UInt64(0)) { acc, fp in
            acc + fp.1.reduce(UInt64(0)) { $0 + min(UInt64(options.chunkSize), fp.0.size - $1) }
        }
        let timedTotal = plans.filter { !$0.isEmpty }.count
        let t0 = monotonicSeconds()
        var out = files
        var bytesDone: UInt64 = 0
        var done = 0
        var interrupted = false

        for i in out.indices where !plans[i].isEmpty {
            if shouldStop() { interrupted = true; break }
            var f = out[i]
            progress?(Progress(filesDone: done, filesTotal: timedTotal, bytesDone: bytesDone, bytesTotal: bytesTotal,
                               elapsed: monotonicSeconds() - t0, current: f.relativePath))
            let fd = open(f.path, O_RDONLY | O_CLOEXEC)
            if fd < 0 {
                f.error = String(cString: strerror(errno))
            } else {
                _ = fcntl(fd, F_NOCACHE, 1)
                var minMBps = Double.infinity
                for off in plans[i] {
                    if shouldStop() { interrupted = true; break }
                    let len = Int(min(UInt64(options.chunkSize), f.size - off))
                    let t = monotonicSeconds()
                    let n = preadFully(fd, buf.pointer, len, off)
                    let dt = monotonicSeconds() - t
                    if n < 0 { f.error = String(cString: strerror(Int32(-n))); break }
                    if n < len { f.error = "short read (file changed?)"; break }
                    f.bytesRead += UInt64(n); f.seconds += dt; f.chunks += 1
                    bytesDone += UInt64(n)
                    if n == options.chunkSize { minMBps = min(minMBps, mbPerSecond(bytes: n, seconds: dt)) }
                }
                close(fd)
                if f.seconds > 0 { f.mbps = Double(f.bytesRead) / 1e6 / f.seconds }
                if minMBps.isFinite { f.minChunkMBps = minMBps }
            }
            out[i] = f
            done += 1
            if interrupted { break }
        }
        return (out, interrupted, monotonicSeconds() - t0)
    }

    /// Below the threshold AND the read took at least `minSeconds`. Small files
    /// always look slow in MB/s on healthy flash (per-file overhead), but a
    /// healthy read of one finishes in well under 5 ms.
    public static func isSlow(_ f: FileSpeed, threshold: Double?, minSeconds: Double = 0.005) -> Bool {
        guard let t = threshold, let v = f.mbps else { return false }
        return v < t && f.seconds >= minSeconds
    }

    static let monthFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()

    public static func summarize(files: [FileSpeed], device: DeviceSummary, volume: String,
                                 options: FileSweepOptions, interrupted: Bool, elapsed: Double,
                                 slowFraction: Double = 0.5, now: Date = Date()) -> FileSweepSummary {
        let timed = files.filter { $0.mbps != nil }
        // Reference speed from big files (true throughput); small files are latency-bound.
        let big = timed.filter { $0.bytesRead >= 4 << 20 }
        // Slow is judged against the median (the typical file), not p90: on a drive where most
        // files share one plateau speed and a few are much faster, half of p90 lands inside the
        // plateau and splits normal files in two.
        let refSpeeds = (big.isEmpty ? timed : big).compactMap(\.mbps).sorted()
        let reference = Stats.percentile(refSpeeds, 50)
        let p90 = Stats.percentile(refSpeeds, 90)
        let threshold = reference.map { $0 * slowFraction }
        func isSlow(_ f: FileSpeed) -> Bool { FileSweep.isSlow(f, threshold: threshold) }
        let slow = timed.filter(isSlow)
        let fast = timed.filter { !isSlow($0) }

        func group(_ key: (FileSpeed) -> String?) -> [GroupStat] {
            var g: [String: [FileSpeed]] = [:]
            for f in timed { g[key(f) ?? "(unknown)", default: []].append(f) }
            return g.map { k, fs in
                let s = fs.filter(isSlow)
                return GroupStat(key: k, files: fs.count, bytes: fs.reduce(0) { $0 + $1.size },
                                 medianMBps: Stats.percentile(fs.compactMap(\.mbps).sorted(), 50),
                                 slowFiles: s.count, slowBytes: s.reduce(0) { $0 + $1.size })
            }
        }

        let slowCreated = slow.compactMap(\.created).sorted()
        let first = slowCreated.first, last = slowCreated.last
        let inside = (first != nil && last != nil)
            ? fast.filter { ($0.created.map { $0 >= first! && $0 <= last! }) ?? false }.count : 0
        let older = first.map { f in fast.filter { ($0.created.map { $0 < f }) ?? false }.count } ?? 0

        return FileSweepSummary(
            createdAt: now, device: device, volume: volume, perFileBudget: options.perFileBudget, minSize: options.minSize,
            filesFound: files.count, filesTimed: timed.count,
            filesSkippedSmall: files.filter { $0.size < options.minSize }.count,
            errors: files.filter { $0.error != nil }.count,
            bytesRead: files.reduce(0) { $0 + $1.bytesRead }, elapsedSeconds: elapsed, interrupted: interrupted,
            likelyCached: timed.filter { ($0.mbps ?? 0) > 1500 }.count,
            referenceMBps: reference, p90MBps: p90, thresholdMBps: threshold,
            slowFiles: slow.count, slowBytes: slow.reduce(0) { $0 + $1.size },
            slowCreatedFirst: first, slowCreatedLast: last,
            fastFilesInsideSlowRange: inside, fastFilesOlderThanAllSlow: older,
            byFolder: group { $0.topFolder }.sorted { ($0.slowBytes, $0.bytes) > ($1.slowBytes, $1.bytes) },
            byCreatedMonth: group { $0.created.map(monthFormatter.string) }.sorted { $0.key < $1.key },
            byModifiedMonth: group { $0.modified.map(monthFormatter.string) }.sorted { $0.key < $1.key },
            slowest: Array(timed.sorted { ($0.mbps ?? 0) < ($1.mbps ?? 0) }.prefix(50)))
    }

    public static let csvHeader = "relative_path,size_bytes,created,modified,bytes_read,seconds,mb_per_s,min_chunk_mb_per_s,error"

    public static func csv(_ files: [FileSpeed]) -> String {
        let iso = ISO8601DateFormatter()
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var s = csvHeader + "\n"
        for f in files {
            s += [q(f.relativePath), String(f.size), f.created.map(iso.string) ?? "", f.modified.map(iso.string) ?? "",
                  String(f.bytesRead), f.mbps != nil ? String(format: "%.4f", f.seconds) : "",
                  f.mbps.map { String(format: "%.3f", $0) } ?? "", f.minChunkMBps.map { String(format: "%.3f", $0) } ?? "",
                  f.error.map(q) ?? ""].joined(separator: ",") + "\n"
        }
        return s
    }

    public static func text(_ s: FileSweepSummary) -> String {
        let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .none
        func d(_ x: Date?) -> String { x.map(df.string) ?? "?" }
        var o: [String] = []
        o.append("Per-file read speeds on \(s.volume) (\(s.device.manufacturer) \(s.device.product), serial \(s.device.serial))")
        o.append("\(s.filesFound) files; timed \(s.filesTimed) (≥ \(Fmt.bytes(s.minSize))), "
                 + (s.perFileBudget.map { "up to \(Fmt.bytes($0)) sampled per file" } ?? "every byte read")
                 + "; read \(Fmt.bytes(s.bytesRead)) in \(Fmt.duration(s.elapsedSeconds)); errors: \(s.errors)")
        if s.interrupted { o.append("INTERRUPTED: results are partial.") }
        if s.likelyCached > 0 { o.append("\(s.likelyCached) file(s) read faster than USB allows (served from memory cache); ignore those.") }
        guard let t = s.thresholdMBps else { return o.joined(separator: "\n") }
        o.append("")
        o.append("Slow = below \(Fmt.mbps(t)) (half the median file speed, \(Fmt.mbps(s.referenceMBps))).")
        if let m = s.referenceMBps, let p = s.p90MBps, p > 3 * m {
            o.append("Note: the fastest 10% of files read at \(Fmt.mbps(p)) or more, over 3× the median, so the typical file is slow too. `scan --compare-fresh` tells whether fresh data reads fast.")
        }
        o.append("Slow files: \(s.slowFiles), \(Fmt.bytes(s.slowBytes)).")
        if s.slowFiles > 0 {
            o.append("Slow files were created between \(d(s.slowCreatedFirst)) and \(d(s.slowCreatedLast)).")
            o.append("Normal-speed files created before the oldest slow file: \(s.fastFilesOlderThanAllSlow); created inside that date range: \(s.fastFilesInsideSlowRange).")
            o.append("(Copy tools often keep the original file dates, so 'created' may not be when the file was written to this drive.)")
        }
        o.append("")
        o.append("By top-level folder (most slow data first):")
        for g in s.byFolder.prefix(15) {
            o.append(String(format: "  %@  %4d files  %@  median %@  slow %d files / %@",
                            g.key.padding(toLength: max(28, g.key.count), withPad: " ", startingAt: 0) as NSString,
                            g.files, Fmt.bytes(g.bytes) as NSString, Fmt.mbps(g.medianMBps) as NSString,
                            g.slowFiles, Fmt.bytes(g.slowBytes) as NSString))
        }
        o.append("")
        o.append("By creation month:")
        for g in s.byCreatedMonth {
            o.append(String(format: "  %@  %4d files  %9@  median %10@  slow %d / %@", g.key as NSString, g.files,
                            Fmt.bytes(g.bytes) as NSString, Fmt.mbps(g.medianMBps) as NSString, g.slowFiles, Fmt.bytes(g.slowBytes) as NSString))
        }
        o.append("")
        o.append("Slowest files:")
        for f in s.slowest.prefix(20) {
            o.append("  \(Fmt.mbps(f.mbps).padding(toLength: 10, withPad: " ", startingAt: 0))  created \(d(f.created))  \(Fmt.bytes(f.size))  \(f.relativePath)")
        }
        return o.joined(separator: "\n")
    }
}
