import XCTest
@testable import FlashProbeCore

/// Target-selection refusal rules and compare-fresh decision logic.
final class TargetSelectionTests: XCTestCase {
    func disk(_ bsd: String = "disk6", isInternal: Bool? = false, proto: String? = "USB", apfs: Bool = false) -> DiskInfo {
        DiskInfo(bsdName: bsd, size: 256_641_603_584, preferredBlockSize: 512, bsdMajor: 1, bsdMinor: 24,
                 content: "FDisk_partition_scheme",
                 partitions: [PartitionInfo(bsdName: bsd + "s1", content: "Windows_NTFS", size: 256_640_000_000,
                                            mountPoint: "/Volumes/SAMSUNG USB")],
                 containsAPFS: apfs, isInternal: isInternal, deviceProtocol: proto)
    }

    func device(serial: String? = "SERIAL0000000001", disks: [DiskInfo]? = nil) -> USBStorageDevice {
        USBStorageDevice(vendorID: 0x090c, productID: 0x1000, bcdDevice: 0x1100, serial: serial,
                         manufacturer: "Samsung", product: "Type-C", locationID: 0x0320_0000, disks: disks ?? [disk()])
    }

    func testSelectsExactSerial() throws {
        let other = device(serial: "SERIAL0000000002", disks: [disk("disk12")])
        let t = try DeviceLocator.selectTarget(serial: " SERIAL0000000001 ", from: [other, device()])
        XCTAssertEqual(t.disk.bsdName, "disk6")
    }

    func testRefusals() {
        func refused(_ devs: [USBStorageDevice], serial: String = "SERIAL0000000001") -> FlashProbeError? {
            do { _ = try DeviceLocator.selectTarget(serial: serial, from: devs); return nil }
            catch let e as FlashProbeError { return e } catch { return nil }
        }
        // serial mismatch (no prefix matching either)
        if case .noSuchSerial = refused([device()], serial: "037372308000068") {} else { XCTFail("prefix must not match") }
        if case .invalidArgument = refused([device()], serial: "  ") {} else { XCTFail("empty serial") }
        if case .ambiguousSerial = refused([device(), device()]) {} else { XCTFail("duplicate serial") }
        if case .refused = refused([device(disks: [disk(isInternal: true)])]) {} else { XCTFail("internal") }
        if case .refused = refused([device(disks: [disk(isInternal: nil)])]) {} else { XCTFail("unknown internal flag") }
        if case .refused = refused([device(disks: [disk(proto: "Apple Fabric")])]) {} else { XCTFail("non-USB") }
        if case .refused = refused([device(disks: [disk(apfs: true)])]) {} else { XCTFail("APFS") }
        if case .refused = refused([device(disks: [])]) {} else { XCTFail("no disk") }
        if case .refused = refused([device(disks: [disk("disk6"), disk("disk7")])]) {} else { XCTFail("two disks") }
    }

    func testPartitionOwnership() {
        XCTAssertTrue(DeviceLocator.partition("/dev/disk6s1", belongsTo: "disk6"))
        XCTAssertTrue(DeviceLocator.partition("disk6s12", belongsTo: "disk6"))
        XCTAssertFalse(DeviceLocator.partition("/dev/disk61s1", belongsTo: "disk6"))
        XCTAssertFalse(DeviceLocator.partition("/dev/disk6", belongsTo: "disk6"))
        XCTAssertFalse(DeviceLocator.partition("/dev/disk6s", belongsTo: "disk6"))
        XCTAssertFalse(DeviceLocator.partition("map auto_home", belongsTo: "disk6"))
    }
}

final class CompareFreshVerdictTests: XCTestCase {
    func testVerdicts() {
        XCTAssertEqual(CompareFresh.verdict(freshMedian: 300, oldMedian: 8, integrityOK: true).kind, .agingData)
        XCTAssertEqual(CompareFresh.verdict(freshMedian: 300, oldMedian: 200, integrityOK: true).kind, .mildlySlower)
        XCTAssertEqual(CompareFresh.verdict(freshMedian: 300, oldMedian: 290, integrityOK: true).kind, .noDifference)
        XCTAssertEqual(CompareFresh.verdict(freshMedian: 20, oldMedian: 8, integrityOK: true).kind, .freshAlsoSlow)
        XCTAssertEqual(CompareFresh.verdict(freshMedian: 300, oldMedian: 3000, integrityOK: true).kind, .likelyCached)
        XCTAssertEqual(CompareFresh.verdict(freshMedian: 300, oldMedian: 8, integrityOK: false).kind, .integrityFailure)
        XCTAssertEqual(CompareFresh.verdict(freshMedian: nil, oldMedian: 8, integrityOK: true).kind, .insufficientData)
    }

    func testPickOldFilesUsesCreationDateAndBudget() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("fp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let blob = Data(count: 2 << 20)
        for (name, age) in [("new.bin", 10.0), ("old.bin", 1000.0), ("mid.bin", 500.0)] {
            let u = dir.appendingPathComponent(name)
            try blob.write(to: u)
            let d = Date(timeIntervalSinceNow: -age * 86400)
            try FileManager.default.setAttributes([.creationDate: d, .modificationDate: Date()], ofItemAtPath: u.path)
        }
        try Data(count: 1024).write(to: dir.appendingPathComponent("tiny.bin"))
        let picked = CompareFresh.pickOldFiles(root: dir, budget: 3 << 20, minSize: 1 << 20)
        XCTAssertEqual(picked.map { ($0.path as NSString).lastPathComponent }, ["old.bin", "mid.bin"])
    }
}
