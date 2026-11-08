# flashprobe safety model

## Vendor-command allowlist

**Current allowlist: empty.**

A command may be added only if at least one independent source documents it as read-only, with exact bytes, and the source is cited here. No Silicon Motion SM32xx private command meets that bar (see `research.md` §3), so `vendor-id` and `health` refuse to run. This is deliberate. The only public trace (`F0 04 …`, recorded on an SM3257) is classed as unknown and is not sent.

When Phase 1–3 code exists, every vendor CDB will go through one function that:
1. looks the exact opcode and sub-opcode up in this list (no list entry means no send),
2. defaults to `--dry-run` (it prints the CBW and CDB bytes and sends nothing) until `--execute` is given,
3. requires `--i-have-a-backup`,
4. allows data-in or no-data transfers only, never data-out.

| Opcode / CDB | Purpose | Data dir | Source proving read-only |
|---|---|---|---|
| *(none)* | | | |

## Picking the drive

- The drive is chosen **by exact USB serial** (`--serial`). Disk numbers are never accepted as input.
- The tool refuses when:
  - no device or more than one device has that serial,
  - the device has more than one whole disk,
  - any APFS container is present,
  - DiskArbitration reports the disk as internal (or can't say),
  - the protocol is not USB.
- After `/dev/rdiskN` is opened, the opened node's `dev_t` must equal the BSD major/minor that IOKit reported for the serial-matched media. This catches disk numbers changing between lookup and open.

## What writes, and what doesn't

| Command | Opens | Writes? |
|---|---|---|
| `list` | IOKit registry only | no |
| `scan` | `/dev/rdiskN` with `O_RDONLY` | **no**: there is no code path that opens a disk node writable |
| `files` | each file on the mounted volume, `O_RDONLY` | **no** |
| `scan --compare-fresh` | the mounted volume | **yes, one new temp file only**: created with `O_EXCL` in free space, after you type `write`; refused without an interactive terminal or with less than size + max(1 GiB, 5 % of free space) available; read back, SHA-256 checked, then deleted (also on Ctrl-C) |
| `inspect`, `vendor-id`, `health` | nothing | no (not built / no-go) |

`compare-fresh` never modifies existing files; it only reads them.

## Interrupts

Ctrl-C, SIGTERM and SIGHUP finish the current read, save partial results and delete the temp file. A second Ctrl-C exits at once, deleting the temp file first.
