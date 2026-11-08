import XCTest
@testable import FlashProbeCore

/// `FLASHPROBE_DEMO_DIR=/some/dir swift test --filter DemoReportTests` writes a
/// synthetic full-size report (256 GB, 4 MiB chunks) for eyeballing the HTML.
/// Skipped otherwise.
final class DemoReportTests: XCTestCase {
    func testWriteDemoReport() throws {
        guard let dir = ProcessInfo.processInfo.environment["FLASHPROBE_DEMO_DIR"] else {
            throw XCTSkip("set FLASHPROBE_DEMO_DIR to write the demo report")
        }
        let size: UInt64 = 256_641_603_584
        let chunk: UInt64 = 4 << 20
        // Old data (first ~180 GB, written long ago) reads 5–15 MB/s; a band
        // written recently reads ~300 MB/s; the never-written tail reads fast.
        var rng = SystemRandomNumberGenerator()
        let src = FakeSource(size: size) { off in
            let g = Double(off) / 1e9
            if g > 120 && g < 128 { return Double.random(in: 260...330, using: &rng) }
            if g < 180 { return Double.random(in: 5...15, using: &rng) * (g > 60 && g < 64 ? 0.4 : 1) }
            return Double.random(in: 300...380, using: &rng)
        }
        src.failAt = [UInt64(15_000) * chunk]
        let plan = try ScanPlan(deviceSize: size, blockSize: 512, chunkSize: chunk)
        let options = ScanOptions(rereadCount: 3, slowFraction: 0.5)
        let outcome = Scanner(source: src, plan: plan, options: options, shouldStop: { false }, clock: { src.now }).run()
        let dev = DeviceSummary(vendorID: "0x090c", productID: "0x1000", bcdDevice: "0x1100", serial: "DEMO-SYNTHETIC",
                                manufacturer: "Synthetic", product: "demo data", bsdName: "diskX", size: size, blockSize: 512)
        let report = ScanReport.build(device: dev, plan: plan, outcome: outcome, options: options)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try HTMLReport.render(report: report, results: outcome.results)
            .write(toFile: dir + "/scan.html", atomically: true, encoding: .utf8)
        try TextSummary.render(report).write(toFile: dir + "/summary.txt", atomically: true, encoding: .utf8)
    }
}
