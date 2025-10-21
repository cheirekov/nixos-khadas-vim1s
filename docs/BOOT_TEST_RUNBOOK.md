# Khadas VIM1S (Amlogic S905Y4) — Hardware Boot Test Runbook for NixOS SD Image

Objective
- Verify that the generated SD image boots NixOS on VIM1S using:
  - Vendor 5.15.137 kernel
  - Vendor DTB with overlays pre-merged at build time
  - Neutral U‑Boot chainloader (u‑boot.ext) via extlinux
- Provide fast diagnostics and fallback commands if it doesn’t boot on first try.

Prerequisites
- Built SD image:
  - nix build -L .#vim1s-sd-image --accept-flake-config
  - Result: result/sd-image/nixos-vim1s-<date>.aarch64-linux.img(.zst)
- Flash to microSD:
  - zstdcat result/sd-image/*.img.zst | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress
- UART:
  - 921600 8N1 on ttyS0 (fallback 115200 8N1 on ttyAML0)
- Optional (raw SD first-stage):
  - Place u-boot.bin.sd.bin.signed.new next to flake.nix before build to embed a signed first-stage via dd into the image.

Where u‑boot.ext lives inside the image
- FAT boot partition (partition 1) at the root: /u-boot.ext
- Verify without mounting:
  - IMG=path/to/nixos-vim1s-*.img
  - BOOT_START=$(parted -sm "$IMG" unit B print | awk -F: '/^1:/ { sub(/B$/,"",$2); print $2 }')
  - mdir -i "$IMG@@$BOOT_START" ::/u-boot.ext
- Or loop mount:
  - sudo losetup --show -Pf "$IMG"        # -> /dev/loopX
  - sudo mount /dev/loopXp1 /mnt/boot
  - ls -l /mnt/boot/u-boot.ext
  - sudo umount /mnt/boot && sudo losetup -d /dev/loopX

Boot test steps (chainload path — recommended)
1) Power off VIM1S, insert the SD, connect UART, then power on.
2) Observe boot ROM → first-stage loader → U‑Boot.
   - Many Khadas loaders automatically look for /u-boot.ext on the FAT partition and chainload it.
3) If an extlinux menu (or direct extlinux boot) appears, this is success. Kernel should load:
   - Image + initrd from /boot/nixos/<hash>/...
   - DTB from /boot/nixos/<hash>/amlogic/kvim1s.dtb
4) If it still boots internal eMMC or does nothing automatically:
   - Interrupt to U‑Boot prompt and force SD device selection:
     - mmc list
     - mmc dev 1         # Often SD is 1; try 0 if needed
     - fatls mmc 1:1 /
   - One-shot extlinux boot (clean path):
     - sysboot mmc 1:1 any /boot/extlinux/extlinux.conf

Expected serial output (abbreviated)
- u‑boot.ext being chainloaded (implicit, no explicit message on some loaders)
- extlinux: reading /boot/extlinux/extlinux.conf
- Loading kernel/initrd/DTB from /boot/nixos/<hash>/...
- “Starting kernel ...”
- Linux console output on ttyS0 (921600), possibly ttyAML0 @ 115200

If it doesn’t boot — quick matrix
- No U‑Boot prompt, nothing on UART:
  - Try the optional signed SD first-stage:
    - Ensure u-boot.bin.sd.bin.signed.new is next to flake.nix
    - Rebuild the image; the postBuild step dd’s it into the image (MBR + remainder)
    - Flash and retry
- U‑Boot prompt present but SD not detected:
  - mmc list; try mmc dev 0 and then mmc dev 1
  - Verify FAT partition lists: fatls mmc X:1 /
- extlinux fails or “file not found”:
  - ext4ls mmc X:1 /boot /boot/extlinux
  - extlinux.conf should point to:
    - LINUX ../nixos/<hash>/linux
    - INITRD ../nixos/<hash>/initrd
    - FDT ../nixos/<hash>/amlogic/kvim1s.dtb
  - Ensure the DTB path matches installed location and closure hash
- FDT errors about overlays / rsvmem:
  - Confirm we are not using Ubuntu overlay helpers:
    - There should be NO /boot/uEnv.txt, overlay.env, or overlays runtime directories on the FAT
    - This flake compiles and merges overlays at build-time; runtime helpers are not used
  - Force one-shot clean extlinux boot:
    - sysboot mmc 1:1 any /boot/extlinux/extlinux.conf
  - Inspect overlay-related environment:
    - printenv fdt_overlays overlays overlayfs overlay_profile
    - To sanitize temporarily: setenv fdt_overlays; setenv overlays; setenv overlayfs; setenv overlay_profile
- U‑Boot warnings “u-boot has a LOAD segment with RWX permissions”:
  - Harmless for legacy vendor U‑Boot

Advanced/debug tips
- Early kernel logs:
  - In extlinux APPEND, add: earlycon=meson,uartao,0xff803000 ignore_loglevel initcall_debug
- Confirm DTB merged with overlays at build time:
  - dtc -I dtb -O dts /boot/nixos/<hash>/amlogic/kvim1s.dtb | less
- If you want to test base DT only:
  - Set overlayNames = [] in modules/vim1s.nix and rebuild; re-introduce overlays incrementally
- Force neutral chainloader (if SPI/eMMC has Ubuntu-style helpers):
  - Ensure /u-boot.ext is present on FAT and chainloaded (implicit)
  - Or manually sysboot as above

Location of artifacts in Nix store (read-only reference)
- U‑Boot chainloader packaged as:
  - ${config.system.build.ubootVim1s}/u-boot/u-boot.ext
- DTB packaged under:
  - /boot/nixos/<hash>/amlogic/kvim1s.dtb (inside the image)

After successful boot
- Re-enable NixOS kernel-config assertions in modules/vim1s.nix and iterate the .config until all checks pass.
- Optionally migrate DTB build into Kbuild (make dtbs) for consistency.
- Decide a minimal overlay set and remove unused ones.
- Capture and archive UART logs for the bring-up notes.
