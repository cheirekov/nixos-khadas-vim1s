# NixOS on Khadas VIM1S (Amlogic S905Y4)
A flake that builds a bootable NixOS SD card image for Khadas VIM1S using the vendor 5.15 kernel (khadas/linux: khadas-vim1s-r) and generic extlinux boot.

Status:
- Kernel: vendor 5.15 built inside the flake
- Bootloader: generic extlinux (expects a U-Boot on the device that supports extlinux)
- DTB: amlogic/kvim1s.dtb
- Image layout: VFAT /boot + ext4 root (NIXOS_SD label)

Repository layout:
- flake.nix — flake outputs (sd-image)
- modules/vim1s.nix — board hardware module (kernel, dtb, initrd, firmware)

## Requirements

You need Nix installed on your build host. For cross-building on x86_64 to aarch64 you also need binfmt/qemu-user emulation.

Options:
- Native build on aarch64 Linux: no special setup required, just run the build command.
- Cross-build on x86_64:
  - On Debian/Ubuntu hosts:
    - sudo apt update
    - sudo apt install -y qemu-user-static binfmt-support
    - sudo update-binfmts --enable qemu-aarch64
  - On NixOS hosts:
    - In your system configuration, enable:
      boot.binfmt.emulatedSystems = [ "aarch64-linux" ];
    - Rebuild your system, then build the image from this flake.

If you have a remote aarch64 builder, you can also configure nix to use it (out of scope here).

## Build

- Build the SD image (on either aarch64 or x86_64 with binfmt):
  - nix build .#vim1s-sd-image

- The output is a compressed image at:
  - result/sd-image/nixos-vim1s-aarch64-linux.img.zst

## Flash to SD

Replace /dev/sdX with your SD card block device (e.g. /dev/mmcblk0). Double-check with lsblk.

- Decompress and write:
  - zstdcat result/sd-image/*.img.zst | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress

- Safely eject the SD card after dd completes.

## Boot

- Insert the SD card into the VIM1S and power on.
- Most Khadas U-Boot builds will auto-detect and boot from SD with extlinux:
  - The image contains /boot/extlinux/extlinux.conf with FDT=amlogic/kvim1s.dtb.
- If the device still boots eMMC, enter the U-Boot shell (interrupt with the key prompt) and try:
  - mmc list
  - mmc dev 1
  - fatls mmc 1:1 / (or ext4ls if it shows ext4)
  - ext4ls mmc 1:1 /boot
  - ext4ls mmc 1:1 /boot/extlinux
- Then boot via extlinux menu or set boot targets appropriately. If your eMMC U-Boot is missing extlinux support, consider flashing the Khadas U-Boot per Khadas docs, or chainloading from eMMC to SD.

## Console and Login

- Serial console: 115200 8N1 on the VIM1S UART (e.g. screen /dev/ttyUSB0 115200)
- Default users:
  - user: nixos / password: nixos
  - root: root / password: root
- SSH is enabled; networking via NetworkManager.

## Device Tree (DTB) and overlays

This initial image uses the base DTB:
- hardware.deviceTree.name = "amlogic/kvim1s.dtb";

Notes:
- In some trees the DTB may be named differently (e.g. meson-sm1-khadas-vim1s.dtb). If boot fails with DTB not found, mount the /boot partition on the SD and inspect /boot/dtb or /boot/dtbs to find the exact DTB name, then update modules/vim1s.nix accordingly.
- Khadas provides overlay repositories for Ubuntu that we can integrate later. The current image does not apply any DT overlays. The base DTB should be sufficient for bring-up (Ethernet/USB/UART). Wi-Fi/BT may require specific firmware and/or overlays depending on the module.

## Kernel details

- The kernel is built from khadas/linux (branch: khadas-vim1s-r) using meson64_defconfig plus some additional options for NixOS and common filesystems.
- The module modules/vim1s.nix sets:
  - boot.kernelPackages = linuxPackagesFor(vendorKernel)
  - loader.generic-extlinux-compatible.enable = true
  - kernelParams: console=ttyAML0, root=LABEL=NIXOS_SD, etc.
  - firmware: linux-firmware bundled
  - initrd: include common MMC/USB modules for Amlogic G12/SM1 family

## Troubleshooting

- No boot / black screen:
  - Use serial console to observe U-Boot and kernel logs.
  - In U-Boot, list partitions and check /boot/extlinux/extlinux.conf exists on mmc 1:1.
  - Ensure FDT path in extlinux.conf matches the DTB present under /boot/dtb or /boot/dtbs.
- Kernel boots but no rootfs:
  - Confirm the root partition label on the SD card is NIXOS_SD (the sd-image module sets this).
  - Try adding rootdelay=3 to kernelParams if storage comes up slowly.
- Ethernet/Wi-Fi:
  - Ethernet should work out-of-the-box.
  - Wi-Fi/BT may require additional firmware or overlays; capture dmesg output and adjust as needed.

## Next steps (optional)

- Integrate Khadas DT overlays by compiling the selected .dts from https://github.com/khadas/khadas-linux-kernel-dt-overlays to .dtbo and adding:
  - hardware.deviceTree.overlays = [ "amlogic/your-overlay.dtbo" ];
- Switch to mainline kernel later once functionality is acceptable, or keep tracking the vendor tree for board-specific features.

## Reproducibility notes

- The kernel source is pinned by flake.lock. Run nix flake update to update inputs.
- The image name base is set to sdImage.imageBaseName = "nixos-vim1s" for easy identification.
