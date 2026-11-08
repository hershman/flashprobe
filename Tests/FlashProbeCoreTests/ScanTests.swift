import XCTest
import Darwin
@testable import FlashProbeCore

/// Deterministic block source: a virtual clock advances by length / speed(offset).
final class FakeSource: BlockSource {
    let size: UInt64
    let blockSize: UInt64 = 512
    var now = 0.0
    var speedMBps: (UInt64) -> Double
    var failAt: Set<UInt64> = []
    var reads: [UInt64] = []

    init(size: UInt64, speed: @escaping (UInt64) -> Double) {
        self.size = size; self.speedMBps = speed
    }

    func read(into buffer: UnsafeMutableRawPointer, length: Int, offset: UInt64) -> Int {
        reads.append(offset)
        now += Double(length) / 1e6 / speedMBps(offset)
        return failAt.contains(offset) ? -Int(EIO) : length
    }
}

final class ScanPlanTests: XCTestCase {
    let MiB: UInt64 = 1 << 20

    func testWholeDeviceWithShortLastChunk() throws {
        let p = try ScanPlan(deviceSize: 10 * MiB + 512, blockSize: 512, chunkSize: 4 * MiB)
        let c = p.chunks
        XCTAssertEqual(c.map(\.index), [0, 1, 2])
        XCTAssertEqual(c.map(\.offset), [0, 4 * MiB, 8 * MiB])
        XCTAssertEqual(c.last?.length, Int(2 * MiB + 512))
        XCTAssertEqual(c.reduce(0) { $0 + $1.length }, Int(10 * MiB + 512))
    }

    func testStartRoundsDownToChunkAndIndicesAreAbsolute() throws {
        let p = try ScanPlan(deviceSize: 64 * MiB, blockSize: 512, chunkSize: 4 * MiB, start: 9 * MiB, length: 8 * MiB)
        XCTAssertEqual(p.start, 8 * MiB)
        XCTAssertEqual(p.end, 17 * MiB)
        XCTAssertEqual(p.chunks.map(\.index), [2, 3, 4])
        XCTAssertEqual(p.chunks.last?.length, Int(1 * MiB))
    }

    func testSampling() throws {
        let p = try ScanPlan(deviceSize: 40 * MiB, blockSize: 512, chunkSize: 4 * MiB, sampleEvery: 3)
        XCTAssertEqual(p.chunks.map(\.index), [0, 3, 6, 9])
    }

    func testRejectsBadGeometry() {
        XCTAssertThrowsError(try ScanPlan(deviceSize: 8 * MiB, blockSize: 512, chunkSize: 1000))
        XCTAssertThrowsError(try ScanPlan(deviceSize: 8 * MiB, blockSize: 500, chunkSize: 4 * MiB))
        XCTAssertThrowsError(try ScanPlan(deviceSize: 8 * MiB, blockSize: 512, chunkSize: 4 * MiB, start: 8 * MiB))
        XCTAssertThrowsError(try ScanPlan(deviceSize: 8 * MiB, blockSize: 512, chunkSize: 4 * MiB, sampleEvery: 0))
        XCTAssertThrowsError(try ScanPlan(deviceSize: 8 * MiB + 1, blockSize: 512, chunkSize: 4 * MiB))
    }
}

final class ScannerTests: XCTestCase {
    let MiB: UInt64 = 1 << 20

    func testTimesEveryChunkWithVirtualClock() throws {
        // First half 100 MB/s, second half 10 MB/s.
        let size = 16 * MiB
        let src = FakeSource(size: size) { $0 < 8 << 20 ? 100 : 10 }
        let plan = try ScanPlan(deviceSize: size, blockSize: 512, chunkSize: 2 * MiB)
        let out = Scanner(source: src, plan: plan, shouldStop: { false }, clock: { src.now }).run()
        XCTAssertEqual(out.results.count, 8)
        XCTAssertFalse(out.interrupted)
        XCTAssertEqual(out.results[0].mbps!, 100, accuracy: 1e-6)
        XCTAssertEqual(out.results[7].mbps!, 10, accuracy: 1e-6)
    }

    func testErrorsAreRecordedAndScanContinues() throws {
        let size = 8 * MiB
        let src = FakeSource(size: size) { _ in 50 }
        src.failAt = [2 * MiB]
        let plan = try ScanPlan(deviceSize: size, blockSize: 512, chunkSize: 1 * MiB)
        let out = Scanner(source: src, plan: plan, shouldStop: { false }, clock: { src.now }).run()
        XCTAssertEqual(out.results.count, 8)
        XCTAssertEqual(out.results[2].errorCode, EIO)
        XCTAssertNil(out.results[2].seconds)
        XCTAssertNil(out.stoppedReason)
    }

    func testStopsAfterConsecutiveErrors() throws {
        let size = 64 * MiB
        let src = FakeSource(size: size) { _ in 50 }
        src.failAt = Set((0..<64).map { UInt64($0) * MiB })
        let plan = try ScanPlan(deviceSize: size, blockSize: 512, chunkSize: 1 * MiB)
        let out = Scanner(source: src, plan: plan, options: ScanOptions(maxConsecutiveErrors: 5),
                          shouldStop: { false }, clock: { src.now }).run()
        XCTAssertEqual(out.results.count, 5)
        XCTAssertNotNil(out.stoppedReason)
    }

    func testInterruptStopsAndKeepsPartialResults() throws {
        let size = 32 * MiB
        let src = FakeSource(size: size) { _ in 50 }
        let plan = try ScanPlan(deviceSize: size, blockSize: 512, chunkSize: 1 * MiB)
        let out = Scanner(source: src, plan: plan, shouldStop: { src.reads.count >= 3 }, clock: { src.now }).run()
        XCTAssertEqual(out.results.count, 3)
        XCTAssertTrue(out.interrupted)
    }

    func testRereadsOnlySlowChunksAndNeverBackToBack() throws {
        let size = 10 * MiB
        // chunks 3 and 4 slow (5 MB/s), the rest 100 MB/s
        let src = FakeSource(size: size) { ($0 >= 3 << 20 && $0 < 5 << 20) ? 5 : 100 }
        let plan = try ScanPlan(deviceSize: size, blockSize: 512, chunkSize: 1 * MiB)
        let out = Scanner(source: src, plan: plan, options: ScanOptions(rereadCount: 3, slowFraction: 0.5),
                          shouldStop: { false }, clock: { src.now }).run()
        XCTAssertEqual(out.results.filter { !$0.rereadSeconds.isEmpty }.map(\.index), [3, 4])
        XCTAssertEqual(out.results[3].rereadSeconds.count, 3)
        let rereadOffsets = Array(src.reads.dropFirst(10))
        XCTAssertEqual(rereadOffsets, [3, 4, 3, 4, 3, 4].map { UInt64($0) * MiB })
    }

    func testFileBlockSourceEndToEnd() throws {
        let path = NSTemporaryDirectory() + "flashprobe-test-\(UUID().uuidString).bin"
        let data = Data((0..<(3 * 1024 * 1024 + 512)).map { UInt8(truncatingIfNeeded: $0) })
        try data.write(to: URL(fileURLWithPath: path))
        defer { unlink(path) }
        let src = try FileBlockSource(path: path)
        let plan = try ScanPlan(deviceSize: src.size, blockSize: 512, chunkSize: 1 << 20)
        let out = Scanner(source: src, plan: plan, shouldStop: { false }).run()
        XCTAssertEqual(out.results.count, 4)
        XCTAssertTrue(out.results.allSatisfy { $0.errorCode == nil && $0.seconds != nil })
        XCTAssertEqual(out.results.last?.length, 512)
    }
}
