# NixOS on Khadas VIM1S (Amlogic S905Y4) — Vendor 5.15 Kernel, DTB/Overlays, U‑Boot Chainload

Objective
- Provide a reproducible NixOS SD image for Khadas VIM1S (S905Y4) using Nix flakes.
- Align with vendor device tree sources and a vendor-aligned 5.15 kernel for maximum compatibility.
- Keep the boot path simple: generic extlinux with a vendor DTB (overlays pre‑merged at build time).

Status (Oct 2025 bring‑up)
- Kernel: using Khadas vendor tree (5.15.137) built via linuxManualConfig (non‑interactive Kconfig).
- DTB: kvim1s.dtb compiled from vendor/common_drivers; overlays from upstream repo are pre‑merged at image build time (no runtime overlay.env/uEnv needed).
- Boot: generic extlinux (U‑Boot reads /boot/extlinux/extlinux.conf). We additionally embed a neutral u‑boot.ext onto the FAT /boot so existing loaders can chainload it, avoiding Ubuntu overlay helpers.
- Signed SD U‑Boot blob (optional): supported for raw SD boot as before (if u-boot.bin.sd.bin.signed.new is in repo root), but chainloading u‑boot.ext is safer for bring‑up.

What changed vs older README versions
- Kernel build strategy:
  - Old approach: nixpkgs linuxPackages_5_15.
  - New approach: build vendor 5.15.137 kernel from khadas/linux khadas‑vims‑5.15.y using a non‑interactive config pipeline.
- U‑Boot:
  - We now embed a chainloadable u‑boot.ext on the FAT /boot partition to neutralize Ubuntu overlay helpers present in some Khadas loaders. Raw SD signed U‑Boot embedding stays optional.
- Debug hardening:
  - Documented the Kconfig loop fixes, modDirVersion mismatch, CRLF issues, and Ubuntu overlay.env pitfalls with recommended UART and U‑Boot commands.

Hardware/Upstream References
- Device: https://www.khadas.com/vim1s
- Vendor Linux kernel (5.4 / 5.15): https://github.com/khadas/linux/tree/khadas-vim1s-r
- Khadas U‑Boot: https://github.com/khadas/u-boot/tree/khadas-vims-v2019.01
- U‑Boot build docs: https://docs.khadas.com/products/sbc/vim1s/development/linux/build-linux-uboot
- DT overlays (upstream): https://github.com/khadas/khadas-linux-kernel-dt-overlays

Constraints and Boot Strategy (Amlogic)
- Amlogic ROM requires a signed BL2/FIP chain for raw SD boot (board‑specific).
- Safer bring‑up:
  - Use existing SPI/eMMC U‑Boot (or a signed SD U‑Boot) and chainload a neutral u‑boot.ext from the SD’s FAT /boot.
  - This avoids Ubuntu overlay helpers and sticks to a clean extlinux flow.
- Optional: embed a signed SD U‑Boot blob to boot raw from SD without SPI/eMMC.

Repository Layout
- flake.nix — flake outputs and NixOS sd-image wiring (VFAT /boot + ext4 root).
- modules/vim1s.nix — VIM1S board module:
  - Builds vendor kernel (5.15.137) from khadas‑vims‑5.15.y using linuxManualConfig.
  - Seeds .config from nixpkgs 5.15 and forces essential NixOS opts + ARCH_MESON; reconciles with olddefconfig.
  - Temporarily bypasses strict NixOS kernel‑config assertions during bring‑up (re‑enable once kernel boots).
  - Builds amlogic/kvim1s.dtb via gcc -E + dtc; overlays from upstream are compiled and fdtoverlay‑merged at build time.
  - Installs DTB to /boot/nixos/<hash>/amlogic/kvim1s.dtb (no “dtbs/” prefix).
  - Enables loader.generic‑extlinux‑compatible; sets console params and basic initrd modules.
  - Embeds u‑boot.ext onto the FAT /boot (chainload) if enabled.
  - Optionally embeds a signed SD U‑Boot blob if u-boot.bin.sd.bin.signed.new is present at repo root (raw SD boot).
- modules/uboot-vim1s.nix — U‑Boot derivation & packaging:
  - Builds Khadas U‑Boot for VIM1S and exposes config.system.build.ubootVim1s.
  - Options:
    - khadas.ubootVim1s.enable (default true in our bring‑up): build and expose U‑Boot.
    - khadas.ubootVim1s.embedInBoot = true: install u‑boot.ext onto the FAT /boot at image build time (chainload).
    - khadas.ubootVim1s.installChainloadFile = false (optional service to install on first boot if missing).

Current Implementation Details

Kernel (vendor 5.15.137)
- Source: khadas/linux (khadas‑vims‑5.15.y) via a non‑flake input.
- Build: pkgs.linuxManualConfig with:
  - version = modDirVersion = 5.15.137 (matches upstream reported version).
  - configfile produced by a non‑interactive derivation that:
    1) Reads vendor/common_drivers; copies kvims_defconfig into a writable path to avoid read‑only store issues.
    2) Seeds .config from nixpkgs 5.15’s config (satisfies core NixOS assertions).
    3) Appends critical flags:
       - DEVTMPFS, CGROUPS, INOTIFY_USER, SIGNALFD, TIMERFD, EPOLL, NET,
         SYSFS, PROC_FS, FHANDLE, CRYPTO_USER_API_HASH, CRYPTO_HMAC, CRYPTO_SHA256,
         AUTOFS_FS, TMPFS (+ POSIX_ACL/XATTR), SECCOMP, BLK_DEV_INITRD,
         MODULES, BINFMT_ELF, UNIX, DMI, DMIID, ARCH_MESON.
    4) Runs make ARCH=arm64 olddefconfig (no interactive prompts; removed “yes |” which caused Broken pipe under pipefail).
- Temporary: system.requiredKernelConfig is disabled during bring‑up (re‑enable after first boot).

Device Tree (DTB)
- Base DTS: vendor/common_drivers (kvim1s.dts).
- Preprocess and compile: gcc -E (DTS preprocessor) + dtc -@ (fixups) => kvim1s.dtb.
- Overlays: compiled from khadas/khadas-linux-kernel-dt-overlays (overlays/vim1s/5.4) and merged via fdtoverlay during image build.
- Installed path: /boot/nixos/<hash>/amlogic/kvim1s.dtb; extlinux must point to this exact closure path.

U‑Boot
- extlinux boot required (U‑Boot sysboot loads extlinux.conf).
- Chainload u‑boot.ext:
  - We embed u‑boot.ext on the FAT /boot when khadas.ubootVim1s.embedInBoot = true.
  - Existing SPI/eMMC loader or signed SD U‑Boot will find and chainload it, resulting in a clean extlinux flow (no Ubuntu overlay.env).
- Signed SD U‑Boot (raw SD boot) remains supported by placing u-boot.bin.sd.bin.signed.new at repo root; postBuild dd’s it into the image (MBR + rest).

Build Requirements
- Nix installed (flakes).
- Build on aarch64 or x86_64 with binfmt/qemu-user enabled.
  - Debian/Ubuntu: sudo apt install qemu-user-static binfmt-support && sudo update-binfmts --enable qemu-aarch64
  - NixOS host: boot.binfmt.emulatedSystems = [ "aarch64-linux" ];

How to Build
- SD image:
  - nix build -L .#vim1s-sd-image --accept-flake-config
- Artifact:
  - result/sd-image/nixos-vim1s-<version>-aarch64-linux.img(.zst)

How to Flash
- Replace /dev/sdX with your SD device (e.g. /dev/mmcblk0).
- zstdcat result/sd-image/*.img.zst | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress

Boot Instructions
- UART at 921600 8N1 on ttyS0 (fallback UART on ttyAML0 at 115200 8N1).
- SD boot:
  - The first‑stage loader finds /boot/u‑boot.ext and chainloads it (if present), then extlinux menu appears.
  - extlinux loads:
    - Image, initrd from /boot/nixos/<hash>/
    - DTB from /boot/nixos/<hash>/amlogic/kvim1s.dtb
- If it continues to boot eMMC:
  - Interrupt U‑Boot, then:
    - mmc list; mmc dev 1
    - fatls mmc 1:1 /; ext4ls mmc 1:1 /boot /boot/extlinux
    - sysboot mmc 1:1 any /boot/extlinux/extlinux.conf (one‑shot clean boot)

Important: Do NOT use Ubuntu’s overlay helpers
- Do not copy /boot/uEnv.txt or any kvim1s.dtb.overlay.env into the SD image.
- Do not copy a kvim1s.dtb.overlays directory.
- These Ubuntu‑specific helpers can cause FDT_ERR_NOTFOUND/rsvmem errors in U‑Boot and break the boot.
- Overlays are compiled and merged at build time in this flake, so runtime helpers are unnecessary.

Troubleshooting and Debug Notes

Observed issues and fixes during bring‑up
- Interactive Kconfig loop (“Error in reading or end of file.”; repeated questions in generate-config.pl):
  - Fix: switched to linuxManualConfig + pre‑generated .config flow.
- “Broken pipe” during olddefconfig:
  - Cause: piping “yes | make olddefconfig” under strict shell caused a pipefail.
  - Fix: call “make olddefconfig” directly (non‑interactive).
- KBUILD_DEFCONFIG path/defconfig resolution:
  - Copy kvims_defconfig into a writable arch/arm64/configs and sanitize CRLF endings.
- modDirVersion mismatch:
  - Error: Nix expected 5.15.137 but modDirVersion was set to 5.15.0‑khadas.
  - Fix: set version=modDirVersion=5.15.137 to match upstream reported version.
- ZFS / external module builder failures:
  - Disabled extraModulePackages and added kernel.dev shim inside linuxPackagesFor to avoid out‑of‑tree module packaging during bring‑up.
- Ubuntu overlay.env/uEnv.txt interference:
  - Some Khadas U‑Boot loaders attempt to read /boot/uEnv.txt and /boot/overlays/*.overlay.env even with extlinux present, then fdt apply overlays at runtime -> FDT errors.
  - Fix/Workaround:
    - Prefer chainloading a neutral u‑boot.ext (no Ubuntu overlay helpers) from FAT /boot.
    - Or directly sysboot for a session: sysboot mmc 1:1 any /boot/extlinux/extlinux.conf.
    - To persist (only if confident):
      - setenv bootcmd 'sysboot mmc 1:1 any /boot/extlinux/extlinux.conf'
      - setenv fdt_overlays; setenv overlays; setenv overlayfs; setenv overlay_profile
      - saveenv

Low‑level diagnostics
- Temporarily append the following to extlinux APPEND for early logs:
  - earlycon=meson,uartao,0xff803000 ignore_loglevel initcall_debug
- U‑Boot environment inspection:
  - printenv fdt_overlays overlays overlayfs overlay_profile fdt_addr_r fdt_addr

Device Tree Details
- hardware.deviceTree.name = "amlogic/kvim1s.dtb"
- DTB installed to /boot/nixos/<hash>/amlogic/kvim1s.dtb (do not move/rename; extlinux points to the closure path).
- To test minimal DTB (no overlays), set overlayNames = [] in modules/vim1s.nix and rebuild; re‑enable overlays incrementally.

U‑Boot Paths: Chainload vs. Raw SD
- Chainload (recommended for bring‑up):
  - khadas.ubootVim1s.enable = true; khadas.ubootVim1s.embedInBoot = true.
  - Places u‑boot.ext into FAT /boot; existing SPI/eMMC or signed SD loader chainloads it.
- Raw SD (optional):
  - Place u-boot.bin.sd.bin.signed.new at repo root.
  - Post‑build dd embeds signed blob (MBR + rest) to image; the SD becomes raw‑bootable without SPI/eMMC U‑Boot.

Extlinux (example snippet)
```
LABEL NixOS
  MENU LABEL NixOS (VIM1S vendor 5.15.137)
  LINUX ../nixos/<hash>/linux
  INITRD ../nixos/<hash>/initrd
  FDT ../nixos/<hash>/amlogic/kvim1s.dtb
  APPEND console=ttyS0,921600n8 console=ttyAML0,115200n8 root=LABEL=NIXOS_SD rootfstype=ext4 rootdelay=3
```

Recommendations before deeper “fixes”
- Let the kernel build complete; first verify the extlinux boot path using the neutral u‑boot.ext (chainload). Do not re‑enable runtime overlay helpers (uEnv/overlay.env).
- If boot succeeds:
  - Re‑enable strict kernel‑config assertions and iterate the .config until all NixOS asserts pass cleanly.
  - Optionally migrate DTB build under Kbuild (make dtbs) if desired for consolidation.
- If boot still fails with FDT errors:
  - Confirm you are chainloading the neutral u‑boot.ext and not the Ubuntu overlay‑enabled environment.
  - Test base DTB (overlayNames = []) and reintroduce overlays incrementally.
  - Use sysboot for one‑shot clean extlinux boot and inspect U‑Boot env variables that may trigger overlay logic.

Flake Quick Reference
- Build SD image:
  - nix build -L .#vim1s-sd-image --accept-flake-config
- NixOS configuration (alternative):
  - nix build .#nixosConfigurations.vim1s.config.system.build.toplevel

Reproducibility Notes
- Vendor sources and overlays are pinned as non‑flake inputs (flake.lock). Use “nix flake update” to advance.
- Image base name set via sdImage.imageBaseName in the module.

Use this README as the prompt for further tasks
- Goal: “Boot NixOS SD image on VIM1S using vendor 5.15.137 kernel with vendor DTB; overlays compiled/merged at build time; optionally embed a signed SD U‑Boot blob; prefer chainload u‑boot.ext for a clean extlinux path.”
- Follow‑ups: re‑enable kernel assertions and trim config, optionally switch DTB build to Kbuild, capture UART logs of clean extlinux boot (with and without signed SD blob), and decide on final overlay set.
