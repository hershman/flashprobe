import Foundation

public struct SpeedStats: Codable, Equatable, Sendable {
    public var chunksRead: Int
    public var errors: Int
    public var min: Double?
    public var p1: Double?
    public var p5: Double?
    public var p25: Double?
    public var median: Double?
    public var p75: Double?
    public var p95: Double?
    public var p99: Double?
    public var max: Double?
    /// total bytes / total read time (what a full copy would see)
    public var effective: Double?
    public var totalBytes: UInt64
    public var totalReadSeconds: Double
    /// p95 / p5: how many times faster the fast end is than the slow end
    public var spreadP95overP5: Double?
}

public struct HistogramBucket: Codable, Equatable, Sendable {
    public var lower: Double
    public var upper: Double?   // nil = open-ended
    public var count: Int
    public var label: String
}

public struct SlowRegion: Codable, Equatable, Sendable {
    public var firstIndex: Int
    public var lastIndex: Int
    public var startOffset: UInt64
    public var endOffset: UInt64        // exclusive
    public var chunks: Int              // chunks read inside the region
    public var slowChunks: Int
    public var errors: Int
    public var totalSeconds: Double
    public var meanMBps: Double?        // bytes / time over the region
    public var minMBps: Double?
    public var rereadMeanMBps: Double?
}

public enum Stats {
    /// Linear-interpolated percentile of an ascending-sorted array.
    public static func percentile(_ sorted: [Double], _ p: Double) -> Double? {
        guard !sorted.isEmpty else { return nil }
        if sorted.count == 1 { return sorted[0] }
        let rank = Swift.max(0, Swift.min(100, p)) / 100 * Double(sorted.count - 1)
        let lo = Int(rank.rounded(.down))
        let hi = Swift.min(lo + 1, sorted.count - 1)
        let f = rank - Double(lo)
        return sorted[lo] + (sorted[hi] - sorted[lo]) * f
    }

    public static func speedStats(_ results: [ChunkResult]) -> SpeedStats {
        let ok = results.filter { $0.seconds != nil }
        let speeds = ok.compactMap(\.mbps).sorted()
        let bytes = ok.reduce(UInt64(0)) { $0 + UInt64($1.length) }
        let secs = ok.reduce(0.0) { $0 + ($1.seconds ?? 0) }
        let p5 = percentile(speeds, 5), p95 = percentile(speeds, 95)
        return SpeedStats(
            chunksRead: ok.count,
            errors: results.count - ok.count,
            min: speeds.first, p1: percentile(speeds, 1), p5: p5, p25: percentile(speeds, 25),
            median: percentile(speeds, 50), p75: percentile(speeds, 75), p95: p95,
            p99: percentile(speeds, 99), max: speeds.last,
            effective: secs > 0 ? Double(bytes) / 1e6 / secs : nil,
            totalBytes: bytes, totalReadSeconds: secs,
            spreadP95overP5: (p5 ?? 0) > 0 ? p95.map { $0 / p5! } : nil)
    }

    /// Roughly log-spaced MB/s edges: spans 5 MB/s stragglers to ~400 MB/s.
    public static let histogramEdges: [Double] = [0, 2, 5, 10, 20, 50, 100, 200, 400]

    public static func histogram(_ results: [ChunkResult], edges: [Double] = histogramEdges) -> [HistogramBucket] {
        var buckets: [HistogramBucket] = edges.indices.map { i in
            let lo = edges[i]
            let hi: Double? = i + 1 < edges.count ? edges[i + 1] : nil
            let label = hi.map { "\(fmtEdge(lo))–\(fmtEdge($0))" } ?? "≥\(fmtEdge(lo))"
            return HistogramBucket(lower: lo, upper: hi, count: 0, label: label)
        }
        for v in results.compactMap(\.mbps) {
            let i = (edges.lastIndex { v >= $0 }) ?? 0
            buckets[i].count += 1
        }
        return buckets
    }

    private static func fmtEdge(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(v)
    }

    /// Group slow (or failed) chunks into contiguous regions. Up to `maxGap`
    /// normal-speed chunks between slow ones are absorbed into one region.
    /// Returned sorted by total time spent, worst first.
    public static func slowRegions(_ results: [ChunkResult], thresholdMBps: Double, maxGap: Int = 2) -> [SlowRegion] {
        let ordered = results.sorted { $0.index < $1.index }
        func isSlow(_ r: ChunkResult) -> Bool { r.errorCode != nil || (r.mbps ?? .infinity) < thresholdMBps }

        var regions: [SlowRegion] = []
        var i = 0
        while i < ordered.count {
            guard isSlow(ordered[i]) else { i += 1; continue }
            var j = i       // last slow position in the run
            var k = i + 1
            var gap = 0
            while k < ordered.count {
                if isSlow(ordered[k]) { j = k; gap = 0 } else {
                    gap += 1
                    if gap > maxGap { break }
                }
                k += 1
            }
            regions.append(makeRegion(Array(ordered[i...j]), isSlow: isSlow))
            i = j + 1
        }
        return regions.sorted { $0.totalSeconds > $1.totalSeconds }
    }

    private static func makeRegion(_ rs: [ChunkResult], isSlow: (ChunkResult) -> Bool) -> SlowRegion {
        let ok = rs.filter { $0.seconds != nil }
        let bytes = ok.reduce(0) { $0 + $1.length }
        let secs = ok.reduce(0.0) { $0 + ($1.seconds ?? 0) }
        let rereadBytes = rs.reduce(0) { $0 + $1.length * $1.rereadSeconds.count }
        let rereadSecs = rs.reduce(0.0) { $0 + $1.rereadSeconds.reduce(0, +) }
        return SlowRegion(
            firstIndex: rs.first!.index, lastIndex: rs.last!.index,
            startOffset: rs.first!.offset, endOffset: rs.last!.offset + UInt64(rs.last!.length),
            chunks: rs.count, slowChunks: rs.filter(isSlow).count,
            errors: rs.filter { $0.errorCode != nil }.count,
            totalSeconds: secs,
            meanMBps: secs > 0 ? Double(bytes) / 1e6 / secs : nil,
            minMBps: ok.compactMap(\.mbps).min(),
            rereadMeanMBps: rereadSecs > 0 ? Double(rereadBytes) / 1e6 / rereadSecs : nil)
    }
}
