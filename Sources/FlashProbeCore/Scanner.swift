import Foundation
import Darwin

// MARK: - Plan

public struct ChunkSpec: Equatable, Sendable {
    /// Absolute chunk number (offset / chunkSize), so maps line up across runs.
    public let index: Int
    public let offset: UInt64
    public let length: Int
}

public struct ScanPlan: Codable, Equatable, Sendable {
    public let deviceSize: UInt64
    public let blockSize: UInt64
    public let chunkSize: UInt64
    public let start: UInt64
    public let end: UInt64
    public let sampleEvery: Int

    /// - start is rounded down to a chunk boundary; the final chunk is
    ///   shortened to end exactly at `end` (always a block multiple).
    public init(deviceSize: UInt64, blockSize: UInt64, chunkSize: UInt64,
                start: UInt64 = 0, length: UInt64? = nil, sampleEvery: Int = 1) throws {
        guard blockSize > 0, blockSize.nonzeroBitCount == 1 else {
            throw FlashProbeError.invalidArgument("block size \(blockSize) is not a power of two")
        }
        guard chunkSize >= blockSize, chunkSize % blockSize == 0 else {
            throw FlashProbeError.invalidArgument("chunk size must be a multiple of the \(blockSize)-byte block size")
        }
        guard chunkSize <= 256 << 20 else {
            throw FlashProbeError.invalidArgument("chunk size above 256 MiB is not useful")
        }
        guard sampleEvery >= 1 else { throw FlashProbeError.invalidArgument("--sample must be ≥ 1") }
        guard deviceSize % blockSize == 0 else {
            throw FlashProbeError.invalidArgument("device size is not a multiple of the block size")
        }
        let s = (start / chunkSize) * chunkSize
        guard s < deviceSize else { throw FlashProbeError.invalidArgument("start is beyond the end of the device") }
        var e = length.map { min(deviceSize, start &+ $0) } ?? deviceSize
        if e < start { e = deviceSize } // overflow guard
        e = min(deviceSize, (e + blockSize - 1) / blockSize * blockSize)
        guard e > s else { throw FlashProbeError.invalidArgument("scan length is zero") }

        self.deviceSize = deviceSize
        self.blockSize = blockSize
        self.chunkSize = chunkSize
        self.start = s
        self.end = e
        self.sampleEvery = sampleEvery
    }

    public var firstIndex: Int { Int(start / chunkSize) }
    public var lastIndex: Int { Int((end - 1) / chunkSize) }

    public var chunks: [ChunkSpec] {
        var out: [ChunkSpec] = []
        out.reserveCapacity((lastIndex - firstIndex) / sampleEvery + 1)
        var i = firstIndex
        while i <= lastIndex {
            if i % sampleEvery == 0 {
                let off = UInt64(i) * chunkSize
                let len = min(chunkSize, end - off)
                out.append(ChunkSpec(index: i, offset: off, length: Int(len)))
            }
            i += 1
        }
        return out
    }
}

// MARK: - Results

public struct ChunkResult: Codable, Equatable, Sendable {
    public let index: Int
    public let offset: UInt64
    public let length: Int
    /// nil when the read failed
    public let seconds: Double?
    /// errno when the read failed
    public let errorCode: Int32?
    public var rereadSeconds: [Double]

    public init(index: Int, offset: UInt64, length: Int, seconds: Double?, errorCode: Int32?, rereadSeconds: [Double] = []) {
        self.index = index; self.offset = offset; self.length = length
        self.seconds = seconds; self.errorCode = errorCode; self.rereadSeconds = rereadSeconds
    }

    public var mbps: Double? { seconds.map { mbPerSecond(bytes: length, seconds: $0) } }
    public var rereadMBps: [Double] { rereadSeconds.map { mbPerSecond(bytes: length, seconds: $0) } }
}

public struct ScanOptions: Sendable {
    /// Re-read each slow chunk this many times after the main pass (0 = off).
    public var rereadCount: Int = 0
    /// Re-read at most this many slow chunks, spread evenly over all slow ones
    /// (a mostly-slow drive would otherwise take many hours).
    public var rereadMax: Int = 256
    /// A chunk is "slow" below this fraction of the reference speed (p90:
    /// what the drive manages on its good areas). Using the median instead
    /// fails on drives where most of the data is old and slow.
    public var slowFraction: Double = 0.5
    /// Give up after this many failed reads in a row (drive probably gone).
    public var maxConsecutiveErrors: Int = 32

    public init(rereadCount: Int = 0, rereadMax: Int = 256, slowFraction: Double = 0.5, maxConsecutiveErrors: Int = 32) {
        self.rereadCount = rereadCount; self.rereadMax = rereadMax; self.slowFraction = slowFraction
        self.maxConsecutiveErrors = maxConsecutiveErrors
    }
}

public struct ProgressInfo: Sendable {
    public enum Phase: String, Sendable { case scan, reread }
    public let phase: Phase
    public let done: Int
    public let total: Int
    public let bytesDone: UInt64
    public let bytesTotal: UInt64
    public let elapsed: Double
    public let last: ChunkResult?
}

public struct ScanOutcome: Sendable {
    public let results: [ChunkResult]
    public let interrupted: Bool
    public let stoppedReason: String?
    public let elapsed: Double
    public let startedAt: Date
}

// MARK: - Scanner

public final class Scanner {
    let source: BlockSource
    let plan: ScanPlan
    let options: ScanOptions
    let shouldStop: () -> Bool
    let clock: () -> Double

    public init(source: BlockSource, plan: ScanPlan, options: ScanOptions = .init(),
                shouldStop: @escaping () -> Bool = { InterruptFlag.shared.requested },
                clock: @escaping () -> Double = monotonicSeconds) {
        self.source = source; self.plan = plan; self.options = options
        self.shouldStop = shouldStop; self.clock = clock
    }

    public func run(progress: ((ProgressInfo) -> Void)? = nil) -> ScanOutcome {
        let startedAt = Date()
        let t0 = clock()
        let chunks = plan.chunks
        let bytesTotal = chunks.reduce(UInt64(0)) { $0 + UInt64($1.length) }
        let buf = AlignedBuffer(count: Int(plan.chunkSize))

        var results: [ChunkResult] = []
        results.reserveCapacity(chunks.count)
        var bytesDone: UInt64 = 0
        var consecutiveErrors = 0
        var stopped: String?
        var interrupted = false

        for c in chunks {
            if shouldStop() { interrupted = true; stopped = "interrupted"; break }
            let (secs, err) = timedRead(c, buf)
            let r = ChunkResult(index: c.index, offset: c.offset, length: c.length, seconds: secs, errorCode: err)
            results.append(r)
            if let err {
                consecutiveErrors += 1
                if err == ENXIO || err == ENODEV {
                    stopped = "device disappeared (\(String(cString: strerror(err))))"; break
                }
                if consecutiveErrors >= options.maxConsecutiveErrors {
                    stopped = "\(consecutiveErrors) consecutive read errors"; break
                }
            } else {
                consecutiveErrors = 0
            }
            bytesDone += UInt64(c.length)
            progress?(ProgressInfo(phase: .scan, done: results.count, total: chunks.count,
                                   bytesDone: bytesDone, bytesTotal: bytesTotal, elapsed: clock() - t0, last: r))
        }

        if stopped == nil, options.rereadCount > 0 {
            let slow = Scanner.evenSample(Scanner.slowPositions(results, fraction: options.slowFraction),
                                          max: options.rereadMax)
            let total = slow.count * options.rereadCount
            var done = 0
            // Pass over all slow chunks, then repeat, so no chunk is read twice
            // back-to-back (avoids measuring a controller-side cache hit).
            outer: for _ in 0..<options.rereadCount {
                for pos in slow {
                    if shouldStop() { interrupted = true; stopped = "interrupted during re-reads"; break outer }
                    let r = results[pos]
                    let (secs, _) = timedRead(ChunkSpec(index: r.index, offset: r.offset, length: r.length), buf)
                    if let secs { results[pos].rereadSeconds.append(secs) }
                    done += 1
                    progress?(ProgressInfo(phase: .reread, done: done, total: total,
                                           bytesDone: 0, bytesTotal: 0, elapsed: clock() - t0, last: results[pos]))
                }
            }
        }

        return ScanOutcome(results: results, interrupted: interrupted, stoppedReason: stopped,
                           elapsed: clock() - t0, startedAt: startedAt)
    }

    private func timedRead(_ c: ChunkSpec, _ buf: AlignedBuffer) -> (Double?, Int32?) {
        let t = clock()
        let n = source.read(into: buf.pointer, length: c.length, offset: c.offset)
        let dt = clock() - t
        if n < 0 { return (nil, Int32(-n)) }
        if n < c.length { return (nil, EIO) } // short read on a block device = failure
        return (dt, nil)
    }

    /// Reference speed for "slow": the 90th percentile of successful reads.
    public static func referenceSpeed(_ results: [ChunkResult]) -> Double? {
        Stats.percentile(results.compactMap(\.mbps).sorted(), 90)
    }

    /// Up to `max` elements spread evenly across `xs` (keeps order).
    public static func evenSample<T>(_ xs: [T], max: Int) -> [T] {
        guard max > 0 else { return [] }
        guard xs.count > max else { return xs }
        return (0..<max).map { xs[$0 * xs.count / max] }
    }

    /// Positions (into `results`) of chunks that failed or ran below
    /// `fraction` × reference (p90) speed.
    public static func slowPositions(_ results: [ChunkResult], fraction: Double) -> [Int] {
        guard let reference = referenceSpeed(results) else {
            return results.indices.filter { results[$0].errorCode != nil }
        }
        let threshold = reference * fraction
        return results.indices.filter {
            results[$0].errorCode != nil || (results[$0].mbps ?? .infinity) < threshold
        }
    }
}
