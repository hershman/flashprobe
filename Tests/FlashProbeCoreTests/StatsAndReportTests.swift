import XCTest
@testable import FlashProbeCore

private let MiB = 1 << 20

/// Results with 1 MiB chunks at the given speeds (nil = read error).
private func results(_ speeds: [Double?]) -> [ChunkResult] {
    speeds.enumerated().map { i, v in
        ChunkResult(index: i, offset: UInt64(i * MiB), length: MiB,
                    seconds: v.map { Double(MiB) / 1e6 / $0 }, errorCode: v == nil ? 5 : nil)
    }
}

final class StatsTests: XCTestCase {
    func testPercentileInterpolates() {
        let s = [1.0, 2, 3, 4, 5]
        XCTAssertEqual(Stats.percentile(s, 50), 3)
        XCTAssertEqual(Stats.percentile(s, 0), 1)
        XCTAssertEqual(Stats.percentile(s, 100), 5)
        XCTAssertEqual(Stats.percentile(s, 25), 2)
        XCTAssertEqual(Stats.percentile([10, 20], 50), 15)
        XCTAssertNil(Stats.percentile([], 50))
    }

    func testSpeedStats() {
        let st = Stats.speedStats(results([100, 100, 10, nil]))
        XCTAssertEqual(st.chunksRead, 3)
        XCTAssertEqual(st.errors, 1)
        XCTAssertEqual(st.median!, 100, accuracy: 1e-9)
        XCTAssertEqual(st.min!, 10, accuracy: 1e-9)
        // effective = 3 MiB / (2×0.010486 + 0.10486 s) = 25 MB/s
        XCTAssertEqual(st.effective!, 25, accuracy: 1e-6)
    }

    func testHistogramBuckets() {
        let h = Stats.histogram(results([1, 3, 7, 7, 15, 450, nil]))
        func count(_ label: String) -> Int { h.first { $0.label == label }!.count }
        XCTAssertEqual(count("0–2"), 1)
        XCTAssertEqual(count("2–5"), 1)
        XCTAssertEqual(count("5–10"), 2)
        XCTAssertEqual(count("10–20"), 1)
        XCTAssertEqual(count("≥400"), 1)
        XCTAssertEqual(h.reduce(0) { $0 + $1.count }, 6)
    }

    func testSlowRegionsMergeSmallGapsAndSortByTime() {
        // idx:   0    1   2   3    4   5    6    7    8   9
        let r = results([100, 10, 10, 100, 10, 100, 100, 100, 5, nil])
        let regions = Stats.slowRegions(r, thresholdMBps: 50, maxGap: 1)
        XCTAssertEqual(regions.count, 2)
        // 8–9 (5 MB/s + error) costs 0.21 s; 1–4 costs 3×0.105 + 0.0105 s, so it's first.
        let a = regions.first { $0.firstIndex == 1 }!
        XCTAssertEqual(a.lastIndex, 4)
        XCTAssertEqual(a.chunks, 4)
        XCTAssertEqual(a.slowChunks, 3)
        XCTAssertEqual(a.endOffset, UInt64(5 * MiB))
        let b = regions.first { $0.firstIndex == 8 }!
        XCTAssertEqual(b.errors, 1)
        XCTAssertEqual(b.minMBps!, 5, accuracy: 1e-9)
        XCTAssertEqual(regions.first?.firstIndex, 1)
    }

    func testSlowPositions() {
        let r = results([100, 100, 100, 20, nil])
        XCTAssertEqual(Scanner.slowPositions(r, fraction: 0.5), [3, 4])
    }

    func testMostlySlowDriveIsJudgedAgainstItsGoodAreas() {
        // 70% old data at ~10 MB/s, 30% at 300 MB/s: median is slow, p90 is not.
        let speeds: [Double?] = Array(repeating: 10, count: 70) + Array(repeating: 300, count: 30)
        let slow = Scanner.slowPositions(results(speeds), fraction: 0.5)
        XCTAssertEqual(slow, Array(0..<70))
    }

    func testEvenSample() {
        XCTAssertEqual(Scanner.evenSample(Array(0..<10), max: 20), Array(0..<10))
        XCTAssertEqual(Scanner.evenSample(Array(0..<10), max: 5), [0, 2, 4, 6, 8])
        XCTAssertEqual(Scanner.evenSample(Array(0..<10), max: 0), [])
    }

    func testRereadSummaryUsesThresholdNotFirstRead() throws {
        var rs = results(Array(repeating: 300, count: 9) + [5])
        rs[9].rereadSeconds = [Double(MiB) / 1e6 / 8, Double(MiB) / 1e6 / 9]   // faster than 5, still slow
        let plan = try ScanPlan(deviceSize: UInt64(10 * MiB), blockSize: 512, chunkSize: UInt64(MiB))
        let outcome = ScanOutcome(results: rs, interrupted: false, stoppedReason: nil, elapsed: 1, startedAt: Date())
        let dev = DeviceSummary(vendorID: "", productID: "", bcdDevice: "", serial: "s", manufacturer: "", product: "",
                                bsdName: "diskX", size: UInt64(10 * MiB), blockSize: 512)
        let rep = ScanReport.build(device: dev, plan: plan, outcome: outcome, options: ScanOptions(rereadCount: 2))
        XCTAssertEqual(rep.reread?.fractionRereadsAboveThreshold, 0)
        XCTAssertTrue(TextSummary.render(rep).contains("stable property"))
    }
}

final class ReportTests: XCTestCase {
    func sampleReport(product: String = "Type-C") throws -> (ScanReport, [ChunkResult]) {
        var rs = results([100, 9.5, nil, 50])
        rs[1].rereadSeconds = [Double(MiB) / 1e6 / 10]
        let plan = try ScanPlan(deviceSize: UInt64(4 * MiB), blockSize: 512, chunkSize: UInt64(MiB))
        let outcome = ScanOutcome(results: rs, interrupted: false, stoppedReason: nil, elapsed: 1, startedAt: Date(timeIntervalSince1970: 0))
        let dev = DeviceSummary(vendorID: "0x090c", productID: "0x1000", bcdDevice: "0x1100", serial: "SERIAL0000000001",
                                manufacturer: "Samsung", product: product, bsdName: "disk6", size: UInt64(4 * MiB), blockSize: 512)
        let rep = ScanReport.build(device: dev, plan: plan, outcome: outcome, options: ScanOptions(rereadCount: 1),
                                   now: Date(timeIntervalSince1970: 0))
        return (rep, rs)
    }

    func testCSV() throws {
        let (_, rs) = try sampleReport()
        let lines = CSVReport.render(rs).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines[0], CSVReport.header)
        XCTAssertEqual(lines.count, 5)
        XCTAssertEqual(lines[1], "0,0,1048576,0.010486,100.000,,")
        XCTAssertEqual(lines[2], "1,1048576,1048576,0.110376,9.500,,10.000")
        XCTAssertEqual(lines[3], "2,2097152,1048576,,,5,")
    }

    func testReportJSONRoundTrips() throws {
        let (rep, _) = try sampleReport()
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let back = try dec.decode(ScanReport.self, from: rep.jsonData())
        XCTAssertEqual(back, rep)
        XCTAssertEqual(rep.reread?.chunks, 1)
        XCTAssertEqual(rep.stats.errors, 1)
    }

    func testHTMLEmbedsDataAndCannotBreakOutOfScript() throws {
        let (rep, rs) = try sampleReport(product: "</script><img src=x onerror=alert(1)>")
        let html = try HTMLReport.render(report: rep, results: rs)
        XCTAssertFalse(html.contains("__FLASHPROBE_DATA__"))
        XCTAssertFalse(html.contains("</script><img"))
        XCTAssertEqual(html.components(separatedBy: "</script>").count - 1, 2) // only our two closing tags
        XCTAssertTrue(html.contains("\"speeds\":[100,9.5,-1,50]"))
        XCTAssertTrue(html.contains("<title>Flash Speed Map</title>"))
    }

    func testHeatmapColumns() {
        XCTAssertEqual(HTMLReport.columns(chunkSize: 4 << 20), 256)
        XCTAssertEqual(HTMLReport.columns(chunkSize: 1 << 20), 512)
        XCTAssertEqual(HTMLReport.columns(chunkSize: 64 << 20), 64)
    }

    func testTextSummaryMentionsKeyNumbers() throws {
        let (rep, _) = try sampleReport()
        let s = TextSummary.render(rep)
        XCTAssertTrue(s.contains("read errors: 1"))
        XCTAssertTrue(s.contains("Slow regions"))
        XCTAssertTrue(s.contains("Re-reads"))
    }
}
