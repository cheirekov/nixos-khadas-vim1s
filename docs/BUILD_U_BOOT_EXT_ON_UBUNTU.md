# Build a clean u-boot.ext for Khadas VIM1S on Ubuntu (no Ubuntu cfgload/env helpers)

Goal
- Produce a u-boot.ext from Khadas vendor U-Boot that:
  - Chainloads cleanly and reads /boot/extlinux/extlinux.conf
  - Does NOT search for boot.ini/uEnv.txt/cfgload “Ubuntu helpers”

Two supported methods: Plain Make (recommended) and Fenix (Khadas scripts).

Prerequisites (Ubuntu host)
- Packages:
  sudo apt update && sudo apt install -y \
    build-essential gcc-aarch64-linux-gnu git bison flex swig python3 \
    pkg-config libssl-dev device-tree-compiler

- Cross-compiler:
  export CROSS_COMPILE=aarch64-linux-gnu-

- Vendor U-Boot source:
  git clone https://github.com/khadas/u-boot -b khadas-vims-v2019.01

- Config fragment (disables cfgload/env helpers, keeps extlinux):
  Use the fragment from this repo:
    modules/../uboot/kvim1s-extlinux-clean.fragment
  If building on a different machine, copy the file contents and create it locally.


Method A: Plain Make (fastest)
1) Enter tree and configure for VIM1S
   cd u-boot
   make kvim1s_defconfig

2) Apply our “no Ubuntu helpers” fragment, then reconcile
   # Option 1: if you have the fragment file locally
   cat /path/to/kvim1s-extlinux-clean.fragment >> .config

   # Option 2: paste the fragment lines (see fragment file in this repo)
   # then:
   make olddefconfig

3) Build
   make -j"$(nproc)"

4) Produce u-boot.ext for chainload
   if [ -f u-boot.itb ]; then
     cp u-boot.itb u-boot.ext
   elif [ -f u-boot.bin ]; then
     cp u-boot.bin u-boot.ext
   else
     echo "No u-boot.itb or u-boot.bin produced; check the build output" >&2
     exit 1
   fi

5) Quick verification (optional)
   # cfgload helper should be absent
   if strings u-boot.ext | grep -qi cfgload; then
     echo "Warning: cfgload still present; the fragment may not have applied" >&2
   fi

   # At runtime (serial console), “help | grep cfgload” should show nothing.
   # Boot should read extlinux instead of boot.ini/uEnv.txt.

6) Use with Nix image
   - Copy u-boot.ext into the Nix repo root (same dir as flake.nix).
   - Our sd-image builder will embed it as /boot/u-boot.ext automatically.
   - Build your image on the Nix side:
     nix build -L .#vim1s-sd-image --accept-flake-config


Method B: Fenix (build U-Boot only)
1) Clone Fenix
   git clone https://github.com/khadas/fenix
   cd fenix

2) Minimal env to build ONLY U-Boot
   export BOARD=VIM1S
   export UBOOT_REPO=https://github.com/khadas/u-boot
   export UBOOT_BRANCH=khadas-vims-v2019.01
   export UBOOT_DEFCONFIG=kvim1s_defconfig
   export CROSS_COMPILE=aarch64-linux-gnu-

3) Build U-Boot (don’t build full Ubuntu images)
   ./make.sh uboot

   Note: Fenix places artifacts under build/ or out/…/uboot/. Identify the U-Boot build dir:
   - If needed, cd into the U-Boot build directory (where .config exists).

4) Apply the fragment as in Method A and rebuild
   cat /path/to/kvim1s-extlinux-clean.fragment >> .config
   make olddefconfig
   make -j"$(nproc)"

5) Produce u-boot.ext
   Same as Method A (prefer u-boot.itb → u-boot.ext; fallback u-boot.bin → u-boot.ext).

6) Copy u-boot.ext to the Nix repo root and rebuild the SD image.


Config fragment details (what it does)
- Prevent U-Boot from searching for boot.ini/uEnv.txt/cfgload helpers:
  CONFIG_ENV_IS_NOWHERE=y
  # CONFIG_ENV_IS_IN_FAT is not set
  # CONFIG_ENV_IS_IN_MMC is not set
  # CONFIG_CMD_CFGLOAD is not set

- Keep standard extlinux/distro boot:
  CONFIG_DISTRO_DEFAULTS=y
  CONFIG_CMD_PXE=y
  CONFIG_CMD_EXT2=y
  CONFIG_CMD_EXT4=y
  CONFIG_CMD_FAT=y
  CONFIG_FS_EXT4=y
  CONFIG_FS_FAT=y

After you’ve generated u-boot.ext:
- Put it next to flake.nix in this repo (root).
- Build the image; the builder will say “Embedding prebuilt u-boot.ext from repository root”.
- Flash the SD image, boot, and you should see clean extlinux flow (no Ubuntu overlays).

Troubleshooting
- cfgload still present: Ensure the fragment was appended to .config before make olddefconfig, or edit include/configs/kvim1s.h (or the included board header) to remove BOOTENV helpers; then rebuild.
- No u-boot.itb/u-boot.bin: Check make output for errors; ensure CROSS_COMPILE is set and defconfig is kvim1s_defconfig.
- SPI U‑Boot interfering: Use the signed SD blob boot path (if you have one) or ensure your chainloader is the first-stage used on your board.
