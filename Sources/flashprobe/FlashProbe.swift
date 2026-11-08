import ArgumentParser
import Foundation
import FlashProbeCore

@main
struct FlashProbe: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "flashprobe",
        abstract: "Find out why a USB flash drive reads slowly: speed maps, per-file timing, fresh vs old data (macOS).",
        version: flashprobeVersion,
        subcommands: [List.self, Scan.self, Files.self, Inspect.self, VendorID.self, Health.self])
}

// MARK: - files

struct Files: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Time an uncached read of every file on the drive's volume (read-only; no sudo).",
        discussion: """
        Ties slow areas to actual files and their dates. Files are opened read-only and nothing is
        written. By default up to 64 MiB per file is read, spread evenly across the file; --full
        reads every byte (slow files at ~7 MB/s take about 2.5 minutes per GB).
        """)

    @Option(help: "USB serial number of the drive (see `flashprobe list`). Required.")
    var serial: String

    @Option(help: "Mount point of the drive's volume (default: its only mounted volume).")
    var volume: String?

    @Option(name: .customLong("per-file-mib"), help: "Read at most this many MiB per file, spread across it.")
    var perFileMiB: Int = 64

    @Flag(help: "Read every byte of every file instead of sampling.")
    var full = false

    @Option(name: .customLong("min-mib"), help: "Skip timing files smaller than this many MiB (0 = time every file).")
    var minMiB: Int = 4

    @Flag(name: .customLong("include-hidden"), help: "Also time hidden files and folders.")
    var includeHidden = false

    @Option(help: "Output directory (default ./flashprobe-out/<serial>-files-<time>).")
    var out: String?

    func validate() throws {
        guard perFileMiB >= 4 else { throw ValidationError("--per-file-mib must be ≥ 4") }
        guard minMiB >= 0 else { throw ValidationError("--min-mib must be ≥ 0") }
    }

    func run() throws {
        InterruptFlag.shared.install()
        let target = try DeviceLocator.resolveTarget(serial: serial)
        let vol = try volume ?? CompareFresh.defaultVolume(target: target)
        let (root, _) = try CompareFresh.checkVolume(vol, target: target, requireWritable: false)

        var opts = FileSweepOptions()
        opts.perFileBudget = full ? nil : UInt64(perFileMiB) << 20
        opts.minSize = max(1, UInt64(minMiB) << 20)
        opts.includeHidden = includeHidden

        fputs("Listing files on \(root)…\n", stderr)
        let files = FileSweep.enumerate(root: URL(fileURLWithPath: root), options: opts)
        let timed = files.filter { $0.size >= opts.minSize }.count
        fputs("\(files.count) files, \(timed) of them to time. Reading read-only, uncached. Ctrl-C stops and saves partial results.\n", stderr)

        let isTTY = isatty(STDERR_FILENO) != 0
        var last = 0.0
        let result = FileSweep.run(files: files, options: opts) { p in
            let now = monotonicSeconds()
            guard now - last >= (isTTY ? 0.5 : 30) else { return }
            last = now
            let rate = p.elapsed > 0 ? Double(p.bytesDone) / p.elapsed : 0
            let eta = rate > 0 ? Double(p.bytesTotal - p.bytesDone) / rate : .nan
            var name = p.current
            if name.count > 50 { name = "…" + name.suffix(49) }
            let line = String(format: "[%d/%d] %@ / %@  ETA %@  %@", p.filesDone, p.filesTotal, Fmt.bytes(p.bytesDone),
                              Fmt.bytes(p.bytesTotal), Fmt.duration(eta), name)
            if isTTY { fputs("\r\u{1B}[2K" + line, stderr) } else { fputs(line + "\n", stderr) }
        }
        if isTTY { fputs("\n", stderr) }

        let summary = FileSweep.summarize(files: result.files,
                                          device: DeviceSummary(target: target, blockSize: target.disk.preferredBlockSize),
                                          volume: root, options: opts, interrupted: result.interrupted, elapsed: result.elapsed)
        let dir = try makeOutDir(out: out, serial: serial, tag: "files")
        let paths = ["files.csv", "files-summary.json", "files.html", "files-summary.txt"].map { (dir as NSString).appendingPathComponent($0) }
        let text = FileSweep.text(summary)
        try FileSweep.csv(result.files).write(toFile: paths[0], atomically: true, encoding: .utf8)
        try summary.jsonData().write(to: URL(fileURLWithPath: paths[1]))
        try FilesHTML.render(summary: summary, files: result.files).write(toFile: paths[2], atomically: true, encoding: .utf8)
        try (text + "\n").write(toFile: paths[3], atomically: true, encoding: .utf8)
        for p in [dir] + paths { chownToSudoUser(p) }
        print(text)
        print("\nWrote:\n" + paths.map { "  " + $0 }.joined(separator: "\n"))
        if result.interrupted { throw ExitCode(130) }
    }
}

func makeOutDir(out: String?, serial: String, tag: String? = nil) throws -> String {
    let dir: String
    if let out { dir = out } else {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; f.locale = Locale(identifier: "en_US_POSIX")
        let safeSerial = serial.filter { $0.isLetter || $0.isNumber }
        dir = "flashprobe-out/\(safeSerial)-\(tag.map { $0 + "-" } ?? "")\(f.string(from: Date()))"
    }
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    if out == nil { chownToSudoUser("flashprobe-out") }
    return (dir as NSString).standardizingPath
}

// MARK: - list

struct List: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List USB storage devices with VID/PID, serial and their /dev/disk nodes. Needs no root.")

    @Flag(help: "Print JSON instead of text.")
    var json = false

    func run() throws {
        let devices = try DeviceLocator.usbStorageDevices()
        if json {
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try enc.encode(devices), as: UTF8.self))
            return
        }
        if devices.isEmpty { print("No USB storage devices found."); return }
        for d in devices {
            print("\(d.manufacturer ?? "?") \(d.product ?? "?")")
            print("  VID:PID \(Fmt.hex4(d.vendorID)):\(Fmt.hex4(d.productID))  rev \(Fmt.hex4(d.bcdDevice))  location 0x\(String(d.locationID, radix: 16))")
            print("  serial  \(d.serial ?? "(none — cannot be targeted)")")
            for disk in d.disks {
                let flags = [
                    disk.isInternal == false ? "external" : "INTERNAL/unknown",
                    disk.deviceProtocol ?? "protocol?",
                    disk.containsAPFS ? "APFS (refused)" : nil,
                ].compactMap { $0 }.joined(separator: ", ")
                print("  /dev/\(disk.bsdName)  \(Fmt.bytes(disk.size))  block \(disk.preferredBlockSize)  \(disk.content)  [\(flags)]")
                for p in disk.partitions {
                    print("    \(p.bsdName)  \(Fmt.bytes(p.size))  \(p.content)  \(p.mountPoint.map { "mounted at \($0)" } ?? "not mounted")")
                }
                if let s = d.serial {
                    do { _ = try DeviceLocator.selectTarget(serial: s, from: devices); print("  → can be targeted with --serial \(s)") }
                    catch { print("  → not targetable: \(error)") }
                }
            }
            print("")
        }
    }
}

// MARK: - scan

struct Scan: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Time reads across the whole raw device and draw a speed map (read-only; needs sudo).",
        discussion: """
        Default mode only opens /dev/rdiskN read-only. Close apps using the drive for cleaner numbers;
        unmounting (diskutil unmountDisk) is optional but avoids interference from Spotlight etc.

        --compare-fresh is the only mode that writes: one temporary file in the volume's free space,
        after you type 'write' to confirm. It is deleted afterwards. It does not need sudo.
        """)

    @Option(help: "USB serial number of the drive (see `flashprobe list`). Required.")
    var serial: String

    @Option(name: .customLong("chunk-mib"), help: "Chunk size in MiB.")
    var chunkMiB: Int = 4

    @Option(name: .customLong("start-gib"), help: "Start offset in GiB.")
    var startGiB: Double = 0

    @Option(name: .customLong("length-gib"), help: "Only scan this many GiB (default: to the end).")
    var lengthGiB: Double?

    @Option(help: "Read only every Nth chunk, for a quick survey (1 = every chunk).")
    var sample: Int = 1

    @Option(name: .customLong("reread-slow"), help: "After the pass, re-read each slow chunk N times (0 = off; try 3).")
    var rereadSlow: Int = 0

    @Option(name: .customLong("reread-max"), help: "Re-read at most this many slow chunks, spread across the drive.")
    var rereadMax: Int = 256

    @Option(name: .customLong("slow-fraction"), help: "A chunk is slow below this fraction of the drive's p90 speed.")
    var slowFraction: Double = 0.5

    @Option(help: "Output directory (default ./flashprobe-out/<serial>-<time>).")
    var out: String?

    @Flag(name: .customLong("compare-fresh"), help: "Write a temp file, read it back, and compare with reads of old files.")
    var compareFresh = false

    @Option(help: "compare-fresh: mount point of the drive's volume (default: its only mounted volume).")
    var volume: String?

    @Option(name: .customLong("fresh-mib"), help: "compare-fresh: size of the temporary file in MiB.")
    var freshMiB: Int = 1024

    @Option(name: .customLong("old-mib"), help: "compare-fresh: how many MiB of the oldest files to read.")
    var oldMiB: Int = 1024

    @Option(name: .customLong("old-file"), help: "compare-fresh: a specific old file to read (repeatable).")
    var oldFile: [String] = []

    func validate() throws {
        guard (1...256).contains(chunkMiB) else { throw ValidationError("--chunk-mib must be 1…256") }
        guard sample >= 1 else { throw ValidationError("--sample must be ≥ 1") }
        guard (0...20).contains(rereadSlow) else { throw ValidationError("--reread-slow must be 0…20") }
        guard rereadMax >= 1 else { throw ValidationError("--reread-max must be ≥ 1") }
        guard slowFraction > 0, slowFraction < 1 else { throw ValidationError("--slow-fraction must be between 0 and 1") }
        guard startGiB >= 0 else { throw ValidationError("--start-gib must be ≥ 0") }
        if let l = lengthGiB, l <= 0 { throw ValidationError("--length-gib must be > 0") }
        guard freshMiB >= 64 else { throw ValidationError("--fresh-mib must be ≥ 64") }
    }

    func run() throws {
        InterruptFlag.shared.install()
        let target = try DeviceLocator.resolveTarget(serial: serial)
        let d = target.device
        fputs("Target: \(d.manufacturer ?? "?") \(d.product ?? "?") \(Fmt.hex4(d.vendorID)):\(Fmt.hex4(d.productID)) serial \(d.serial ?? "?") -> /dev/\(target.disk.bsdName) (\(Fmt.bytes(target.disk.size)))\n", stderr)

        if compareFresh { try runCompareFresh(target); return }

        let dev = try ReadOnlyDevice(target: target)
        let outDir = try makeOutDir(out: out, serial: serial)
        let plan = try ScanPlan(deviceSize: dev.size, blockSize: dev.blockSize,
                                chunkSize: UInt64(chunkMiB) << 20,
                                start: UInt64(startGiB * 1_073_741_824),
                                length: lengthGiB.map { UInt64($0 * 1_073_741_824) },
                                sampleEvery: sample)
        let options = ScanOptions(rereadCount: rereadSlow, rereadMax: rereadMax, slowFraction: slowFraction)
        let planned = plan.chunks.count
        fputs("Reading \(dev.path) read-only: \(planned) chunks of \(chunkMiB) MiB, \(Fmt.gib(plan.start))–\(Fmt.gib(plan.end)). Ctrl-C stops and saves partial results.\n", stderr)

        let printer = ProgressPrinter()
        let outcome = Scanner(source: dev, plan: plan, options: options).run(progress: printer.update)
        printer.finish()

        let report = ScanReport.build(device: DeviceSummary(target: target, blockSize: dev.blockSize),
                                      plan: plan, outcome: outcome, options: options)
        let csv = (outDir as NSString).appendingPathComponent("scan.csv")
        let json = (outDir as NSString).appendingPathComponent("summary.json")
        let html = (outDir as NSString).appendingPathComponent("scan.html")
        let txt = (outDir as NSString).appendingPathComponent("summary.txt")
        let summary = TextSummary.render(report)
        try CSVReport.render(outcome.results).write(toFile: csv, atomically: true, encoding: .utf8)
        try report.jsonData().write(to: URL(fileURLWithPath: json))
        try HTMLReport.render(report: report, results: outcome.results).write(toFile: html, atomically: true, encoding: .utf8)
        try (summary + "\n").write(toFile: txt, atomically: true, encoding: .utf8)
        for p in [outDir, csv, json, html, txt] { chownToSudoUser(p) }

        print(summary)
        print("\nWrote:\n  \(html)\n  \(csv)\n  \(json)\n  \(txt)")
        if outcome.interrupted { throw ExitCode(130) }
    }

    private func runCompareFresh(_ target: Target) throws {
        let vol = try volume ?? CompareFresh.defaultVolume(target: target)
        var opts = CompareFreshOptions()
        opts.freshBytes = UInt64(freshMiB) << 20
        opts.oldBytes = UInt64(oldMiB) << 20
        opts.oldFiles = oldFile
        let result = try CompareFresh.run(target: target, volume: vol, options: opts, confirm: { plan in
            print(plan)
            guard isatty(STDIN_FILENO) != 0 else {
                print("\nstdin is not a terminal; refusing to write without an interactive confirmation.")
                return false
            }
            print("\nType 'write' to go ahead, anything else to cancel: ", terminator: "")
            fflush(stdout)
            return readLine()?.trimmingCharacters(in: .whitespaces) == "write"
        })
        let outDir = try makeOutDir(out: out, serial: serial)
        let json = (outDir as NSString).appendingPathComponent("compare-fresh.json")
        try result.jsonData().write(to: URL(fileURLWithPath: json))
        chownToSudoUser(outDir); chownToSudoUser(json)

        print("")
        print("Fresh file: write \(Fmt.mbps(result.freshWriteMBps)), read-back median \(Fmt.mbps(result.freshReadMedianMBps)), integrity \(result.integrityOK ? "OK" : "FAILED")")
        print("Old files:  read median \(Fmt.mbps(result.oldReadMedianMBps)) over \(result.oldFiles.count) file(s)")
        for o in result.oldFiles.prefix(10) {
            print("  \(Fmt.mbps(o.mbps))  \(Fmt.bytes(o.size))  \(o.path)\(o.error.map { "  ERROR: \($0)" } ?? "")")
        }
        print("\nVerdict: \(result.verdict.text)")
        if freshMiB < 8192 {
            print("Note: a small fresh file may sit in the drive's fast SLC cache. If fresh reads look suspiciously fast, retry with --fresh-mib 8192.")
        }
        print("\nWrote \(json)")
    }
}

final class ProgressPrinter {
    private var lastPrint = 0.0
    private var window: [(t: Double, bytes: Int)] = []
    private let isTTY = isatty(STDERR_FILENO) != 0

    func update(_ p: ProgressInfo) {
        let now = monotonicSeconds()
        if let r = p.last, r.seconds != nil { window.append((now, r.length)) }
        window.removeAll { now - $0.t > 10 }
        guard now - lastPrint >= (isTTY ? 0.5 : 30) || p.done == p.total else { return }
        lastPrint = now
        let line: String
        switch p.phase {
        case .scan:
            let pct = Double(p.bytesDone) / Double(max(1, p.bytesTotal)) * 100
            let span = max(0.001, (window.last?.t ?? now) - (window.first?.t ?? now))
            let recent = window.count > 1 ? Double(window.dropFirst().reduce(0) { $0 + $1.bytes }) / 1e6 / span : nil
            let rate = p.elapsed > 0 ? Double(p.bytesDone) / p.elapsed : 0
            let eta = rate > 0 ? Double(p.bytesTotal - p.bytesDone) / rate : .nan
            line = String(format: "[%5.1f%%] %@ / %@  recent %@  ETA %@", pct, Fmt.bytes(p.bytesDone), Fmt.bytes(p.bytesTotal),
                          Fmt.mbps(recent), Fmt.duration(eta))
        case .reread:
            line = "[re-read] \(p.done)/\(p.total)  last \(Fmt.mbps(p.last?.rereadMBps.last))"
        }
        if isTTY { fputs("\r\u{1B}[2K" + line, stderr) } else { fputs(line + "\n", stderr) }
    }

    func finish() { if isTTY { fputs("\n", stderr) } }
}

// MARK: - Not-yet-built / no-go phases

struct Inspect: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Standard SCSI INQUIRY/VPD/capacity (planned, not built yet).", shouldDisplay: false)
    func run() throws {
        print("Not implemented yet: needs the Phase 1 USB transport. Use `flashprobe list` and `diskutil info` for now.")
        throw ExitCode(2)
    }
}

struct VendorID: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "vendor-id",
        abstract: "Silicon Motion private identification commands (disabled: no documented read-only commands).")
    func run() throws {
        print("""
        Disabled. The vendor-command allowlist is empty: no Silicon Motion private command for this
        controller is documented as read-only by any independent source (see docs/research.md §3).
        flashprobe will not send guessed or undocumented opcodes.
        """)
        throw ExitCode(2)
    }
}

struct Health: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Wear / ECC / bad-block counters (disabled: nothing documented).")
    func run() throws {
        print("""
        Not available. No read-only health command is documented for SM32xx flash-drive controllers
        (docs/research.md §3d). Use `flashprobe scan` (speed map) and `scan --compare-fresh` instead.
        """)
        throw ExitCode(2)
    }
}
