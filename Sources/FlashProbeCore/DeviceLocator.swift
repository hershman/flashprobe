import Foundation
import IOKit
import DiskArbitration

public struct PartitionInfo: Codable, Sendable, Equatable {
    public var bsdName: String
    public var content: String
    public var size: UInt64
    public var mountPoint: String?

    public init(bsdName: String, content: String, size: UInt64, mountPoint: String? = nil) {
        self.bsdName = bsdName; self.content = content; self.size = size; self.mountPoint = mountPoint
    }
}

public struct DiskInfo: Codable, Sendable, Equatable {
    public var bsdName: String
    public var size: UInt64
    public var preferredBlockSize: UInt64
    public var bsdMajor: Int32
    public var bsdMinor: Int32
    public var content: String
    public var partitions: [PartitionInfo]
    public var containsAPFS: Bool
    /// From DiskArbitration. nil = unknown (treated as unsafe).
    public var isInternal: Bool?
    public var deviceProtocol: String?

    public init(bsdName: String, size: UInt64, preferredBlockSize: UInt64, bsdMajor: Int32, bsdMinor: Int32,
                content: String, partitions: [PartitionInfo], containsAPFS: Bool,
                isInternal: Bool?, deviceProtocol: String?) {
        self.bsdName = bsdName; self.size = size; self.preferredBlockSize = preferredBlockSize
        self.bsdMajor = bsdMajor; self.bsdMinor = bsdMinor; self.content = content
        self.partitions = partitions; self.containsAPFS = containsAPFS
        self.isInternal = isInternal; self.deviceProtocol = deviceProtocol
    }
}

public struct USBStorageDevice: Codable, Sendable, Equatable {
    public var vendorID: Int
    public var productID: Int
    public var bcdDevice: Int
    public var serial: String?
    public var manufacturer: String?
    public var product: String?
    public var locationID: Int
    public var disks: [DiskInfo]

    public init(vendorID: Int, productID: Int, bcdDevice: Int, serial: String?, manufacturer: String?,
                product: String?, locationID: Int, disks: [DiskInfo]) {
        self.vendorID = vendorID; self.productID = productID; self.bcdDevice = bcdDevice
        self.serial = serial; self.manufacturer = manufacturer; self.product = product
        self.locationID = locationID; self.disks = disks
    }
}

/// The one drive a command is allowed to touch, chosen by USB serial.
public struct Target: Sendable, Equatable {
    public let device: USBStorageDevice
    public let disk: DiskInfo
}

public enum DeviceLocator {
    static let apfsContainerGUID = "7C3457EF-0000-11AA-AA11-00306543ECAC"

    // MARK: Safety policy (pure, unit-tested)

    /// Choose the target by exact USB serial and apply every refusal rule.
    /// This is the only way commands obtain a `Target`.
    public static func selectTarget(serial: String, from devices: [USBStorageDevice]) throws -> Target {
        let wanted = serial.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { throw FlashProbeError.invalidArgument("--serial must not be empty") }

        let matches = devices.filter { $0.serial == wanted }
        guard !matches.isEmpty else {
            throw FlashProbeError.noSuchSerial(wanted, available: devices.compactMap(\.serial))
        }
        guard matches.count == 1 else { throw FlashProbeError.ambiguousSerial(wanted, count: matches.count) }

        let dev = matches[0]
        guard dev.disks.count == 1, let disk = dev.disks.first else {
            throw FlashProbeError.refused("expected exactly one whole disk on serial \(wanted), found \(dev.disks.count)")
        }
        if disk.containsAPFS {
            throw FlashProbeError.refused("\(disk.bsdName) contains an APFS container")
        }
        guard disk.isInternal == false else {
            throw FlashProbeError.refused("\(disk.bsdName) is internal (or DiskArbitration could not say it is external)")
        }
        guard disk.deviceProtocol == "USB" else {
            throw FlashProbeError.refused("\(disk.bsdName) protocol is \(disk.deviceProtocol ?? "unknown"), not USB")
        }
        guard disk.size > 0, disk.preferredBlockSize > 0 else {
            throw FlashProbeError.refused("\(disk.bsdName) reports no media size")
        }
        return Target(device: dev, disk: disk)
    }

    /// Does a mount's source device ("/dev/disk6s1") belong to whole disk "disk6"?
    public static func partition(_ mntFrom: String, belongsTo wholeBSD: String) -> Bool {
        let name = mntFrom.hasPrefix("/dev/") ? String(mntFrom.dropFirst(5)) : mntFrom
        let prefix = wholeBSD + "s"
        guard name.hasPrefix(prefix) else { return false }
        let rest = name.dropFirst(prefix.count)
        return !rest.isEmpty && rest.allSatisfy(\.isNumber)
    }

    // MARK: Live lookup

    public static func resolveTarget(serial: String) throws -> Target {
        try selectTarget(serial: serial, from: usbStorageDevices())
    }

    /// Every USB device that has at least one whole-disk IOMedia beneath it.
    public static func usbStorageDevices() throws -> [USBStorageDevice] {
        var it: io_iterator_t = 0
        let kr = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &it)
        guard kr == KERN_SUCCESS else { throw FlashProbeError.iokit("IOServiceGetMatchingServices", kr) }
        defer { IOObjectRelease(it) }

        let mounts = mountTable()
        var out: [USBStorageDevice] = []

        while case let dev = IOIteratorNext(it), dev != 0 {
            defer { IOObjectRelease(dev) }

            struct Media { var bsd: String; var whole: Bool; var size: UInt64; var block: UInt64
                           var major: Int32; var minor: Int32; var content: String }
            var media: [Media] = []
            var sawAPFS = false

            var cit: io_iterator_t = 0
            if IORegistryEntryCreateIterator(dev, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &cit) == KERN_SUCCESS {
                while case let e = IOIteratorNext(cit), e != 0 {
                    defer { IOObjectRelease(e) }
                    if IOObjectConformsTo(e, "AppleAPFSContainer") != 0 || IOObjectConformsTo(e, "AppleAPFSMedia") != 0 {
                        sawAPFS = true
                    }
                    guard IOObjectConformsTo(e, "IOMedia") != 0, let bsd = str(e, "BSD Name") else { continue }
                    let content = str(e, "Content") ?? ""
                    if content.uppercased() == apfsContainerGUID || content == "Apple_APFS" { sawAPFS = true }
                    media.append(Media(bsd: bsd, whole: (prop(e, "Whole") as? Bool) ?? false,
                                       size: u64(e, "Size") ?? 0, block: u64(e, "Preferred Block Size") ?? 0,
                                       major: Int32(truncatingIfNeeded: int(e, "BSD Major") ?? -1),
                                       minor: Int32(truncatingIfNeeded: int(e, "BSD Minor") ?? -1),
                                       content: content))
                }
                IOObjectRelease(cit)
            }

            let wholes = media.filter(\.whole)
            guard !wholes.isEmpty else { continue }

            let disks: [DiskInfo] = wholes.map { w in
                let parts = media.filter { !$0.whole && partition($0.bsd, belongsTo: w.bsd) }
                    .map { PartitionInfo(bsdName: $0.bsd, content: $0.content, size: $0.size,
                                         mountPoint: mounts["/dev/" + $0.bsd]) }
                    .sorted { $0.bsdName < $1.bsdName }
                let da = diskArbitrationInfo(w.bsd)
                return DiskInfo(bsdName: w.bsd, size: w.size, preferredBlockSize: w.block,
                                bsdMajor: w.major, bsdMinor: w.minor, content: w.content,
                                partitions: parts, containsAPFS: sawAPFS,
                                isInternal: da.internal, deviceProtocol: da.proto)
            }

            out.append(USBStorageDevice(
                vendorID: int(dev, "idVendor") ?? 0,
                productID: int(dev, "idProduct") ?? 0,
                bcdDevice: int(dev, "bcdDevice") ?? 0,
                serial: str(dev, "USB Serial Number") ?? str(dev, "kUSBSerialNumberString"),
                manufacturer: str(dev, "kUSBVendorString") ?? str(dev, "USB Vendor Name"),
                product: str(dev, "USB Product Name") ?? str(dev, "kUSBProductString"),
                locationID: int(dev, "locationID") ?? 0,
                disks: disks))
        }
        return out
    }

    /// "/dev/disk6s1" -> "/Volumes/SAMSUNG USB"
    public static func mountTable() -> [String: String] {
        var p: UnsafeMutablePointer<statfs>?
        let n = getmntinfo(&p, MNT_NOWAIT)
        guard n > 0, let p else { return [:] }
        var m: [String: String] = [:]
        for i in 0..<Int(n) {
            let s = p[i]
            let from = withUnsafeBytes(of: s.f_mntfromname) { String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self)) }
            let on = withUnsafeBytes(of: s.f_mntonname) { String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self)) }
            m[from] = on
        }
        return m
    }

    static func diskArbitrationInfo(_ bsd: String) -> (internal: Bool?, proto: String?) {
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsd),
              let desc = DADiskCopyDescription(disk) as NSDictionary?
        else { return (nil, nil) }
        let isInternal = desc[kDADiskDescriptionDeviceInternalKey as String] as? Bool
        let proto = desc[kDADiskDescriptionDeviceProtocolKey as String] as? String
        return (isInternal, proto)
    }

    // MARK: IORegistry helpers

    static func prop(_ e: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(e, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
    static func int(_ e: io_registry_entry_t, _ key: String) -> Int? { (prop(e, key) as? NSNumber)?.intValue }
    static func u64(_ e: io_registry_entry_t, _ key: String) -> UInt64? { (prop(e, key) as? NSNumber)?.uint64Value }
    static func str(_ e: io_registry_entry_t, _ key: String) -> String? { prop(e, key) as? String }
}
