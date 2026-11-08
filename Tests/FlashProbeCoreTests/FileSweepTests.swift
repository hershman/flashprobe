import XCTest
@testable import FlashProbeCore

final class FileSweepTests: XCTestCase {
    let MiB: UInt64 = 1 << 20
    let dev = DeviceSummary(vendorID: "0x090c", productID: "0x1000", bcdDevice: "0x1100", serial: "S",
                            manufacturer: "Samsung", product: "Type-C", bsdName: "disk6", size: 1, blockSize: 512)

    func testChunkOffsets() {
        let c = Int(4 * MiB)
        XCTAssertEqual(FileSweep.chunkOffsets(fileSize: 10 * MiB, chunk: c, budget: nil), [0, 4 * MiB, 8 * MiB])
        XCTAssertEqual(FileSweep.chunkOffsets(fileSize: 10 * MiB, chunk: c, budget: 64 * MiB), [0, 4 * MiB, 8 * MiB])
        // 100 chunks, budget 4 chunks: first, last, two evenly between
        let o = FileSweep.chunkOffsets(fileSize: 400 * MiB, chunk: c, budget: 16 * MiB)
        XCTAssertEqual(o.map { $0 / (4 * MiB) }, [0, 33, 66, 99])
        XCTAssertEqual(FileSweep.chunkOffsets(fileSize: 0, chunk: c, budget: nil), [])
    }

    func file(_ name: String, mbps: Double?, created: String?, size: UInt64 = 100 << 20) -> FileSpeed {
        let iso = ISO8601DateFormatter()
        var f = FileSpeed(path: "/Volumes/V/" + name, relativePath: name, size: size,
                          created: created.flatMap { iso.date(from: $0 + "T12:00:00Z") }, modified: nil)
        f.mbps = mbps
        if mbps != nil { f.bytesRead = size; f.seconds = Double(size) / 1e6 / mbps! }
        return f
    }

    func testSummaryGroupsAndAgeFacts() {
        let files = [
            file("Old/a.mov", mbps: 300, created: "2019-03-01"),     // older than every slow file, fast
            file("Photos2021/b.jpg", mbps: 7, created: "2021-05-01"),
            file("Photos2021/c.jpg", mbps: 6, created: "2021-05-20"),
            file("Mixed/d.mov", mbps: 320, created: "2021-05-10"),   // inside the slow range, fast
            file("New/e.mov", mbps: 330, created: "2024-01-01"),
            file("tiny.txt", mbps: nil, created: "2020-01-01", size: 10),
        ]
        var opts = FileSweepOptions(); opts.minSize = 4 * MiB
        let s = FileSweep.summarize(files: files, device: dev, volume: "/Volumes/V", options: opts,
                                    interrupted: false, elapsed: 1)
        XCTAssertEqual(s.filesTimed, 5)
        XCTAssertEqual(s.filesSkippedSmall, 1)
        XCTAssertEqual(s.slowFiles, 2)
        XCTAssertEqual(s.slowBytes, 200 << 20)
        XCTAssertEqual(s.fastFilesOlderThanAllSlow, 1)
        XCTAssertEqual(s.fastFilesInsideSlowRange, 1)
        XCTAssertEqual(s.byFolder.first?.key, "Photos2021")
        XCTAssertEqual(s.byFolder.first?.slowFiles, 2)
        XCTAssertEqual(s.byCreatedMonth.map(\.key), ["2019-03", "2021-05", "2024-01"])
        XCTAssertEqual(s.byCreatedMonth[1].slowFiles, 2)
        XCTAssertEqual(s.slowest.first?.relativePath, "Photos2021/c.jpg")
        let text = FileSweep.text(s)
        XCTAssertTrue(text.contains("Slow files: 2"))
        XCTAssertTrue(text.contains("created before the oldest slow file: 1"))
    }

    func testSmallFilesNeedRealDelayToCountAsSlow() {
        var quick = file("a.jpg", mbps: 150, created: nil, size: 200_000)   // 1.3 ms: healthy, latency-bound
        quick.seconds = 0.0013
        var slow = file("b.jpg", mbps: 7, created: nil, size: 200_000)      // 29 ms
        slow.seconds = 0.029
        XCTAssertFalse(FileSweep.isSlow(quick, threshold: 175))
        XCTAssertTrue(FileSweep.isSlow(slow, threshold: 175))
        XCTAssertFalse(FileSweep.isSlow(slow, threshold: nil))
        // reference comes from big files only
        let s = FileSweep.summarize(files: [file("big.mov", mbps: 330, created: nil), quick, slow], device: dev,
                                    volume: "/V", options: FileSweepOptions(), interrupted: false, elapsed: 1)
        XCTAssertEqual(s.referenceMBps!, 330, accuracy: 1e-9)
        XCTAssertEqual(s.slowFiles, 1)
    }

    func testPlateauDriveFlagsOnlyRealOutliers() {
        // Shape seen on a real 1 TB drive: most files on a ~33 MB/s plateau, a quarter fast, a few stalled.
        var files: [FileSpeed] = []
        for i in 0..<70 { files.append(file("p/\(i).mp4", mbps: 31 + Double(i % 5), created: nil)) }
        for i in 0..<25 { files.append(file("f/\(i).mp4", mbps: 360, created: nil)) }
        for i in 0..<3 { files.append(file("s/\(i).mp4", mbps: 1, created: nil)) }
        let s = FileSweep.summarize(files: files, device: dev, volume: "/V", options: FileSweepOptions(),
                                    interrupted: false, elapsed: 1)
        XCTAssertEqual(s.referenceMBps!, 33, accuracy: 2)
        XCTAssertEqual(s.slowFiles, 3)
        XCTAssertTrue(FileSweep.text(s).contains("so the typical file is slow too"))
    }

    func testTopFolder() {
        XCTAssertEqual(file("a/b/c.mov", mbps: 1, created: nil).topFolder, "a")
        XCTAssertEqual(file("c.mov", mbps: 1, created: nil).topFolder, "(root)")
    }

    func testCSVQuotesPaths() {
        let f = file("dir, \"quoted\"/x.mov", mbps: 10, created: "2021-01-01")
        let lines = FileSweep.csv([f]).split(separator: "\n")
        XCTAssertEqual(String(lines[0]), FileSweep.csvHeader)
        XCTAssertTrue(lines[1].hasPrefix("\"dir, \"\"quoted\"\"/x.mov\",104857600,2021-01-01T12:00:00Z,"))
    }

    func testRunReadsRealFilesAndSkipsSmallOnes() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("fp-files-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(count: Int(9 * MiB)).write(to: dir.appendingPathComponent("sub/big.bin"))
        try Data(count: 1000).write(to: dir.appendingPathComponent("small.bin"))
        try Data(count: Int(5 * MiB)).write(to: dir.appendingPathComponent(".hidden.bin"))
        var opts = FileSweepOptions(); opts.minSize = 4 * MiB; opts.perFileBudget = nil
        let listed = FileSweep.enumerate(root: dir, options: opts)
        XCTAssertEqual(listed.map(\.relativePath), ["small.bin", "sub/big.bin"])
        let r = FileSweep.run(files: listed, options: opts, shouldStop: { false })
        let big = r.files.first { $0.relativePath == "sub/big.bin" }!
        XCTAssertEqual(big.bytesRead, 9 * MiB)
        XCTAssertEqual(big.chunks, 3)
        XCTAssertNotNil(big.mbps)
        XCTAssertNil(r.files.first { $0.relativePath == "small.bin" }!.mbps)
        XCTAssertFalse(r.interrupted)
    }

    func testHTMLEscapesPaths() throws {
        let files = [file("</script><b>x.mov", mbps: 10, created: "2021-01-01"), file("y.mov", mbps: 300, created: "2022-01-01")]
        let s = FileSweep.summarize(files: files, device: dev, volume: "/Volumes/V", options: FileSweepOptions(),
                                    interrupted: false, elapsed: 1)
        let html = try FilesHTML.render(summary: s, files: files)
        XCTAssertFalse(html.contains("</script><b>"))
        XCTAssertEqual(html.components(separatedBy: "</script>").count - 1, 2)
        XCTAssertTrue(html.contains("<title>File Read Speeds</title>"))
    }
}
