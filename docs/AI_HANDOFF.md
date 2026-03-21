# Khadas VIM1S Bring-Up Handoff

Last updated
- 2026-03-21

Purpose
- Recover the current board-support state quickly in a clean AI session.
- Avoid re-deriving the same findings from UART logs, Ubuntu reference boots,
  AWS logs, and cache/bootstrap work.

Current Milestone
- NixOS 25.11 SD image boots reliably to a shell on real hardware.
- U-Boot extlinux boot path is working.
- AWS remote builds, SSM logging, and the S3 binary cache are working.
- The board now exposes:
  - `eth0`
  - `wlan0`
  - `wlan1`
  - `hci0`
- `aml_drm` is still blacklisted intentionally, so HDMI is not enabled yet.

Current Blocker
- Wi-Fi firmware loading is failing because the vendor `dhd` stack was passing
  absolute firmware paths into `request_firmware()`.
- Live board evidence showed:
  - the files exist under `/run/current-system/firmware/brcm`
  - the kernel firmware loader path is already set to the realized firmware
    closure
  - `dhd` still fails with `Direct firmware load ... failed with error -2`
- The current local fix changes:
  - `options dhd firmware_path=brcm/ nvram_path=brcm/`
- This fix is in the local working tree and needs a normal rebuild/reboot test.

What Works Right Now
- Stable headless boot to userspace.
- Root on SD image partitioning works.
- The vendor Ethernet stack now probes far enough to create `eth0`.
- Bluetooth attach service is good enough to produce a live `hci0` controller.
- Firmware compatibility derivation now builds and contains:
  - `fw_bcm43456c5_ag.bin`
  - `config_bcm43456c5_ag.txt`
  - `clm_bcm43456c5_ag.blob`
  - `nvram_ap6256.txt`
  - `BCM4345C5.hcd`

What Is Still Not Done
- Verify Wi-Fi after the relative `brcm/` firmware path fix.
- Revisit Ethernet only after a cable is actually plugged in.
- Re-enable and debug HDMI only after wireless is stable.
- Make the vendor wireless stack less fragile; hot-reloading is unsafe.

Do Not Repeat
- Do not spend more time guessing Ethernet DT properties blindly.
  - The important step was loading `amlogic_mailbox` before the vendor Ethernet
    stack. That got us from endless probe defers to a real `eth0`.
- Do not re-enable `aml_drm` yet.
  - It was the original source of a vendor panic during bring-up.
- Do not hot-reload `amlogic_wireless` on the live board.
  - Manual `modprobe -r` / `modprobe` testing caused duplicate sysfs classes
    and a kernel panic.
- Do not point `dhd` at absolute `/run/current-system/firmware/...` paths.
  - This was the exact reason for the current Wi-Fi failure.
- Do not assume the older boot runbook is fully current.
  - Read this file first.

Asset Locations
- Main board log:
  - `uart-115200.log`
- Earlier reference boot / vendor boot log:
  - `uart-921600.log`
- Ubuntu reference extraction:
  - `.tmp-ubuntu-ref/`
- Main Nix board module:
  - `modules/vim1s.nix`
- Boot runbook:
  - `docs/BOOT_TEST_RUNBOOK.md`
- AWS remote build/caching notes:
  - `docs/REMOTE_BUILD_AWS.md`
- EC2 remote-build scripts:
  - `scripts/ci/build-on-builder.sh`
  - `scripts/ci/ec2-spot-build.sh`
- Local salvage/cache helper:
  - `scripts/ci/push-local-s3-cache.sh`

Known Good Reference
- Official Ubuntu/Fenix runtime is the reference for:
  - Ethernet module chain
  - Broadcom `dhd` wireless stack
  - Bluetooth over UART
  - HDMI viability
- Important lesson from Ubuntu:
  - the board support exists already
  - the hard part in NixOS is packaging and runtime wiring, not inventing new
    kernel support

Important Findings
- Firmware compat package is correct now.
  - The last AWS failure was a bad source path for
    `clm_bcm43456c5_ag.blob`.
  - Fixed by copying `brcmfmac43456-sdio.clm_blob` into the vendor filename.
- On the live board:
  - `/run/current-system/firmware/brcm/fw_bcm43456c5_ag.bin` exists
  - `/run/current-system/firmware/brcm/config_bcm43456c5_ag.txt` exists
  - `/run/current-system/firmware/brcm/clm_bcm43456c5_ag.blob` exists
  - `/etc/firmware/BCM4345C5.hcd` exists
- Also on the live board:
  - `cat /sys/module/firmware_class/parameters/path`
  - returned the realized firmware store path, not `/lib/firmware`
- Therefore the right model is:
  - keep firmware in the Nix firmware closure
  - pass relative `brcm/...` names to `dhd`
  - do not fight the kernel firmware loader with absolute paths

Strategy
1. Rebuild the current tree and verify Wi-Fi with the relative `brcm/` fix.
2. If Wi-Fi comes up, test Bluetooth behavior again and only then move to HDMI.
3. Keep HDMI last.
4. Keep using the Ubuntu BSP as the cheat sheet.
   - Prefer copying the working runtime shape over inventing local variants.

Immediate Next Commands
- Rebuild:
```bash
nix build -L .#vim1s-sd-image --accept-flake-config 2>&1 | tee build-vim1s.log
```
- Flash:
```bash
zstdcat ./result/sd-image/*.img.zst | sudo dd of=/dev/<sdcard> bs=4M conv=fsync status=progress
sync
```
- After boot:
```bash
ip -br link
iw dev
rfkill list
hciconfig -a
journalctl -b | grep -Ei 'dhd|firmware|wlan|bluetooth'
```

Fresh Session Checklist
1. Open this file first.
2. Open `docs/BOOT_TEST_RUNBOOK.md`.
3. Check `git status --short`.
4. Read the latest UART log:
```bash
rg -a -n "dhd|eth0|wlan|hci0|firmware|bluetooth|panic|Oops" uart-115200.log | tail -n 200
```
5. If the board is live, use UART instead of guessing from old logs.

Paste-Ready Prompt For A Clean AI Session
```text
Read docs/AI_HANDOFF.md first, then docs/BOOT_TEST_RUNBOOK.md.

This repository is bringing up NixOS on Khadas VIM1S using the vendor 5.15 BSP.
Current state: board boots, eth0 exists, wlan0/wlan1/hci0 exist, HDMI is still
disabled, and the latest local untested fix in modules/vim1s.nix changes dhd
from absolute /run/current-system/firmware/brcm paths to relative brcm/ paths.

Do not re-derive old boot issues. Do not re-enable aml_drm yet. Do not hot-reload
amlogic_wireless. Start from the current handoff state, inspect git diff, inspect
uart-115200.log, and continue from there.
```
