# flashprobe — Phase 0 research

Date: 2026-11-07. Nothing in this phase sent any command to the drive. The only data read from it came from the macOS IOKit registry (`system_profiler`, `ioreg`, `diskutil list`), which only reports descriptors the OS already cached when the drive was plugged in.

---

## 1. The target drive (observed on this machine)

| Field | Value | Source |
|---|---|---|
| Product string | `Type-C` (manufacturer `Samsung`) | ioreg |
| VID / PID / bcdDevice | `0x090c` / `0x1000` / `0x1100` | ioreg |
| USB serial | (redacted, 16 digits) | ioreg — **use this to pick the drive** |
| bcdUSB | `0x0310` | ioreg |
| Configurations | 1 | ioreg |
| Interfaces | **1**: #0, alt 0, class `0x08` / subclass `0x06` (SCSI transparent) / protocol **`0x50` (Bulk-Only Transport)**, 2 endpoints | ioreg |
| UAS (`0x62`) alternate setting | **None.** There is no second alt setting. | ioreg |
| macOS driver stack | `IOUSBMassStorageDriver` → `IOSCSIPeripheralDeviceType00` → `IOBlockStorageDriver` → IOMedia | ioreg |
| BSD node | `disk6` today, MBR, one partition `disk6s1` (type 0x07, shown as "Windows_NTFS"; exFAT uses the same MBR type) | diskutil |
| Other client | An `AppleUSBHostDeviceUserClient` owned by **Google Chrome** is open on the device | ioreg |

Implications:
- **BOT only, no UAS.** That makes the libusb route simpler, since we only need to implement BOT (CBW/CSW).
- Chrome has the device open (probably WebUSB/device enumeration). That could interfere with getting exclusive access in Phase 1. Quit Chrome before detaching.

## 2. Which controller is this?

**Short answer: most likely a Silicon Motion SM3281-family controller with Samsung-customised firmware. The VID/PID cannot confirm it, and the usual identification tools fail on this exact drive family.**

Evidence:
- `090C:1000` with revision `1100` is Silicon Motion's **generic default** VID/PID. It shows up on SM3255, SM3257EN*, SM3259, SM3267 and SM3281 drives, so it identifies the vendor only, not the part. Examples on usbdev.ru: an SP Mobile X20 (SM3257ENLTAA, 090C:1000, rev 1100) and an SP 8GB (SM3259AA1, 090C:1000, rev 1100) [S1]. FlashBoot's iFlash database also lists SM3281 drives under 090C:1000 [S2].
- **A closely matching case:** a usbdev.ru thread on a *Samsung Flash Drive FIT 128 GB* with the same `090C:1000`, rev `1100`, manufacturer `Samsung`, and a 16-digit serial in the same `037…` format as yours (`0374119070018039`). Both **Flash Drive Information Extractor and ChipGenius returned "Controller: Unknown" and no Flash ID**. A senior forum member answered that Samsung's Bar Plus uses an **SM3281**, and suggested a recent SMI MPTool for identification, with the explicit warning to stay away from the Start button [S3].
- Newer Samsung Type-C / Bar Plus units (MUF-256DA/AM, MUF-256BE4/AM, 2025) enumerate as **`04E8:6300` rev `1100`**, and Gough Lui notes that the two models share identifiers [S4]. Your drive keeps the SMI default VID, so it is an **older production batch**. That fits SM3281 more than the SM3282 (an SMI USB-SSD-on-a-chip from 2019 [S5]).

**How existing tools identify SMI parts:**
- *ChipGenius* and *Flash Drive Information Extractor (FDIE)* send undocumented SMI vendor SCSI commands. They report controller part (e.g. `SM3267AB`), ISP firmware string (e.g. `ISP 140214-1AB`), flash ID per CE/channel, and MPTool version [S1].
- *SMI MPTool* shows the most data: per-channel flash ID table, ISP/PTEST versions and checksums, `ForceFlash.set` index, IC version, total LBA [S1]. **It is a mass-production flasher**, and its main function is to rewrite firmware and low-level format.
- None of these tools is open source, and none publishes its command bytes.

**Conclusion for this drive:** even the tools that do use SMI vendor commands get nothing back from Samsung's firmware on this family. The firmware either blocks or changes the SMI vendor query path.

## 3. Silicon Motion private (vendor) commands — inventory

I looked for documentation of any SMI USB-controller vendor command in: usbdev.ru (articles, forum, file pages), flashboot.ru, GitHub (veryflashy, warewolf gists, ssd-flash-id, iTXTech fdfdb/FlashDetector), hddguru, and smartmontools.

### 3a. Read-only (documented by ≥1 independent source)

**None found.**

No source I found gives the command bytes, the meaning, and evidence of read-only behaviour for any SM32xx vendor command. **The allowlist for Phases 3–4 is therefore empty.**

### 3b. Seen in the wild, semantics undocumented → **UNKNOWN, forbidden**

| CDB (hex) | Where seen | What's known | Why not allowlisted |
|---|---|---|---|
| `F0 04 00 00 00 00 00 00 00 00 00 01`, 525-byte data-in | warewolf's "SMI USB flash drive controller identification" gist [S6] | On an SM3257ENLTAA it returned a firmware date (`2010-10-26`), the strings `SM3257ENLTAA` and `SMI32X`, and then what looks like **8051 firmware code**. The `USBS` CSW signature shows up *inside* the data buffer, and the host saw `DID_TIME_OUT`. | One raw trace, no explanation of the opcode or subcommand. The transfer length was wrong (the CSW leaked into the data phase), and it timed out. Behaviour on SM3281/Samsung firmware is unknown. It may also be a code-memory read path that sits next to write paths in the same `F0` family. |
| Other `F0`-family and `F1`… vendor CDBs used by ChipGenius / FDIE / MPTool | Inferred from tool output [S1] | These tools obviously send *something* to get flash ID and firmware strings | Bytes not published. Getting them would mean reverse-engineering Windows binaries or USB-sniffing MPTool, and MPTool's code paths include firmware download and low-level format. |

### 3c. State-changing → **forbidden** (known to exist, bytes not needed)

From MPTool's documented function [S1, S7]: firmware/ISP download, PTEST (pre-test, which scans and **erases** blocks), low-level format, change VID/PID/serial/strings ("we'll cover how to fake some of these SMI identifiers" [S1]), switch to ROM/factory mode, and set read-only/write-protect. All of these are done with vendor commands in the same opcode space as the identification commands. That is why guessing neighbouring opcodes is dangerous, and why the veryflashy author warns that even "read-only" undocumented commands could corrupt or brick a drive [S8].

### 3d. Health data (erase counts, spare/bad blocks, ECC / read-retry counters)

**Nothing documented for SM32xx USB controllers.** MPTool's *test* results show bad-block counts per CE, but it gets them by running a destructive scan, not by reading a counter. No public tool reads wear or ECC statistics from an SMI flash *drive* (as opposed to SMI *SSD* controllers, which expose SMART over SATA/NVMe; see smartmontools' "Silicon Motion based SSDs" entries [S9]). smartmontools has **no entry for VID 0x090c** among its 231 USB bridge entries, because SM32xx flash drives aren't SAT bridges and don't expose ATA SMART.

## 4. How macOS can send raw SCSI to this drive

### 4a. Normal passthrough is blocked: **confirmed**
Apple QA1179 says that for peripheral device type `0x00` (direct-access block devices) Apple's in-kernel driver owns the device and **no `SCSITaskDeviceInterface` user client is provided**. The stated reason is that apps must not bypass file-system permissions by sending commands directly. The supported user-space route is the raw BSD node `/dev/rdiskN` for block I/O only [S10]. The ioreg tree confirms the drive is driven by `IOSCSIPeripheralDeviceType00`.

### 4b. libusb + detach + our own BOT: **workable, needs root**
- libusb's Darwin backend implements `libusb_detach_kernel_driver` (added in libusb 1.0.25, "macOS: implement kernel driver detach" #911). It needs **effective UID 0** *or* the **`com.apple.vm.device-access`** entitlement (plus `IOServiceAuthorize`). Otherwise it returns `LIBUSB_ERROR_ACCESS` [S11, S12, S13].
- `com.apple.vm.device-access` is meant for VM USB capture apps and requires Apple approval, so it isn't realistic for a personal CLI. **Use `sudo`.** SIP does not need to be disabled.
- When we detach, macOS tears down the whole mass-storage stack. Volumes go away (unmount them first so the detach is clean), and `/dev/diskN` disappears until we release the device. Re-attach with `libusb_attach_kernel_driver` or a re-enumerate. **Phase 5 cannot run while the device is captured. That's fine, because Phase 5 doesn't need capture.**
- **What we implement ourselves (USB Mass Storage Class BOT 1.0):**
  - CBW: 31 bytes, signature `0x43425355` ("USBC"), tag, data-transfer length, flags (bit 7 = data-in), LUN, CB length 1–16, CDB.
  - CSW: 13 bytes, signature `0x53425355` ("USBS"), tag (must match the CBW), residue, status (0 pass / 1 fail → REQUEST SENSE / 2 phase error → reset recovery).
  - Class requests: Get Max LUN (`0xFE`), Bulk-Only Mass Storage Reset (`0xFF`).
  - Reset recovery = BOMS Reset, then CLEAR_FEATURE(ENDPOINT_HALT) on bulk-in and on bulk-out.
  - Handle a STALL on the data phase by clearing the halt and then reading the CSW. Validate signature, tag and length on every CSW. The warewolf trace in §3b, where the CSW turned up inside the data buffer, is exactly the bug this protects against.
- Cleanup on exit and on SIGINT/SIGTERM: release interface → `libusb_attach_kernel_driver` → close. If re-attach fails, fall back to `libusb_reset_device`, and as a last resort tell the user to re-plug.

### 4c. DriverKit — the "proper" long-term route
SCSIPeripheralsDriverKit (DriverKit 22+, i.e. macOS 13+) provides `IOUserSCSIPeripheralDeviceType00`. Its **`UserSendCDB`** "sends a vendor-specific CDB to the device" [S14], so vendor CDBs could be sent *without* tearing down the storage stack. Costs: it needs a system extension, the `com.apple.developer.driverkit.*` entitlements (Apple-granted; development signing works locally only with SIP/AMFI relaxed or a provisioning profile), a host app to install it, and user approval in System Settings. **That's too much for a one-drive diagnostic, and there's no allowlisted vendor command to send anyway.** Not recommended now.

## 5. What the speed-map route can tell you (Phase 5)
This needs no private commands. Reading `/dev/rdiskN` needs `sudo` (or read access to the node) and works with the normal driver attached. Your theory is that charge has leaked from old cells, so the controller retries and adjusts read voltages and LDPC/BCH decoding works harder on old data. That predicts:
- **Fresh data reads fast** (a few hundred MB/s on this model) **and old data reads slowly**. That points to data aging/retention loss, not worn-out blocks. `--compare-fresh` tests this directly.
- Slow areas that line up with *when* data was written (file extents), not with fixed physical positions.
- Re-reading the same slow area is about as slow every time (the controller doesn't usually refresh on read for these parts, although some firmware does). If a second read is much faster, that's a sign of read-refresh or caching.

This is the most direct evidence you can get for your actual question, and it works whatever the firmware does.

## 6. Go / no-go

| Phase | Verdict | Reason |
|---|---|---|
| 1 — libusb + BOT transport | **GO** | Single BOT interface, no UAS. libusb detach works as root. Low risk if done carefully. |
| 2 — standard SCSI (INQUIRY/VPD, READ CAPACITY(16), MODE SENSE, REQUEST SENSE) | **GO** | Standard SPC/SBC commands. Note: macOS already does INQUIRY/READ CAPACITY, so the gain over `diskutil info` is VPD pages and raw bytes. ATA PASS-THROUGH (`0xA1`/`0x85`) is a standard opcode, and a non-SAT device should answer ILLEGAL REQUEST. I'd send it once as planned, but it carries the small risk that any opcode a vendor firmware doesn't recognise carries. |
| 3 — SMI private identification | **NO-GO** | No vendor command meets your rule (documented read-only by ≥1 independent source). The one public trace (`F0 04…`) has undocumented semantics, misbehaved, and was recorded on a different controller. Also, ChipGenius and FDIE, which *do* use these commands, return nothing on this Samsung family [S3]. The allowlist stays **empty**. The code will keep the allowlist mechanism, `--dry-run`, and `--i-have-a-backup` gates so a command could be added later with evidence. |
| 4 — health data | **NO-GO / skip** | No documented read-only wear/ECC/bad-block command exists for SM32xx flash drives. |
| 5 — speed map + `--compare-fresh` | **GO, and do it first** | Answers the real question (aging vs wear) with zero firmware risk, and doesn't need Phase 1. |

**Overall recommendation:** build the project, but **reorder it as 5 → 1 → 2** and leave Phases 3–4 as documented stubs. Phase 5 alone will very likely settle your hypothesis. If it confirms aging, the practical fix is to copy everything off, then copy it back (or reformat and restore). Rewriting the data recharges the cells. Then you can treat the drive as a cold-storage risk.

If you still want controller/NAND IDs later, the only evidence-based path is: get a **spare drive of the same model**, capture USB traffic from a Windows machine (USBPcap/Wireshark) while FDIE or ChipGenius identifies it (not MPTool), check that the trace contains only data-in commands, and add exactly those CDBs to the allowlist with the capture as the cited source. Given [S3], expect it to return "Unknown" here as well.

---

## Sources
- [S1] usbdev.ru, "Получение максимум служебных данных о флешке на контроллере SMI" — https://www.usbdev.ru/articles/a_smi/smidriveinfo/
- [S2] FlashBoot.ru iFlash database — https://flashboot.ru/iflash/page10//1000
- [S3] usbdev.ru forum, "Samsung Flash Drive FIT 128 G / SM3281 + no FID" (2019) — https://www.usbdev.ru/f/index.php?topic=4277.0
- [S4] Gough Lui, Review: Samsung 256GB Bar Plus & USB Type-C (MUF-256DA/AM), 2025 — https://goughlui.com/2025/11/29/review-samsung-256gb-bar-plus-muf-256be4-am-usb-type-c-flash-drive-muf-256da-am/
- [S5] CNX Software, Silicon Motion SM3282 — https://www.cnx-software.com/2019/06/03/silicon-motion-sm3282-single-chip-solution-portable-usb-ssd-sticks/
- [S6] warewolf, "SMI USB flash drive controller identification page" (gist) — https://gist.github.com/warewolf/c185d17008dd1639138f
- [S7] usbdev.ru, SMI MPTool SM32X/SM34X file page — https://www.usbdev.ru/files/smi/smimptool/
- [S8] dlenski/veryflashy (README warning; no SMI support) — https://github.com/dlenski/veryflashy
- [S9] smartmontools drivedb.h — https://github.com/smartmontools/smartmontools/blob/master/smartmontools/drivedb.h
- [S10] Apple Technical Q&A QA1179, "Sending SCSI or ATA commands to storage devices" — https://developer.apple.com/library/archive/qa/qa1179/_index.html
- [S11] libusb Darwin: detach error message commit — https://flutter.googlesource.com/third_party/libusb/+/993b28c400b97e65fc1c457f112e2a9c2fd1d912
- [S12] Apple, `com.apple.vm.device-access` entitlement — https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.vm.device-access
- [S13] QEMU issue #1951, "MacOS requires root to pass through USB devices properly" — https://gitlab.com/qemu-project/qemu/-/issues/1951
- [S14] Apple, `IOUserSCSIPeripheralDeviceType00` / `UserSendCDB` — https://developer.apple.com/documentation/scsiperipheralsdriverkit/iouserscsiperipheraldevicetype00
