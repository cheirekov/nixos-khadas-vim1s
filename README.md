# NixOS on Khadas VIM1S (Amlogic S905Y4)
Vendor 5.15.137 kernel + vendor DTB/overlays + neutral U‑Boot chainloader via extlinux

Overview
- Goal: Reproducible NixOS SD image for VIM1S using vendor-aligned 5.15.137 kernel and vendor device trees for maximum compatibility.
- Boot path: Clean, distro-standard extlinux. No Ubuntu cfgload/uEnv overlay helpers at runtime; overlays are precompiled and merged at build time.
- Chainload: A neutral u-boot.ext is embedded into the FAT boot partition so the existing SPI/eMMC U‑Boot or signed SD first stage can chainload a clean environment.

What this flake does
- Kernel (vendor 5.15.137)
  - Builds the Khadas vendor kernel via linuxManualConfig using a pre-generated .config (non-interactive). 
  - Seeds from nixpkgs 5.15 configuration, appends essential NixOS flags, enables ARCH_MESON, then make olddefconfig.
  - Temporarily disables strict NixOS kernel-config assertions during bring-up (re-enable after boot is proven).

- Device tree (DTB and overlays)
  - Compiles kvim1s.dtb from vendor/common_drivers using gcc -E (preprocess) + dtc -@.
  - Optionally compiles upstream overlays (khadas/khadas-linux-kernel-dt-overlays) and merges them into the base DTB with fdtoverlay at image build time.
  - Installs the merged DTB under /boot/nixos/<hash>/amlogic/kvim1s.dtb; extlinux points to the closure path.

- U‑Boot (vendor v2019.01)
  - Builds vendor U‑Boot for kvim1s with modern toolchains; resolves legacy host tool link issues by finalizing Kconfig first and building tools explicitly.
  - Force-enables CONFIG_FIT, disables CONFIG_FIT_SIGNATURE, disables CONFIG_FIT_FULL_CHECK to avoid fdt_check_full symbol, and maps fdt_check_full→fdt_check_header for tools.
  - Avoids u-boot.itb (dtc -E incompatibility on this vendor tree); uses u-boot.bin as u-boot.ext.
  - Embeds u-boot.ext into the FAT /boot during image postBuild using mtools (no mounting needed).
  - Optional: embeds signed SD first-stage u-boot.bin.sd.bin.signed.new (raw SD boot) via dd into the image’s MBR + remainder.

- sd-image integration
  - FAT /boot partition + ext4 root partition.
  - postBuild: 
    - If u-boot.bin.sd.bin.signed.new is present in repo root, dd it into the image (raw SD boot).
    - If chainload embedding is enabled, mcopy u-boot.ext into FAT /boot.
  - No Ubuntu runtime overlay mechanisms are used or expected.

Repository layout
- flake.nix        — Flake outputs and sd-image wiring
- modules/vim1s.nix — Board module: kernel, DTB build/merge, sd-image behaviors, extlinux, serial params
- modules/uboot-vim1s.nix — U‑Boot derivation + module options and packaging
- docs/BUILD_U_BOOT_EXT_ON_UBUNTU.md — How to build a clean neutral u-boot.ext on an Ubuntu host
- uboot/kvim1s-extlinux-clean.fragment — Config fragment to disable Ubuntu helpers and keep extlinux, for reference

Build prerequisites
- Nix with flakes enabled.
- Host platform:
  - aarch64-linux: native build.
  - x86_64-linux: enable qemu-user/binfmt for aarch64:
    - Debian/Ubuntu: sudo apt install qemu-user-static binfmt-support && sudo update-binfmts --enable qemu-aarch64
    - NixOS: add boot.binfmt.emulatedSystems = [ "aarch64-linux" ];

How to build the SD image
- nix build -L .#vim1s-sd-image --accept-flake-config
- Output: result/sd-image/nixos-vim1s-<date>.aarch64-linux.img(.zst)

Flash to SD
- Replace /dev/sdX with your SD device (e.g., /dev/mmcblk0):
  - zstdcat result/sd-image/*.img.zst | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress

Where u-boot.ext is inside the image
- It is placed in the FAT boot partition (partition 1) at the root: /u-boot.ext
- Verify without mounting using mtools:
  - IMG=path/to/nixos-vim1s-*.img
  - BOOT_START=$(parted -sm "$IMG" unit B print | awk -F: '/^1:/ { sub(/B$/,"",$2); print $2 }')
  - mdir -i "$IMG@@$BOOT_START" ::/
  - mdir -i "$IMG@@$BOOT_START" ::/u-boot.ext
- Or via loop mount:
  - sudo losetup --show -Pf "$IMG"       # -> /dev/loopX
  - sudo mount /dev/loopXp1 /mnt/boot
  - ls -l /mnt/boot/u-boot.ext
  - sudo umount /mnt/boot && sudo losetup -d /dev/loopX

Boot instructions (UART)
- Connect UART at 921600 8N1 (ttyS0). A fallback UART is often at 115200 8N1 (ttyAML0).
- Expected behavior:
  - First-stage loader (SPI/eMMC or signed SD) chainloads /boot/u-boot.ext from FAT.
  - U‑Boot sysboot/extlinux reads /boot/extlinux/extlinux.conf and loads:
    - Linux, initrd, DTB from /boot/nixos/<hash>/...
- If the board keeps booting eMMC:
  - Interrupt U‑Boot prompt, then:
    - mmc list; mmc dev 1
    - fatls mmc 1:1 /; ext4ls mmc 1:1 /boot /boot/extlinux
    - sysboot mmc 1:1 any /boot/extlinux/extlinux.conf

Kernel/DTB details
- Vendor kernel: 5.15.137 (khadas-vims-5.15.y). We set version = modDirVersion = 5.15.137 to match upstream reported version.
- .config generation:
  - Copy kvims_defconfig into a writable arch/arm64/configs (sanitize CRLF).
  - Seed .config from nixpkgs 5.15 to satisfy core NixOS flags.
  - Append critical flags (DEVTMPFS, CGROUPS, INOTIFY_USER, SIGNALFD, TIMERFD, EPOLL, NET, SYSFS, PROC_FS, FHANDLE, CRYPTO_* hash/HMAC/SHA256, AUTOFS_FS, TMPFS(+ACL/XATTR), SECCOMP, BLK_DEV_INITRD, MODULES, BINFMT_ELF, UNIX, DMI, DMIID, ARCH_MESON, UHID=y, DEBUG_INFO_DWARF4, no-BTF).
  - make ARCH=arm64 olddefconfig (no “yes |”, avoids Broken pipe with pipefail).
- Device tree:
  - Preprocess DTS via gcc -E -P -D__DTS__ with include paths spanning vendor includes and common_drivers.
  - dtc -@ for fixups, and optionally fdtoverlay apply compiled overlays (overlays/vim1s/5.4).
  - Installed under /boot/nixos/<hash>/amlogic/kvim1s.dtb (extlinux FDT points to this path).

U‑Boot details and mitigations
- Legacy vendor tree + modern GCC/openssl can break U‑Boot host tools (mkimage/dumpimage) and FIT signature paths. Fixes applied:
  - Finalize Kconfig first: defconfig → patch .config → olddefconfig
  - Host tools built first (make O=build tools)
  - Set CONFIG_FIT=y; disable CONFIG_FIT_SIGNATURE; disable CONFIG_FIT_FULL_CHECK
  - Map fdt_check_full→fdt_check_header for host tool compilation (vendor libfdt variants)
  - Avoid u-boot.itb target to bypass dtc “-E requires arg” incompatibility; build u-boot.bin and package as u-boot.ext
  - Add git and hostname (inetutils) as nativeBuildInputs to placate vendor build scripts
  - Remove -Werror, relax warnings, and add -Wl,--no-as-needed for host link
- Expected warnings:
  - “u-boot has a LOAD segment with RWX permissions” — harmless on legacy U‑Boot.
- Chainloader packaging:
  - A symlink/copy u-boot.ext is installed in the U‑Boot derivation output at: ${config.system.build.ubootVim1s}/u-boot/u-boot.ext (read-only).
  - The sd-image postBuild embeds u-boot.ext into the FAT boot partition using mtools.

Disable Ubuntu overlay helpers
- Do not ship /boot/uEnv.txt, overlay.env files, or runtime overlay directories.
- These can trigger U‑Boot’s runtime overlay application and cause FDT errors (e.g., rsvmem not found).
- This flake compiles and merges overlays at build time instead.

Optional: build a neutral u-boot.ext on Ubuntu
- See docs/BUILD_U_BOOT_EXT_ON_UBUNTU.md for Plain Make and Fenix flows.
- Use uboot/kvim1s-extlinux-clean.fragment to disable cfgload and env-in-fat/mmc and keep extlinux flow.
- To embed a prebuilt chainloader, drop u-boot.ext next to flake.nix (repo root). The image builder will pick it up.

Raw SD first-stage (optional)
- Place u-boot.bin.sd.bin.signed.new at repo root. postBuild will dd it:
  - First 444 bytes (MBR region)
  - Remainder of file starting at 512-byte boundary
- This creates a raw SD boot path without relying on SPI/eMMC U‑Boot (still compatible with chainloader).

Troubleshooting
- Interactive Kconfig loops / repeated questions:
  - Use the non-interactive pre-generated .config approach (as implemented).
- Broken pipe with olddefconfig:
  - Don’t pipe “yes |”; call make olddefconfig directly.
- mkimage/dumpimage undefined symbols:
  - Ensure CONFIG_FIT=y; disable FIT_SIGNATURE; disable FIT_FULL_CHECK; build tools after olddefconfig; map fdt_check_full→fdt_check_header; use -Wl,--no-as-needed.
- dtc “-E” requires an argument on u-boot.itb:
  - Skip u-boot.itb target; use u-boot.bin as u-boot.ext.
- Boot still uses Ubuntu overlay runtime:
  - Confirm that you are using /boot/u-boot.ext (neutral chainloader).
  - Try one-shot boot: sysboot mmc 1:1 any /boot/extlinux/extlinux.conf.
  - Inspect and clear suspicious env: printenv fdt_overlays overlays overlayfs overlay_profile; setenv them empty if necessary.

Quick commands and verification
- Build SD image:
  - nix build -L .#vim1s-sd-image --accept-flake-config
- Verify FAT /boot embeds u-boot.ext (no mounting):
  - IMG=path/to/*.img
  - BOOT_START=$(parted -sm "$IMG" unit B print | awk -F: '/^1:/ { sub(/B$/,"",$2); print $2 }')
  - mdir -i "$IMG@@$BOOT_START" ::/u-boot.ext
- UART boot check:
  - Expect extlinux menu or direct boot messages pointing to /boot/extlinux/extlinux.conf.
  - Use earlycon for verbose kernel bring-up:
    - Append: earlycon=meson,uartao,0xff803000 ignore_loglevel initcall_debug

Next steps and prompts for new tasks
- Re-enable kernel-config assertions and iterate until NixOS checks pass on booted hardware.
- Consider migrating DTB build to Kbuild (make dtbs) for consolidation.
- Decide a final overlay set (reduce to what you need).
- Optional: produce a minimal, signed SD first-stage pipeline if you want raw SD boot only.

Prompt template for follow-up tasks
- Board: Khadas VIM1S (S905Y4)
- Kernel: vendor 5.15.137 (khadas-vims-5.15.y), linuxManualConfig with non-interactive .config; DTB compiled + overlays merged at build time.
- Boot: extlinux on FAT /boot; neutral u-boot.ext embedded; no Ubuntu cfgload/uEnv.
- U‑Boot: vendor v2019.01; FIT enabled, signatures disabled; host tools built after olddefconfig; u-boot.bin packaged as u-boot.ext; mtools embedding into FAT; optional signed SD blob dd to MBR.
- To do: enable assertions; Kbuild DTBs; pick final overlays; collect UART logs; confirm clean extlinux path; possibly upstream patches for tools/libfdt.

Changelog (bring-up highlights)
- Switched to vendor kernel build via linuxManualConfig; resolved Kconfig loops and modDirVersion mismatches.
- Device tree compiled via gcc -E + dtc; overlays pre-merged at build time.
- U‑Boot build stabilized with modern toolchains:
  - FIT on; signatures off; full-check off; map fdt_check_full; build tools first.
  - Prefer u-boot.bin over u-boot.itb, eliminating dtc -E failures.
  - Embed u-boot.ext into FAT with mtools; optionally dd signed SD first-stage.
- Explicitly avoid Ubuntu overlay helpers at runtime; extlinux only.

References
- Device: https://www.khadas.com/vim1s
- Vendor Linux: https://github.com/khadas/linux/tree/khadas-vim1s-r (and khadas-vims-5.15.y branch for 5.15.137)
- U‑Boot: https://github.com/khadas/u-boot/tree/khadas-vims-v2019.01
- Khadas U‑Boot docs: https://docs.khadas.com/products/sbc/vim1s/development/linux/build-linux-uboot
- DT overlays: https://github.com/khadas/khadas-linux-kernel-dt-overlays
