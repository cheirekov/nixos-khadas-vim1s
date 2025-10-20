# NixOS on Khadas VIM1S (Amlogic S905Y4) — Image Build, DTB/Overlays, U‑Boot Embedding

Objective
- Provide a reproducible NixOS SD image for Khadas VIM1S (S905Y4) using Nix flakes.
- Align with vendor device tree sources and a 5.15 kernel for maximum compatibility.

What’s new in this flake (Oct 2025 updates)
- Device Tree build:
  - kvim1s.dtb is built inside the flake by preprocessing the vendor DTS with gcc -E (no kernel .config needed) and compiling with dtc.
  - Final DTB path installed in /boot’s Nix closure is amlogic/kvim1s.dtb (no “dtbs/” prefix).
- Overlays from upstream repo:
  - Selected overlays for VIM1S are compiled from upstream: github.com/khadas/khadas-linux-kernel-dt-overlays (overlays/vim1s/5.4).
  - They are merged into the base DTB at image build time via fdtoverlay. No runtime overlay.env/uEnv usage is required.
- Clean extlinux boot path:
  - The image boots via generic extlinux. Ubuntu-specific U‑Boot overlay helpers (overlay.env/uEnv.txt) are NOT used.
- Board console and timing:
  - Kernel arguments set to console=ttyS0,921600n8 with a fallback console=ttyAML0,115200n8 and rootdelay=3.
- Optional U‑Boot embedding:
  - If a signed SD U‑Boot blob is present at the repo root (u-boot.bin.sd.bin.signed.new), it is embedded directly into the produced SD image during the sd-image postBuild phase (in-place dd). This allows raw SD boot without relying on SPI/eMMC U‑Boot.

Hardware/Upstream References
- Device: https://www.khadas.com/vim1s
- Vendor Linux kernel (5.4 / 5.15): https://github.com/khadas/linux/tree/khadas-vim1s-r
- Khadas U‑Boot: https://github.com/khadas/u-boot/tree/khadas-vims-v2019.01
- U‑Boot build docs: https://docs.khadas.com/products/sbc/vim1s/development/linux/build-linux-uboot
- DT overlays (upstream): https://github.com/khadas/khadas-linux-kernel-dt-overlays

Constraints and Boot Strategy (Amlogic)
- Amlogic boot ROM expects a signed BL2/FIP chain; packaging U‑Boot for raw SD boot is board‑specific.
- Short‑term: use existing U‑Boot in SPI/eMMC that supports extlinux to boot from SD.
- Optional: embed a signed SD U‑Boot blob into the image so it can boot raw from SD.
- Long‑term: provide a proper U‑Boot derivation from the Khadas tree or chainload (u‑boot.ext), but this is optional and gated.

Current Implementation (this flake)
- Image generator: NixOS sd-image for aarch64 (VFAT /boot + ext4 root with label NIXOS_SD).
- Kernel: nixpkgs linuxPackages_5_15 (matches vendor 5.15 DT compatibility; mainline 6.x may mismatch).
- DTB:
  - Base DTS from vendor/common_drivers is preprocessed via gcc -E and compiled with dtc.
  - Final DTB is installed as amlogic/kvim1s.dtb (no “dtbs/” prefix).
- Overlays:
  - Selected overlays are compiled from upstream (overlays/vim1s/5.4) and merged into the base DTB at build time via fdtoverlay.
  - This removes the need for runtime overlay.env/uEnv in U‑Boot.
- Bootloader:
  - generic-extlinux-compatible (U‑Boot must read /boot/extlinux/extlinux.conf).
  - Optional raw SD boot by embedding a signed SD U‑Boot blob during image build (see “U‑Boot Embedding”).
- Root filesystem: ext4 (label NIXOS_SD).
- Serial: console=ttyS0,921600n8 (board doc), with fallback console=ttyAML0,115200n8.

Repository Layout
- flake.nix — outputs and package. Produces the SD image package: .#vim1s-sd-image.
- modules/vim1s.nix — VIM1S board module:
  - Sets boot.kernelPackages = linuxPackages_5_15
  - Enables loader.generic-extlinux-compatible
  - Builds amlogic/kvim1s.dtb using gcc -E + dtc (no kernel .config needed)
  - Compiles and merges overlays from upstream (overlays/vim1s/5.4) into the DTB at build time
  - Adds initrd modules for G12/SM1 family
  - Sets kernelParams: console=ttyS0,921600n8 console=ttyAML0,115200n8 root=LABEL=NIXOS_SD rootfstype=ext4 rootdelay=3
  - Optional: embeds a signed SD U‑Boot blob into the generated image if u-boot.bin.sd.bin.signed.new is present
- modules/uboot-vim1s.nix — U‑Boot derivation & packaging (optional, gated). Also exposes the chainload u‑boot.ext install as a service (disabled by default).

Build Requirements
- Nix installed.
- Build on aarch64 host (native) or x86_64 with user‑mode emulation.
- For x86_64 hosts:
  - Debian/Ubuntu:
    - sudo apt update
    - sudo apt install -y qemu-user-static binfmt-support
    - sudo update-binfmts --enable qemu-aarch64
  - NixOS:
    - In your config: boot.binfmt.emulatedSystems = [ "aarch64-linux" ];
    - Rebuild system.

How to Build
- Build the SD image:
  - nix build .#vim1s-sd-image
- Result artifact:
  - result/sd-image/nixos-vim1s-<version>-aarch64-linux.img(.zst)

U‑Boot Embedding (optional, raw SD boot)
- If your board doesn’t have a suitable U‑Boot in SPI/eMMC, you can embed a signed SD U‑Boot into the built image.
- Place the blob at repo root as: u-boot.bin.sd.bin.signed.new
- During image build, modules/vim1s.nix will run sdImage.postBuildCommands to write the blob into the image with dd:
  - dd if=... bs=1 count=444 conv=fsync,notrunc
  - dd if=... bs=512 skip=1 seek=1 conv=fsync,notrunc
- This mirrors the nixos-generators approach. Use at your own risk; ensure the blob matches VIM1S (SM1/Y4) expectations.

How to Flash
- Replace /dev/sdX with your SD device (e.g. /dev/mmcblk0). Double‑check with lsblk.
- Write image:
  - zstdcat result/sd-image/*.img.zst | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress
- Eject safely when done.

Boot Instructions
- Attach serial at 921600 8N1 on ttyS0. A fallback console is configured on ttyAML0 at 115200 8N1.
- Insert SD into VIM1S and power on.
- Expected: U‑Boot finds /boot/extlinux/extlinux.conf on the SD and loads:
  - Image, initrd from /boot/nixos/<hash>/
  - DTB from /boot/nixos/<hash>/amlogic/kvim1s.dtb
- If it continues to boot eMMC:
  - Interrupt U‑Boot, then:
    - mmc list
    - mmc dev 1
    - fatls mmc 1:1 / (or ext4ls)
    - ext4ls mmc 1:1 /boot /boot/extlinux
  - Choose the extlinux menu or set boot targets to SD.

Important: Do NOT use Ubuntu’s overlay helpers
- Do not copy /boot/uEnv.txt or any kvim1s.dtb.overlay.env into the SD image.
- Do not copy a kvim1s.dtb.overlays directory.
- These Ubuntu‑specific helpers can cause FDT_ERR_NOTFOUND/rsvmem errors in U‑Boot and break the boot.
- Overlays are compiled and merged at build time in this flake, so runtime helpers are unnecessary.

Device Tree Details
- hardware.deviceTree.name = "amlogic/kvim1s.dtb"
- The DTB is placed in the Nix closure at /boot/nixos/<hash>/amlogic/kvim1s.dtb.
- Do not move/rename it on the SD. Let extlinux reference the exact closure path.

Overlays (built from upstream)
- This flake compiles overlays from: github.com/khadas/khadas-linux-kernel-dt-overlays/tree/main/overlays/vim1s/5.4
- The default overlay list (compiled and applied at image build) currently includes:
  - 4k2k_fb, i2cm_e, i2s, onewire, panfrost, pwm_f, spdifout, spi0, uart_c
- The built .dtbo files are also installed under amlogic/overlays in the DT package for reference.
- To change overlay selection: edit overlayNames in modules/vim1s.nix (or we can expose a Nix option later).

Console, Users, Networking
- Serial console: primary ttyS0 at 921600 8N1; fallback ttyAML0 at 115200 8N1.
- Users:
  - user: nixos / pass: nixos
  - root: root / pass: root
- SSH enabled; NetworkManager manages networking.

Troubleshooting
- “DTB not found”:
  - Ensure extlinux.conf FDT points to ../nixos/<hash>/amlogic/kvim1s.dtb (note: no “dtbs/” prefix).
- FDT_ERR_NOTFOUND / rsvmem check failed in U‑Boot:
  - Remove /boot/uEnv.txt, kvim1s.dtb.overlay.env, and any kvim1s.dtb.overlays you copied. These are Ubuntu helpers and not needed here.
- No kernel logs after “Starting kernel …”:
  - Verify the serial console: 921600 8N1 on ttyS0. A fallback on ttyAML0 at 115200 is also configured.
  - You can temporarily append earlycon=meson,uartao,0xff803000 ignore_loglevel initcall_debug to APPEND in extlinux.conf for low‑level diagnostics.
- Root not mounting:
  - Confirm the root partition label is NIXOS_SD; check /dev/disk/by-label/NIXOS_SD in initrd.
- If an overlay causes issues:
  - Rebuild image with overlayNames = [] in modules/vim1s.nix for a base DTB test, then re‑enable overlays incrementally.

Flake Quick Reference
- Build SD image:
  - nix build .#vim1s-sd-image
- NixOS configuration (alternative):
  - nix build .#nixosConfigurations.vim1s.config.system.build.toplevel

Reproducibility Notes
- Vendor sources and overlays are pinned as non‑flake inputs (flake.lock). Use nix flake update to advance.
- Image base name set via sdImage.imageBaseName in the module.

Next Steps
- Optional: Provide a robust U‑Boot derivation (khadas-vims-v2019.01) and a safe boot flow:
  - Chainload u‑boot.ext (keep SPI/eMMC U‑Boot intact), or
  - Provide an opt‑in image variant with the signed SD U‑Boot embedded (already supported via u-boot.bin.sd.bin.signed.new), with clear documentation and risks.
- Optional: Expose a Nix option to select overlays instead of editing overlayNames in modules/vim1s.nix.
- Capture and document UART logs confirming a clean extlinux boot on VIM1S (with and without U‑Boot embedding).

Use this README as the prompt for further tasks
- Goal: “Boot NixOS SD image on VIM1S using nixpkgs 5.15 kernel with vendor DTB; compile and merge upstream overlays at build time; optionally embed a signed SD U‑Boot blob.”
- Follow‑ups: iterate overlay selection, integrate a U‑Boot derivation, or provide a chainload‑first strategy.
