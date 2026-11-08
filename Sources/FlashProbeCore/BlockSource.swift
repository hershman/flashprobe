import Foundation
import Darwin

/// Something the scanner can read from. Deliberately has no write method.
public protocol BlockSource: AnyObject {
    var size: UInt64 { get }
    var blockSize: UInt64 { get }
    /// Read `length` bytes at `offset`. Returns bytes read, or -errno.
    func read(into buffer: UnsafeMutableRawPointer, length: Int, offset: UInt64) -> Int
}

// <sys/disk.h> ioctls; Swift can't import these function-like macros.
// _IOR('d', 24, uint32_t) and _IOR('d', 25, uint64_t).
private let DKIOCGETBLOCKSIZE: UInt = 0x4004_6418
private let DKIOCGETBLOCKCOUNT: UInt = 0x4008_6419

/// The raw character device of the serial-selected drive, opened O_RDONLY.
///
/// Identity is checked *after* opening: the opened node's dev_t must equal the
/// BSD major/minor IOKit reported for the serial-matched IOMedia. That closes
/// the race where disk numbers change between lookup and open.
public final class ReadOnlyDevice: BlockSource {
    public let path: String
    public let size: UInt64
    public let blockSize: UInt64
    private let fd: Int32

    public init(target: Target) throws {
        let path = "/dev/r" + target.disk.bsdName
        // O_RDONLY only. There is no code path in this tool that opens a disk node for writing.
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        if fd < 0 {
            let e = errno
            if e == EACCES || e == EPERM { throw FlashProbeError.needsRoot(path) }
            throw FlashProbeError.posix("open \(path)", e)
        }

        var st = stat()
        guard fstat(fd, &st) == 0 else {
            let e = errno; close(fd); throw FlashProbeError.posix("fstat \(path)", e)
        }
        let major = (st.st_rdev >> 24) & 0xff
        let minor = st.st_rdev & 0xff_ffff
        guard (st.st_mode & S_IFMT) == S_IFCHR,
              major == target.disk.bsdMajor, minor == target.disk.bsdMinor else {
            close(fd)
            throw FlashProbeError.deviceMismatch(
                "\(path) is dev \(major),\(minor) but serial \(target.device.serial ?? "?") maps to " +
                "\(target.disk.bsdMajor),\(target.disk.bsdMinor). Disk numbers changed? Re-run.")
        }

        _ = fcntl(fd, F_NOCACHE, 1)

        var bs: UInt32 = 0
        var bc: UInt64 = 0
        if ioctl(fd, DKIOCGETBLOCKSIZE, &bs) == 0, ioctl(fd, DKIOCGETBLOCKCOUNT, &bc) == 0, bs > 0, bc > 0 {
            blockSize = UInt64(bs)
            size = UInt64(bs) * bc
        } else {
            blockSize = target.disk.preferredBlockSize
            size = target.disk.size
        }
        guard size == target.disk.size else {
            close(fd)
            throw FlashProbeError.deviceMismatch("\(path) size \(size) differs from IOKit size \(target.disk.size)")
        }
        self.path = path
        self.fd = fd
    }

    deinit { close(fd) }

    public func read(into buffer: UnsafeMutableRawPointer, length: Int, offset: UInt64) -> Int {
        preadFully(fd, buffer, length, offset)
    }
}

/// A regular file as a block source (tests, or scanning a disk image).
public final class FileBlockSource: BlockSource {
    public let size: UInt64
    public let blockSize: UInt64
    private let fd: Int32

    public init(path: String, blockSize: UInt64 = 512) throws {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw FlashProbeError.posix("open \(path)", errno) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { let e = errno; close(fd); throw FlashProbeError.posix("fstat", e) }
        self.fd = fd
        self.size = UInt64(st.st_size)
        self.blockSize = blockSize
    }

    deinit { close(fd) }

    public func read(into buffer: UnsafeMutableRawPointer, length: Int, offset: UInt64) -> Int {
        preadFully(fd, buffer, length, offset)
    }
}
