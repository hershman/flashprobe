import Foundation

public let flashprobeVersion = "0.6.0"

public struct DeviceSummary: Codable, Equatable, Sendable {
    public var vendorID: String
    public var productID: String
    public var bcdDevice: String
    public var serial: String
    public var manufacturer: String
    public var product: String
    public var bsdName: String
    public var size: UInt64
    public var blockSize: UInt64

    public init(target: Target, blockSize: UInt64) {
        vendorID = Fmt.hex4(target.device.vendorID)
        productID = Fmt.hex4(target.device.productID)
        bcdDevice = Fmt.hex4(target.device.bcdDevice)
        serial = target.device.serial ?? ""
        manufacturer = target.device.manufacturer ?? ""
        product = target.device.product ?? ""
        bsdName = target.disk.bsdName
        size = target.disk.size
        self.blockSize = blockSize
    }

    public init(vendorID: String, productID: String, bcdDevice: String, serial: String, manufacturer: String,
                product: String, bsdName: String, size: UInt64, blockSize: UInt64) {
        self.vendorID = vendorID; self.productID = productID; self.bcdDevice = bcdDevice
        self.serial = serial; self.manufacturer = manufacturer; self.product = product
        self.bsdName = bsdName; self.size = size; self.blockSize = blockSize
    }
}

public struct RereadSummary: Codable, Equatable, Sendable {
    public var chunks: Int
    public var readsPerChunk: Int
    public var firstReadMedianMBps: Double?
    public var rereadMedianMBps: Double?
    /// Share of re-reads that came back at or above the slow threshold. This,
    /// not "re-read vs first read", is the meaningful test: re-reading the
    /// slowest chunks always looks a bit faster by regression to the mean.
    public var fractionRereadsAboveThreshold: Double?
}

public struct ScanReport: Codable, Equatable, Sendable {
    public var tool = "flashprobe"
    public var version = flashprobeVersion
    public var createdAt: Date
    public var device: DeviceSummary
    public var plan: ScanPlan
    public var chunksPlanned: Int
    public var interrupted: Bool
    public var stoppedReason: String?
    public var elapsedSeconds: Double
    public var stats: SpeedStats
    public var slowFraction: Double
    /// p90 of chunk speeds: what the drive does on its good areas
    public var referenceMBps: Double?
    public var slowThresholdMBps: Double?
    public var histogram: [HistogramBucket]
    public var slowRegions: [SlowRegion]   // worst first, capped
    public var slowRegionCount: Int
    public var reread: RereadSummary?

    public static func build(device: DeviceSummary, plan: ScanPlan, outcome: ScanOutcome,
                             options: ScanOptions, now: Date = Date(), maxRegions: Int = 50) -> ScanReport {
        let stats = Stats.speedStats(outcome.results)
        let reference = Scanner.referenceSpeed(outcome.results)
        let threshold = reference.map { $0 * options.slowFraction }
        let regions = threshold.map { Stats.slowRegions(outcome.results, thresholdMBps: $0) } ?? []

        var reread: RereadSummary?
        let rr = outcome.results.filter { !$0.rereadSeconds.isEmpty }
        if !rr.isEmpty {
            let all = rr.flatMap(\.rereadMBps)
            reread = RereadSummary(
                chunks: rr.count,
                readsPerChunk: options.rereadCount,
                firstReadMedianMBps: Stats.percentile(rr.compactMap(\.mbps).sorted(), 50),
                rereadMedianMBps: Stats.percentile(all.sorted(), 50),
                fractionRereadsAboveThreshold: threshold.map { t in
                    Double(all.filter { $0 >= t }.count) / Double(max(1, all.count)) })
        }

        return ScanReport(
            createdAt: now, device: device, plan: plan, chunksPlanned: plan.chunks.count,
            interrupted: outcome.interrupted, stoppedReason: outcome.stoppedReason,
            elapsedSeconds: outcome.elapsed, stats: stats, slowFraction: options.slowFraction,
            referenceMBps: reference, slowThresholdMBps: threshold, histogram: Stats.histogram(outcome.results),
            slowRegions: Array(regions.prefix(maxRegions)), slowRegionCount: regions.count, reread: reread)
    }

    public func jsonData() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return try enc.encode(self)
    }
}

// MARK: - CSV

public enum CSVReport {
    public static let header = "index,offset_bytes,length_bytes,seconds,mb_per_s,error_errno,reread_mb_per_s"

    public static func render(_ results: [ChunkResult]) -> String {
        var s = header + "\n"
        s.reserveCapacity(results.count * 64)
        for r in results {
            let secs = r.seconds.map { String(format: "%.6f", $0) } ?? ""
            let mbps = r.mbps.map { String(format: "%.3f", $0) } ?? ""
            let err = r.errorCode.map(String.init) ?? ""
            let rr = r.rereadMBps.map { String(format: "%.3f", $0) }.joined(separator: ";")
            s += "\(r.index),\(r.offset),\(r.length),\(secs),\(mbps),\(err),\(rr)\n"
        }
        return s
    }
}

// MARK: - Text summary

public enum TextSummary {
    public static func render(_ r: ScanReport) -> String {
        var out: [String] = []
        let st = r.stats
        out.append("Scan of \(r.device.manufacturer) \(r.device.product) (serial \(r.device.serial), /dev/r\(r.device.bsdName))")
        let covered = r.plan.sampleEvery > 1 ? " (every \(r.plan.sampleEvery)th chunk)" : ""
        out.append("Range \(Fmt.gib(r.plan.start))–\(Fmt.gib(r.plan.end)), chunk \(r.plan.chunkSize >> 20) MiB\(covered)")
        if let why = r.stoppedReason { out.append("STOPPED EARLY: \(why). Results below are partial.") }
        out.append("Read \(st.chunksRead) chunks, \(Fmt.bytes(st.totalBytes)) in \(Fmt.duration(r.elapsedSeconds)); read errors: \(st.errors)")
        out.append("")
        out.append("Speed (MB/s):  min \(f(st.min))  p5 \(f(st.p5))  p25 \(f(st.p25))  median \(f(st.median))  p75 \(f(st.p75))  p95 \(f(st.p95))  max \(f(st.max))")
        out.append("Effective throughput \(Fmt.mbps(st.effective)); spread p95/p5 = \(st.spreadP95overP5.map { String(format: "%.1f×", $0) } ?? "n/a")")
        out.append("")
        out.append("Histogram:")
        let total = max(1, r.histogram.reduce(0) { $0 + $1.count })
        for b in r.histogram where b.count > 0 {
            let pct = Double(b.count) / Double(total) * 100
            let bar = String(repeating: "█", count: max(1, Int((pct / 100 * 40).rounded())))
            let label = b.label.padding(toLength: max(b.label.count, 8), withPad: " ", startingAt: 0)
            out.append("  " + label + String(format: " MB/s %6d  %5.1f%%  ", b.count, pct) + bar)
        }
        if let t = r.slowThresholdMBps {
            let slowBytes = r.slowRegions.isEmpty ? 0 : r.slowRegions.reduce(UInt64(0)) { $0 + ($1.endOffset - $1.startOffset) }
            out.append("")
            out.append("Slow regions (< \(Fmt.mbps(t)), i.e. \(Int(r.slowFraction * 100))% of the p90 speed \(Fmt.mbps(r.referenceMBps))): \(r.slowRegionCount)"
                       + (r.slowRegionCount <= r.slowRegions.count ? ", covering \(Fmt.bytes(slowBytes))" : ""))
            for g in r.slowRegions.prefix(10) {
                var line = "  \(Fmt.gib(g.startOffset))–\(Fmt.gib(g.endOffset))  \(g.slowChunks)/\(g.chunks) slow"
                line += "  mean \(Fmt.mbps(g.meanMBps))  min \(Fmt.mbps(g.minMBps))  \(Fmt.duration(g.totalSeconds)) spent"
                if g.errors > 0 { line += "  \(g.errors) ERRORS" }
                if let rr = g.rereadMeanMBps { line += "  re-read \(Fmt.mbps(rr))" }
                out.append(line)
            }
        }
        if let rr = r.reread {
            out.append("")
            out.append("Re-reads: \(rr.chunks) slow chunks × \(rr.readsPerChunk): first read median \(Fmt.mbps(rr.firstReadMedianMBps)), re-read median \(Fmt.mbps(rr.rereadMedianMBps))")
            if let f = rr.fractionRereadsAboveThreshold {
                let pct = Int((f * 100).rounded())
                out.append(f >= 0.5
                    ? "  \(pct)% of re-reads were no longer slow: the controller likely refreshed (rewrote) that data after the first read, or a cache served it."
                    : "  Only \(pct)% of re-reads cleared the slow threshold: the slowness is a stable property of the data stored there.")
            }
        }
        return out.joined(separator: "\n")
    }

    private static func f(_ v: Double?) -> String {
        guard let v else { return "n/a" }
        return v >= 100 ? String(format: "%.0f", v) : String(format: "%.1f", v)
    }
}
