# NixOS on Khadas VIM1S (Amlogic S905Y4) — Bring-up Plan and Context

Objective
- Provide NixOS support for Khadas VIM1S (SoC: Amlogic S905Y4), producing a bootable SD card image via NixOS flakes.
- Keep the approach reproducible and upstream-aligned where possible.

Hardware/Upstream References
- Device overview: https://www.khadas.com/vim1s
- Vendor Linux kernel (5.4 / 5.15 support): https://github.com/khadas/linux/tree/khadas-vim1s-r
- Device tree source(s): kvim1s.dts in vendor tree or common drivers overlay tree(s)
- Khadas U-Boot (khadas-vims-v2019.01): https://github.com/khadas/u-boot/tree/khadas-vims-v2019.01
- U-Boot build docs: https://docs.khadas.com/products/sbc/vim1s/development/linux/build-linux-uboot
- DT overlays (Ubuntu-oriented): https://github.com/khadas/khadas-linux-kernel-dt-overlays

Constraints and Boot Strategy (Amlogic)
- Amlogic boot ROM expects a signed BL2/FIP chain; packaging U-Boot for raw SD boot is non-trivial and board-specific.
- Easiest short-term path is to leverage a U-Boot already in SPI/eMMC that supports extlinux and boots from SD (common on Khadas devices).
- Long-term plan is to provide a proper U-Boot derivation from Khadas’ u-boot tree, packaged for VIM1S, and integrate it in a safe boot flow (e.g., chainload from eMMC, or provide documented steps for SPI/eMMC flashing when desired).

Current Implementation (this flake)
- Image generator: NixOS sd-image for aarch64 (VFAT /boot + ext4 root with label NIXOS_SD).
- Kernel: nixpkgs linuxPackages_5_15 (chosen to align with vendor 5.15 DT compatibility; mainline 6.x caused DT mismatches).
- DTB: kvim1s.dtb compiled from Khadas vendor sources in-flake using dtc.
- Bootloader: generic-extlinux-compatible (expects a U-Boot on device that can read /boot/extlinux/extlinux.conf from SD).
- Root filesystem: ext4 (label NIXOS_SD), serial console on ttyAML0.

Repository Layout
- flake.nix — flake outputs (sd-image package and nixosConfigurations.vim1s).
- modules/vim1s.nix — VIM1S board module:
  - Sets boot.kernelPackages = linuxPackages_5_15
  - Enables loader.generic-extlinux-compatible
  - Builds kvim1s.dtb from vendor sources and installs it under /boot/dtbs
  - Adds common initrd modules for G12/SM1 family
  - Enables SSH + NetworkManager, creates default users
- (Planned) modules/uboot-vim1s.nix — U-Boot derivation & packaging (see Next Steps).

Build Requirements
- Nix installed.
- Build on aarch64 host (native) or on x86_64 with user-mode emulation.
- For x86_64 hosts:
  - Debian/Ubuntu:
    - sudo apt update
    - sudo apt install -y qemu-user-static binfmt-support
    - sudo update-binfmts --enable qemu-aarch64
  - NixOS:
    - Add to your system configuration: boot.binfmt.emulatedSystems = [ "aarch64-linux" ];
    - Rebuild system.

How to Build
- Build the SD image:
  - nix build .#vim1s-sd-image
- Result artifact:
  - result/sd-image/nixos-vim1s-aarch64-linux.img.zst

How to Flash
- Replace /dev/sdX with your SD device (e.g. /dev/mmcblk0). Double-check with lsblk.
- Write image:
  - zstdcat result/sd-image/*.img.zst | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress
- Eject safely when done.

Boot Instructions
- Insert SD into VIM1S and power on with serial attached for logs (115200 8N1).
- Expected: existing Khadas U-Boot in SPI/eMMC finds /boot/extlinux/extlinux.conf on the SD and boots the NixOS kernel with FDT amlogic/kvim1s.dtb.
- If it continues to boot eMMC:
  - Interrupt U-Boot, then:
    - mmc list
    - mmc dev 1
    - fatls mmc 1:1 / (or ext4ls)
    - ext4ls mmc 1:1 /boot
    - ext4ls mmc 1:1 /boot/extlinux
  - Boot via the extlinux menu or adjust boot targets temporarily.
- If your U-Boot lacks extlinux, you can flash a Khadas U-Boot with extlinux support per Khadas docs or use chainloading.

Console, Users, Networking
- Serial console: ttyAML0 at 115200 8N1 (e.g., screen /dev/ttyUSB0 115200).
- Users:
  - user: nixos / pass: nixos
  - root: root / pass: root
- SSH enabled; NetworkManager manages networking.

Device Tree Details
- modules/vim1s.nix builds kvim1s.dtb from the vendor sources and installs it under /boot/dtbs, referenced as:
  - hardware.deviceTree.name = "amlogic/kvim1s.dtb";
- If boot fails with “DTB not found”, mount SD /boot and inspect /boot/dtb or /boot/dtbs to confirm the exact DTB path. Update hardware.deviceTree.name accordingly.

Known Issues Previously Encountered
- Using mainline kernels (6.x) alongside the vendor DTB caused boot issues (kernel/init loaded then DT mismatch symptoms).
  - Mitigation: use nixpkgs linuxPackages_5_15 for better compatibility with vendor DT.
- A previous syntax error during flake evaluation referenced modules/vim1s.nix sed line inside the dtb buildPhase. This has been corrected.
  - The expected sed line is:
    - sed -E -i 's@^[[:space:]]*#include[[:space:]]+"([^"]+)"@/include/ "\\1"@' "$f"
  - If you hit an evaluation error pointing to modules/vim1s.nix with unexpected text near that sed command, ensure the file matches the repository version.

Troubleshooting
- No boot / blank:
  - Check serial logs; ensure /boot/extlinux/extlinux.conf exists and references FDT amlogic/kvim1s.dtb.
  - If storage is slow to come up, add rootdelay=3 to boot.kernelParams in modules/vim1s.nix.
- Kernel boots but cannot mount root:
  - Confirm the root partition label is NIXOS_SD (set by sd-image module).
  - Check that /dev/disk/by-label/NIXOS_SD resolves in the initrd shell.
- Networking:
  - Ethernet should work early.
  - Wi-Fi/BT may need specific firmware/overlays; capture dmesg logs and adjust.

Next Steps (for the upcoming task)
1) U-Boot for NixOS (from Khadas u-boot: khadas-vims-v2019.01)
   - Create a derivation that builds U-Boot for VIM1S.
   - Determine the correct packaging for Amlogic SM1/Y4 (e.g., u-boot.bin.sd.bin, FIP packaging, or u-boot.ext for chainload).
   - Provide a safe integration strategy:
     - Prefer chainloading (keep eMMC/SPI U-Boot intact) where possible.
     - Document explicit flashing steps only as an opt-in, with clear risk notes.
   - Optionally copy u-boot.ext to /boot so an existing U-Boot can chainload it.

2) Keep kernel at nixpkgs 5.15 initially
   - Validate core peripherals with vendor DTB (Ethernet/USB/UART).
   - If specific devices misbehave, consider building vendor 5.15 kernel via buildLinux as an alternative kernelPackages set.

3) Optional DT overlays
   - Compile selected Khadas overlays to .dtbo and expose via:
     - hardware.deviceTree.overlays = [ "amlogic/your-overlay.dtbo" ];
   - Only if/when needed.

4) Validate and document
   - Capture UART logs (U-Boot and kernel) for first boot.
   - Update README with confirmed-working paths and any quirks.

Flake Quick Reference
- Build SD image:
  - nix build .#vim1s-sd-image
- NixOS configuration path (alternative use):
  - .#nixosConfigurations.vim1s

Reproducibility Notes
- Vendor sources are pinned as non-flake inputs (flake.lock). Run nix flake update to advance.
- Image base name set via sdImage.imageBaseName = "nixos-vim1s".

Use this README as the model context prompt for the next task
- Goal: “Make NixOS SD image boot on VIM1S with Khadas U-Boot and nixpkgs 5.15 kernel; compile vendor DTB; then integrate a proper U-Boot derivation.”
- Start with implementing the U-Boot derivation and a safe boot flow (chainload-first).
