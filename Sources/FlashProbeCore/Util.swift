import Foundation
import Darwin

// MARK: - Errors

public enum FlashProbeError: Error, CustomStringConvertible, Equatable {
    case iokit(String, Int32)
    case posix(String, Int32)
    case needsRoot(String)
    case noSuchSerial(String, available: [String])
    case ambiguousSerial(String, count: Int)
    case refused(String)
    case deviceMismatch(String)
    case invalidArgument(String)
    case aborted(String)

    public var description: String {
        switch self {
        case let .iokit(what, kr):
            return "\(what) failed (IOKit 0x\(String(UInt32(bitPattern: kr), radix: 16)))"
        case let .posix(what, e):
            return "\(what): \(String(cString: strerror(e))) (errno \(e))"
        case let .needsRoot(path):
            return "Permission denied opening \(path). Raw device reads need root: re-run with sudo."
        case let .noSuchSerial(s, available):
            let list = available.isEmpty ? "none" : available.joined(separator: ", ")
            return "No USB storage device has serial \"\(s)\". Serials present: \(list). Run `flashprobe list`."
        case let .ambiguousSerial(s, n):
            return "\(n) USB devices report serial \"\(s)\"; refusing to guess. Unplug the others."
        case let .refused(why):
            return "Refusing to touch this device: \(why)"
        case let .deviceMismatch(why):
            return "Device identity check failed: \(why)"
        case let .invalidArgument(why):
            return why
        case let .aborted(why):
            return "Aborted: \(why)"
        }
    }
}

// MARK: - Timing

public func monotonicSeconds() -> Double {
    Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9
}

// MARK: - Interrupt handling

/// Ctrl-C / SIGTERM / SIGHUP set a flag that long loops poll, so the tool can
/// finish the current read, save partial results and clean up temp files.
/// A second signal exits immediately (after deleting registered temp files).
public final class InterruptFlag: @unchecked Sendable {
    public static let shared = InterruptFlag()

    private let lock = NSLock()
    private var _requested = false
    private var cleanupPaths: Set<String> = []
    private var sources: [DispatchSourceSignal] = []
    private var installed = false

    public var requested: Bool {
        lock.lock(); defer { lock.unlock() }
        return _requested
    }

    public func install() {
        lock.lock(); defer { lock.unlock() }
        guard !installed else { return }
        installed = true
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            src.setEventHandler { [unowned self] in self.handle() }
            src.resume()
            sources.append(src)
        }
    }

    private func handle() {
        lock.lock()
        let already = _requested
        _requested = true
        let paths = cleanupPaths
        lock.unlock()
        if already {
            for p in paths { unlink(p) }
            fputs("\nSecond interrupt: exiting now.\n", stderr)
            exit(130)
        }
        fputs("\nInterrupt received: finishing the current read, then saving partial results. Press Ctrl-C again to quit immediately.\n", stderr)
    }

    public func registerCleanup(_ path: String) {
        lock.lock(); cleanupPaths.insert(path); lock.unlock()
    }

    public func unregisterCleanup(_ path: String) {
        lock.lock(); cleanupPaths.remove(path); lock.unlock()
    }
}

// MARK: - Buffers and I/O helpers

/// Page-aligned buffer; raw-device and F_NOCACHE I/O want aligned memory.
public final class AlignedBuffer {
    public let pointer: UnsafeMutableRawPointer
    public let count: Int

    public init(count: Int, alignment: Int = 16384) {
        self.count = count
        pointer = .allocate(byteCount: count, alignment: alignment)
        pointer.initializeMemory(as: UInt8.self, repeating: 0, count: count)
    }

    deinit { pointer.deallocate() }
}

/// pread until `length` bytes, EOF, or an error. Returns bytes read, or -errno.
public func preadFully(_ fd: Int32, _ buf: UnsafeMutableRawPointer, _ length: Int, _ offset: UInt64) -> Int {
    var done = 0
    while done < length {
        let r = pread(fd, buf + done, length - done, off_t(offset) + off_t(done))
        if r < 0 {
            if errno == EINTR { continue }
            return -Int(errno)
        }
        if r == 0 { break }
        done += r
    }
    return done
}

/// Bytes per second -> MB/s (decimal, 10^6 bytes), the unit drive vendors use.
@inline(__always)
public func mbPerSecond(bytes: Int, seconds: Double) -> Double {
    seconds > 0 ? Double(bytes) / 1e6 / seconds : .infinity
}

/// When run under sudo, give output files back to the invoking user.
public func chownToSudoUser(_ path: String) {
    guard getuid() == 0,
          let uidStr = ProcessInfo.processInfo.environment["SUDO_UID"], let uid = uid_t(uidStr),
          let gidStr = ProcessInfo.processInfo.environment["SUDO_GID"], let gid = gid_t(gidStr)
    else { return }
    _ = chown(path, uid, gid)
}

// MARK: - Formatting

public enum Fmt {
    public static func bytes(_ b: UInt64) -> String {
        let d = Double(b)
        if d >= 1e12 { return String(format: "%.2f TB", d / 1e12) }
        if d >= 1e9 { return String(format: "%.1f GB", d / 1e9) }
        if d >= 1e6 { return String(format: "%.1f MB", d / 1e6) }
        if d >= 1e3 { return String(format: "%.1f kB", d / 1e3) }
        return "\(b) B"
    }

    public static func gib(_ b: UInt64) -> String {
        String(format: "%.2f GiB", Double(b) / 1_073_741_824)
    }

    public static func mbps(_ v: Double?) -> String {
        guard let v, v.isFinite else { return "n/a" }
        return v >= 100 ? String(format: "%.0f MB/s", v) : String(format: "%.1f MB/s", v)
    }

    public static func duration(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "?" }
        let t = Int(s.rounded())
        if t >= 3600 { return "\(t / 3600)h\(String(format: "%02d", (t % 3600) / 60))m" }
        if t >= 60 { return "\(t / 60)m\(String(format: "%02d", t % 60))s" }
        return "\(t)s"
    }

    public static func hex4(_ v: Int) -> String {
        String(format: "0x%04x", v)
    }
}
