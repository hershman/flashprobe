# flashprobe

A macOS command-line tool that finds out why a USB flash drive reads slowly.

Old data on cheap flash can lose charge over time. The drive then has to retry and error-correct every read, so a drive that reads fresh data at 350 MB/s may crawl at 5–30 MB/s through files written a year ago. flashprobe measures this without writing to your data:

- **`scan`** times reads across the raw device and draws a speed map (HTML heatmap, CSV, summary).
- **`files`** times each file on the volume, then groups slow files by folder and date.
- **`scan --compare-fresh`** writes one temporary file into free space and compares its read speed with your oldest files. This shows whether old data has faded or the drive is simply slow.

| Subcommand | Status |
|---|---|
| `list` | works |
| `scan` | works (read-only) |
| `files` | works (read-only) |
| `scan --compare-fresh` | works (writes one temp file, after you confirm) |
| `vendor-id`, `health` | **disabled**: no controller commands are documented as read-only ([docs/research.md](docs/research.md)) |

flashprobe picks a drive by its USB serial number, never by disk number. It refuses internal disks and APFS containers. It never opens a disk device for writing. The full rules are in [docs/safety.md](docs/safety.md).

**What to do with the results:** if old data is slow, copy it off to another drive and check the copy. Rewriting the data, for example by reformatting and copying it back, usually restores full speed. Some controllers also restore it when the data is simply read. A drive whose data fades within months has weak flash: don't keep the only copy of anything on it.

## Build

Needs Xcode or the Command Line Tools (Swift 5.9+) and macOS 13+.

```bash
swift build -c release
```

The binary is `.build/release/flashprobe`. Run the tests (no hardware needed) with:

```bash
swift test
```

## Use

### 1. Find the drive's serial (no sudo)

```bash
.build/release/flashprobe list
```

### 2. Speed map: needs `sudo`

`/dev/rdiskN` is `root:operator 0640`, so the raw read needs root. It only reads.

A quick survey first, reading every 16th chunk (about 16 GB of reads):

```bash
sudo .build/release/flashprobe scan --serial <SERIAL> --sample 16
```

Then the full map, with 3 re-reads of up to 256 slow chunks:

```bash
sudo .build/release/flashprobe scan --serial <SERIAL> --reread-slow 3
```

At 5–11 MB/s on old data a full 256 GB pass can take **5–12 hours**. Ctrl-C stops early and still writes a (partial) report.

**For cleaner numbers:**
- Quit apps that use the drive, including Chrome, which has the device open.
- Optionally unmount first with `diskutil unmountDisk diskN` (N from `flashprobe list`); raw reads work while the drive is unmounted.
- Keep the Mac awake, e.g. `caffeinate -i sudo …`.

Output goes to `flashprobe-out/<serial>-<time>/`:
- `scan.html` is the heatmap.
- `scan.csv` has one row per chunk.
- `summary.json` and `summary.txt` hold the stats and slow regions.

Files are handed back to your user, not root. [docs/example/scan.html](docs/example/scan.html) shows what the HTML looks like, built from **synthetic** data.

Useful options:
- `--chunk-mib N`: chunk size, default 4.
- `--start-gib` / `--length-gib`: scan only part of the drive.
- `--sample N`: read only every Nth chunk.
- `--reread-slow N` / `--reread-max M`: re-read up to M slow chunks N times each.
- `--slow-fraction F`: a chunk counts as slow when it reads below F × the drive's p90 speed (default 0.5).

### 3. Which files are slow: no sudo, read-only

```bash
.build/release/flashprobe files --serial <SERIAL>
```

Times an uncached read of every file of at least 4 MiB on the drive's volume, then reports:
- the slow files,
- slow data per top-level folder and per creation month,
- whether older files read fine, which tests the "aging" theory.

A file counts as slow when it reads below half the median file speed. If the typical file is itself far slower than the fastest files, the summary says so; `scan --compare-fresh` then tells whether fresh data reads fast.

Output: `files.html` (speed against date, as a scatter chart), `files.csv`, `files-summary.txt` and `files-summary.json`.

By default it reads up to 64 MiB spread across each file. Options:
- `--full`: read every byte.
- `--per-file-mib N`: change the per-file amount.
- `--min-mib N`: change the 4 MiB minimum file size.
- `--include-hidden`: also time hidden files.

Copy tools often keep the original file dates, so a file's date may be older than when it was written to this drive.

### 4. Fresh vs old data: no sudo, **writes one temp file**

```bash
.build/release/flashprobe scan --serial <SERIAL> --compare-fresh
```

What it does:
1. Shows exactly what it will do and asks you to type `write`.
2. Reads your oldest large files (by creation date).
3. Writes a 1 GiB temp file of random data into free space, reads it back uncached and checks it with SHA-256.
4. Deletes the temp file.
5. Compares fresh and old read speeds and prints a verdict.

Options:
- `--fresh-mib 8192`: write a bigger temp file, to get past the drive's SLC cache.
- `--old-file PATH`: choose which old files to read (repeatable).
- `--volume PATH`: pick the volume if the drive has several.

## What needs sudo

| Command | sudo? | Why |
|---|---|---|
| `list` | no | reads the IOKit registry only |
| `scan` | **yes** | opens `/dev/rdiskN` read-only, which needs root |
| `scan --compare-fresh` | no | ordinary file I/O on the mounted volume |
| `files` | no | ordinary read-only file I/O on the mounted volume |


## Disclaimer

flashprobe reads raw devices and, in `--compare-fresh`, writes a temporary file. It is provided as is, with no warranty. Keep a backup of any data you care about before testing a drive that is misbehaving.

## License

MIT. See [LICENSE](LICENSE).
