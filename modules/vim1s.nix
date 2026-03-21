{ lib, pkgs, config, kernel-khadas, common_drivers, dt-overlays, ... }:

let
  khadasSrc = pkgs.runCommand "khadas-linux-src-with-common-drivers" {} ''
    mkdir -p $out
    cp -r ${kernel-khadas}/* $out/
    mkdir -p $out/common_drivers
    cp -r ${common_drivers}/. $out/common_drivers/
    chmod -R u+w $out

    # Khadas enables -Werror unconditionally once AMLOGIC_DRIVER is set, which
    # turns benign vendor warnings into hard build failures with GCC 13.
    sed -i '/^KBUILD_CFLAGS += -Werror$/d' $out/Makefile

    # Vendor GPIO stubs have mismatched fallback signatures. Once the S4
    # pinctrl/GPIO stack is enabled, GCC treats these as a real type error via
    # module_merge.h, so fix the signatures in the copied source tree.
    substituteInPlace $out/common_drivers/drivers/gpio/main.h \
      --replace 'static inline void meson_gpio_irq_init(void)' 'static inline int meson_gpio_irq_init(void)' \
      --replace 'static inline int meson_gpio_irq_exit(void)' 'static inline void meson_gpio_irq_exit(void)'

    # Khadas' MMC host uses IS_ENABLED() on CQHCI helper paths. When the vendor
    # defconfig leaves AMLOGIC_MMC_CQHCI=m, those branches still compile into
    # the built-in host object and later fail to link against module-only
    # meson-cqhci symbols. Treat the helper as reachable only when it can really
    # link into the current build.
    sed -i 's/IS_ENABLED(CONFIG_AMLOGIC_MMC_CQHCI)/IS_REACHABLE(CONFIG_AMLOGIC_MMC_CQHCI)/g' \
      $out/common_drivers/drivers/mmc/host/meson-gx-mmc.c

    # eMMC key registration is optional vendor functionality, not part of the
    # SD boot path. Skip unifykey registration when the provider is not built
    # into the current image, otherwise vmlinux links mmc_key.o against
    # module-only or disabled unifykey symbols.
    ${pkgs.python3}/bin/python3 - "$out/common_drivers/drivers/mmc/host/mmc_key.c" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
old = """\tif (register_unifykey_types(uk_type)) {\n\t\t*retp = -EINVAL;\n\t\tpr_info(\"%s:%d,emmc key check fail\\n\", __func__, __LINE__);\n\t\tgoto exit_err1;\n\t}\n\tpr_info(\"emmc key: %s:%d ok.\\n\", __func__, __LINE__);\n\n\tauto_attach();\n"""
new = """\tif (IS_REACHABLE(CONFIG_AMLOGIC_EFUSE_UNIFYKEY)) {\n\t\tif (register_unifykey_types(uk_type)) {\n\t\t\t*retp = -EINVAL;\n\t\t\tpr_info(\"%s:%d,emmc key check fail\\n\", __func__, __LINE__);\n\t\t\tgoto exit_err1;\n\t\t}\n\t\tpr_info(\"emmc key: %s:%d ok.\\n\", __func__, __LINE__);\n\n\t\tauto_attach();\n\t} else {\n\t\tpr_info(\"emmc key: unifykey support disabled, skip registration\\n\");\n\t}\n"""
if old not in text:
    raise SystemExit("failed to patch mmc_key.c")
path.write_text(text.replace(old, new, 1))
PY
    # hdmitx_common.c includes efuse.h even when CONFIG_AMLOGIC_EFUSE=n.
    # In that case the vendor header emits non-inline fallback stubs, and
    # GCC 13 trips -Wunused-function under the vendor Werror settings while
    # building hdmitx_common.o. Make those stubs inline so the header stays
    # harmless when nothing calls them.
    substituteInPlace $out/common_drivers/drivers/efuse_unifykey/efuse.h \
      --replace-fail 'static int __init aml_efuse_init(void)' 'static inline int aml_efuse_init(void)' \
      --replace-fail 'static void aml_efuse_exit(void)' 'static inline void aml_efuse_exit(void)'

    # The vendor BCMDHD driver assumes an in-tree non-O= build and sets
    # BCMDHD_ROOT = $(src). In our linuxManualConfig/O= build, the actual source
    # tree lives under $(srctree), so plain $(src)/include still points at the
    # object tree and local Broadcom headers like <typedefs.h> are not found.
    # Rewrite both BCMDHD_ROOT and the Kbuild include flags to anchor them to
    # $(srctree)/$(src).
    ${pkgs.python3}/bin/python3 - "$out/drivers/net/wireless/bcmdhd/Makefile" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
root_needle = 'BCMDHD_ROOT = $(src)\n'
root_insert = 'BCMDHD_ROOT := $(srctree)/$(src)\n'
if 'BCMDHD_ROOT := $(srctree)/$(src)' not in text:
    if root_needle not in text:
        raise SystemExit("failed to patch BCMDHD_ROOT")
    text = text.replace(root_needle, root_insert, 1)

flags_needle = 'ccflags-y := $(EXTRA_CFLAGS)\n'
flags_insert = 'ccflags-y := $(EXTRA_CFLAGS) -I$(srctree)/$(src)/include -I$(srctree)/$(src)\nsubdir-ccflags-y += -I$(srctree)/$(src)/include -I$(srctree)/$(src)\n'
if 'ccflags-y := $(EXTRA_CFLAGS) -I$(srctree)/$(src)/include -I$(srctree)/$(src)' not in text:
    if flags_needle not in text:
        raise SystemExit("failed to patch BCMDHD Makefile include paths")
    text = text.replace(flags_needle, flags_insert, 1)
path.write_text(text)
PY
  '';
  localDtOverlayDir = ../files/dtb;
  dtbOverlayEnv = pkgs.writeText "kvim1s.dtb.overlay.env" ''
    fdt_overlays=
  '';
  neutralUEnv = pkgs.writeText "vim1s-uEnv.txt" ''
    fdtfile=amlogic/kvim1s.dtb
    overlays=
    fdt_overlays=
  '';
  vim1sWirelessFirmwareCompat = pkgs.runCommand "vim1s-wireless-firmware-compat" {
    nativeBuildInputs = [ pkgs.xz ];
  } ''
    mkdir -p "$out/lib/firmware/brcm" "$out/lib/firmware"

    copy_fw() {
      local dst="$1"
      shift
      local src
      for src in "$@"; do
        if [ -f "$src" ] || [ -f "$src.xz" ]; then
          if [ ! -f "$src" ] && [ -f "$src.xz" ]; then
            src="$src.xz"
          fi
          case "$src" in
            *.xz)
              xz -dc "$src" > "$dst"
              ;;
            *)
              cp "$src" "$dst"
              ;;
          esac
          chmod 0644 "$dst"
          return 0
        fi
      done
      echo "missing firmware source for $dst" >&2
      exit 1
    }

    copy_fw "$out/lib/firmware/brcm/BCM4345C5.hcd" \
      ${pkgs.armbian-firmware}/lib/firmware/brcm/BCM4345C5.hcd

    copy_fw "$out/lib/firmware/brcm/fw_bcm43456c5_ag.bin" \
      ${pkgs.armbian-firmware}/lib/firmware/brcm/fw_bcm43456c5_ag.bin

    copy_fw "$out/lib/firmware/brcm/fw_bcm43456c5_ag_apsta.bin" \
      ${pkgs.armbian-firmware}/lib/firmware/brcm/fw_bcm43456c5_ag_apsta.bin

    copy_fw "$out/lib/firmware/brcm/config_bcm43456c5_ag.txt" \
      ${pkgs.armbian-firmware}/lib/firmware/brcm/config_bcm43456c5_ag.txt

    copy_fw "$out/lib/firmware/brcm/clm_bcm43456c5_ag.blob" \
      ${pkgs.armbian-firmware}/lib/firmware/brcm/brcmfmac43456-sdio.clm_blob \
      ${pkgs.linux-firmware}/lib/firmware/brcm/brcmfmac43456-sdio.clm_blob

    copy_fw "$out/lib/firmware/brcm/nvram_ap6256.txt" \
      ${pkgs.armbian-firmware}/lib/firmware/brcm/nvram_ap6256.txt

    copy_fw "$out/lib/firmware/brcm/brcmfmac43456-sdio.bin" \
      ${pkgs.armbian-firmware}/lib/firmware/brcm/brcmfmac43456-sdio.bin

    copy_fw "$out/lib/firmware/brcm/brcmfmac43456-sdio.clm_blob" \
      ${pkgs.armbian-firmware}/lib/firmware/brcm/brcmfmac43456-sdio.clm_blob

    copy_fw "$out/lib/firmware/brcm/brcmfmac43456-sdio.txt" \
      ${pkgs.armbian-firmware}/lib/firmware/brcm/brcmfmac43456-sdio.txt

    copy_fw "$out/lib/firmware/regulatory.db" \
      ${pkgs.wireless-regdb}/lib/firmware/regulatory.db

    copy_fw "$out/lib/firmware/regulatory.db.p7s" \
      ${pkgs.wireless-regdb}/lib/firmware/regulatory.db.p7s
  '';
  bluetoothKhadasScript = pkgs.writeShellScript "bluetooth-khadas.sh" ''
    set -eu

    for _ in $(seq 1 10); do
      [ -e /dev/ttyS1 ] && break
      sleep 1
    done

    ${pkgs.util-linux}/bin/rfkill block bluetooth || ${pkgs.util-linux}/bin/rfkill block 0 || true
    sleep 2
    ${pkgs.util-linux}/bin/rfkill unblock bluetooth || ${pkgs.util-linux}/bin/rfkill unblock 0 || true
    sleep 1

    exec ${pkgs.bluez}/bin/hciattach -n -s 115200 /dev/ttyS1 bcm43xx 2000000
  '';

  # Pre-generate a non-interactive .config from vendor kvims_defconfig to avoid Nix's generate-config loop
  kvimsConfig = pkgs.stdenv.mkDerivation {
    pname = "kvims-config";
    version = "5.15-khadas";
    src = khadasSrc;
    nativeBuildInputs = with pkgs; [ gnumake bc bison flex pkg-config perl ];

    buildPhase = ''
      cp -r $src ./src
      chmod -R u+w ./src
      cd src

      # Ensure kvims_defconfig is discoverable and sanitize line endings
      if [ -f "./common_drivers/arch/arm64/configs/kvims_defconfig" ]; then
        # Copy from read-only nix store symlink to a writable location
        mkdir -p "./arch/arm64/configs"
        cp -f "./common_drivers/arch/arm64/configs/kvims_defconfig" "./arch/arm64/configs/kvims_defconfig"
        sed -i 's/\r$//' "./arch/arm64/configs/kvims_defconfig"
      fi
      for f in ./arch/arm64/Kconfig ./arch/Kconfig ./Kconfig; do
        test -f "$f" && sed -i 's/\r$//' "$f" || true
      done

      # Start from the exact vendor VIMS defconfig. Khadas' own 5.15 build uses
      # kvims_defconfig plus common_drivers; seeding from the generic nixpkgs
      # 5.15 config was pulling in upstream Meson clock/pinctrl/MMC drivers at
      # the same time, which later collided with the vendor common_drivers
      # copies at link time.
      cp ./arch/arm64/configs/kvims_defconfig .config
      chmod u+w .config

      # Minimal fragment to satisfy NixOS boot requirements and keep the VIM1S
      # bring-up path on the vendor Amlogic stack.
      cat >> .config << 'EOF'
CONFIG_DEVTMPFS=y
CONFIG_DEVTMPFS_MOUNT=y
CONFIG_CGROUPS=y
CONFIG_INOTIFY_USER=y
CONFIG_SIGNALFD=y
CONFIG_TIMERFD=y
CONFIG_EPOLL=y
CONFIG_NET=y
CONFIG_SYSFS=y
CONFIG_PROC_FS=y
CONFIG_FHANDLE=y
CONFIG_CRYPTO_USER_API_HASH=y
CONFIG_CRYPTO_HMAC=y
CONFIG_CRYPTO_SHA256=y
CONFIG_REGULATOR=y
CONFIG_REGULATOR_FIXED_VOLTAGE=y
CONFIG_REGULATOR_GPIO=y
CONFIG_AUTOFS_FS=y
CONFIG_TMPFS=y
CONFIG_TMPFS_POSIX_ACL=y
CONFIG_TMPFS_XATTR=y
CONFIG_SECCOMP=y
CONFIG_BLK_DEV_INITRD=y
CONFIG_MODULES=y
CONFIG_BINFMT_ELF=y
CONFIG_UNIX=y
CONFIG_DMI=y
CONFIG_DMIID=y
CONFIG_ARCH_MESON=y

# Use the vendor common_drivers stack for VIM1S instead of the upstream Meson
# clock/pinctrl/MMC implementations. Mixing both trees produces duplicate
# symbols such as meson_clk_pll_ops, clk_regmap_gate_ops, and meson_pmx_*.
# CONFIG_MMC_MESON_GX is not set
# CONFIG_PINCTRL_MESON is not set
# CONFIG_PINCTRL_MESON_GXBB is not set
# CONFIG_PINCTRL_MESON_GXL is not set
# CONFIG_PINCTRL_MESON8_PMX is not set
# CONFIG_PINCTRL_MESON_AXG is not set
# CONFIG_PINCTRL_MESON_AXG_PMX is not set
# CONFIG_PINCTRL_MESON_G12A is not set
# CONFIG_PINCTRL_MESON_A1 is not set
# CONFIG_COMMON_CLK_MESON_REGMAP is not set
# CONFIG_COMMON_CLK_MESON_DUALDIV is not set
# CONFIG_COMMON_CLK_MESON_MPLL is not set
# CONFIG_COMMON_CLK_MESON_PHASE is not set
# CONFIG_COMMON_CLK_MESON_PLL is not set
# CONFIG_COMMON_CLK_MESON_SCLK_DIV is not set
# CONFIG_COMMON_CLK_MESON_VID_PLL_DIV is not set
# CONFIG_COMMON_CLK_MESON_AO_CLKC is not set
# CONFIG_COMMON_CLK_MESON_EE_CLKC is not set
# CONFIG_COMMON_CLK_MESON_CPU_DYNDIV is not set
# CONFIG_COMMON_CLK_GXBB is not set
# CONFIG_COMMON_CLK_AXG is not set
# CONFIG_COMMON_CLK_AXG_AUDIO is not set
# CONFIG_COMMON_CLK_G12A is not set

CONFIG_AMLOGIC_DRIVER=y
CONFIG_AMLOGIC_IN_KERNEL_MODULES=y
CONFIG_AMLOGIC_GPIO=y
CONFIG_AMLOGIC_GPIOLIB=y

# VIM1S uses vendor S4 provider drivers from common_drivers for pinctrl and
# the main clock controller. Without these, the MMC hosts exist in DT but stay
# stuck in deferred probe waiting on fe000000.apb4:pinctrl@4000 and
# fe000000.clock-controller. Build the root-path pieces in rather than as
# modules so the initrd can see the SD card before stage 1 switches root.
CONFIG_AMLOGIC_COMMON_CLK=y
CONFIG_AMLOGIC_COMMON_CLK_MESON_REGMAP=y
CONFIG_AMLOGIC_COMMON_CLK_MESON_DUALDIV=y
CONFIG_AMLOGIC_COMMON_CLK_MESON_MPLL=y
CONFIG_AMLOGIC_COMMON_CLK_MESON_PHASE=y
CONFIG_AMLOGIC_COMMON_CLK_MESON_PLL=y
CONFIG_AMLOGIC_COMMON_CLK_MESON_SCLK_DIV=y
CONFIG_AMLOGIC_COMMON_CLK_MESON_VID_PLL_DIV=y
CONFIG_AMLOGIC_COMMON_CLK_MESON_AO_CLKC=y
CONFIG_AMLOGIC_COMMON_CLK_MESON_EE_CLKC=y
CONFIG_AMLOGIC_COMMON_CLK_MESON_CPU_DYNDIV=y
CONFIG_AMLOGIC_COMMON_CLK_S4=y
# CONFIG_AMLOGIC_COMMON_CLK_SC2 is not set
# CONFIG_AMLOGIC_COMMON_CLK_C2 is not set
# CONFIG_AMLOGIC_COMMON_CLK_C3 is not set
# CONFIG_AMLOGIC_COMMON_CLK_A1 is not set
# CONFIG_AMLOGIC_COMMON_CLK_T3 is not set
# CONFIG_AMLOGIC_COMMON_CLK_T7 is not set
# CONFIG_AMLOGIC_COMMON_CLK_T5M is not set
# CONFIG_AMLOGIC_COMMON_CLK_G12A is not set
# CONFIG_AMLOGIC_COMMON_CLK_S5 is not set
# CONFIG_AMLOGIC_COMMON_CLK_T5W is not set
# CONFIG_AMLOGIC_COMMON_CLK_T3X is not set
# CONFIG_AMLOGIC_COMMON_CLK_TXHD2 is not set
# CONFIG_AMLOGIC_COMMON_CLK_C1 is not set
# CONFIG_AMLOGIC_COMMON_CLK_S1A is not set
# CONFIG_AMLOGIC_COMMON_CLK_T5D is not set
# CONFIG_AMLOGIC_COMMON_CLK_TM2 is not set
# CONFIG_AMLOGIC_COMMON_CLK_S7 is not set
# CONFIG_AMLOGIC_COMMON_CLK_S7D is not set
CONFIG_AMLOGIC_PINCTRL_MESON=y
CONFIG_AMLOGIC_PINCTRL_MESON_S4=y
# CONFIG_AMLOGIC_PINCTRL_MESON_C2 is not set
# CONFIG_AMLOGIC_PINCTRL_MESON_C3 is not set
# CONFIG_AMLOGIC_PINCTRL_MESON_A1 is not set
# CONFIG_AMLOGIC_PINCTRL_MESON_SC2 is not set
# CONFIG_AMLOGIC_PINCTRL_MESON_T3 is not set
# CONFIG_AMLOGIC_PINCTRL_MESON_T7 is not set
# CONFIG_AMLOGIC_PINCTRL_MESON_T5M is not set
# CONFIG_AMLOGIC_PINCTRL_MESON_G12A is not set
# CONFIG_AMLOGIC_PINCTRL_MESON_S5 is not set
# CONFIG_AMLOGIC_PINCTRL_MESON_T5W is not set
# CONFIG_AMLOGIC_PINCTRL_MESON_T3X is not set
# CONFIG_AMLOGIC_PINCTRL_MESON_TXHD2 is not set
# CONFIG_AMLOGIC_PINCTRL_MESON_C1 is not set
# CONFIG_AMLOGIC_PINCTRL_MESON_S1A is not set
# CONFIG_AMLOGIC_PINCTRL_MESON_T5D is not set
# CONFIG_AMLOGIC_PINCTRL_MESON_TM2 is not set
# CONFIG_AMLOGIC_PINCTRL_MESON_S7 is not set
# CONFIG_AMLOGIC_PINCTRL_MESON_S7D is not set
CONFIG_AMLOGIC_MMC_MESON_GX=y
# CONFIG_MMC_CQHCI is not set
# CONFIG_AMLOGIC_MMC_CQHCI is not set
# Keep the vendor efuse provider modular. stmmac-platform.ko reads MAC data via
# efuse_user_attr_read(), and aml_media.ko pulls efuse_obj_read() from the same
# driver. The header stub warning was fixed above, so we can enable the real
# provider again without reintroducing the earlier GCC 13 failure.
CONFIG_AMLOGIC_EFUSE_UNIFYKEY=m
CONFIG_AMLOGIC_EFUSE=y
CONFIG_AMLOGIC_UNIFYKEY=y
# CONFIG_AMLOGIC_DEFENDKEY is not set

# Keep boot-critical storage and pinctrl paths built in, but leave the
# broader Ethernet and display/media stacks in the vendor modular shape.
# Khadas' own kvims_defconfig expects those helpers to live in .ko files;
# forcing them into vmlinux drags in Android-era TEE/media dependencies and
# explodes the final link. The real fix is to let linuxManualConfig parse
# CONFIG_MODULES=y and produce a proper modules output.
CONFIG_STMMAC_ETH=m
CONFIG_STMMAC_PLATFORM=m
CONFIG_DWMAC_MESON=m
# The upstream Meson G12A MDIO mux driver aliases the same DT node as the
# vendor amlogic-mdio-g12a module. Ubuntu's working VIM1S image keeps only the
# vendor path enabled. If both are modular, the upstream one can bind first and
# leave Ethernet stuck without a usable MAC device.
# CONFIG_MDIO_BUS_MUX_MESON_G12A is not set
CONFIG_AMLOGIC_MDIO_G12A=m
CONFIG_AMLOGIC_MEDIA_MODULE=m
CONFIG_AMLOGIC_MEDIA_UTILS=m
CONFIG_AMLOGIC_DRM=m
CONFIG_AMLOGIC_SECMON=m
CONFIG_AMLOGIC_CPU_INFO=m
CONFIG_BCMDHD=m
CONFIG_BCMDHD_FW_PATH="/lib/firmware/brcm/"
CONFIG_BCMDHD_NVRAM_PATH="/lib/firmware/brcm/"
CONFIG_BCMDHD_SDIO=y
# CONFIG_BCMDHD_PCIE is not set
# CONFIG_BCMDHD_USB is not set
CONFIG_BCMDHD_OOB=y
# CONFIG_BCMDHD_SDIO_IRQ is not set
# CONFIG_AMLOGIC_NPU is not set

# Fix link error from hid-core referencing uhid_hid_driver:
# Build UHID into the kernel so hid-core can reference it.
CONFIG_UHID=y

# Tame BTF/pahole issues with toolchain: keep DWARF v4 and disable BTF.
CONFIG_DEBUG_INFO=y
CONFIG_DEBUG_INFO_DWARF4=y
# CONFIG_DEBUG_INFO_DWARF5 is not set
CONFIG_DEBUG_INFO_BTF=n
CONFIG_DEBUG_INFO_BTF_MODULES=n
# Support NixOS initrd compression (ZSTD used by default)
CONFIG_RD_ZSTD=y
CONFIG_RD_GZIP=y
CONFIG_RD_LZ4=y

# Device-mapper (LVM) support in kernel to avoid initrd DM errors
CONFIG_MD=y
CONFIG_BLK_DEV_DM=y

# Expose kernel config for verification
CONFIG_IKCONFIG=y
CONFIG_IKCONFIG_PROC=y
EOF

      # Reconcile config non-interactively (avoid piping `yes`, which trips pipefail)
      make ARCH=arm64 olddefconfig

      echo "VIM1S kernel config summary:"
      grep -E '^(CONFIG_AMLOGIC_COMMON_CLK_S4|CONFIG_AMLOGIC_PINCTRL_MESON_S4|CONFIG_AMLOGIC_MMC_MESON_GX)=' .config || true
      grep -E '^(CONFIG_MDIO|CONFIG_STMMAC_ETH|CONFIG_STMMAC_PLATFORM|CONFIG_DWMAC_MESON|CONFIG_AMLOGIC_MDIO_G12A)=' .config || true
      grep -E '^(# CONFIG_MDIO_BUS_MUX_MESON_G12A is not set)$' .config || true
      grep -E '^(CONFIG_AMLOGIC_MEDIA_MODULE|CONFIG_AMLOGIC_MEDIA_UTILS|CONFIG_AMLOGIC_DRM|CONFIG_AMLOGIC_HDMITX|CONFIG_AMLOGIC_VPU|CONFIG_AMLOGIC_VOUT|CONFIG_AMLOGIC_SECMON|CONFIG_AMLOGIC_CPU_INFO)=' .config || true
      grep -E '^(CONFIG_AMLOGIC_EFUSE_UNIFYKEY|CONFIG_AMLOGIC_EFUSE|CONFIG_AMLOGIC_UNIFYKEY)=' .config || true
      grep -E '^(CONFIG_BCMDHD|# CONFIG_AMLOGIC_NPU is not set)' .config || true
      grep -E '^(CONFIG_REGULATOR_GPIO)=' .config || true
      grep -E '^(# CONFIG_(COMMON_CLK_GXBB|COMMON_CLK_AXG|COMMON_CLK_AXG_AUDIO|COMMON_CLK_G12A|PINCTRL_MESON|MMC_MESON_GX|MMC_CQHCI) is not set)$' .config || true

      # Fail fast if olddefconfig re-enables the upstream Meson providers or if
      # the vendor S4 root-path drivers are not built in. Only the SD boot path
      # is required here; Ethernet/DRM/media should remain modular like the
      # vendor defconfig once linuxManualConfig is allowed to install modules.
      for line in \
        'CONFIG_AMLOGIC_COMMON_CLK_S4=y' \
        'CONFIG_AMLOGIC_PINCTRL_MESON_S4=y' \
        'CONFIG_AMLOGIC_MMC_MESON_GX=y' \
        'CONFIG_REGULATOR_GPIO=y' \
        '# CONFIG_COMMON_CLK_GXBB is not set' \
        '# CONFIG_COMMON_CLK_AXG is not set' \
        '# CONFIG_COMMON_CLK_AXG_AUDIO is not set' \
        '# CONFIG_COMMON_CLK_G12A is not set' \
        '# CONFIG_PINCTRL_MESON is not set' \
        '# CONFIG_MMC_MESON_GX is not set' \
        '# CONFIG_MMC_CQHCI is not set' \
        'CONFIG_AMLOGIC_EFUSE_UNIFYKEY=m' \
        'CONFIG_AMLOGIC_EFUSE=y' \
        'CONFIG_AMLOGIC_UNIFYKEY=y'
      do
        grep -qxF "$line" .config || {
          echo "Unexpected kernel config: missing '$line'" >&2
          exit 1
        }
      done
      grep -q '^# CONFIG_MDIO_BUS_MUX_MESON_G12A is not set$' .config

      # AMLOGIC_MMC_CQHCI depends on MMC_CQHCI. Once MMC_CQHCI is forced off,
      # olddefconfig may omit the vendor symbol entirely instead of emitting an
      # explicit '# CONFIG_AMLOGIC_MMC_CQHCI is not set' line.
      if grep -q '^CONFIG_AMLOGIC_MMC_CQHCI=' .config; then
        echo "Unexpected kernel config: AMLOGIC_MMC_CQHCI is still enabled" >&2
        exit 1
      fi

      # Wireless support should follow the vendor Ubuntu BSP here: keep BCMDHD
      # enabled for the AP6256 combo module, but continue to leave the broken
      # vendor NPU disabled until its include wiring is fixed separately.
      grep -qxF 'CONFIG_BCMDHD=m' .config || {
        echo "Unexpected kernel config: BCMDHD is not enabled as a module" >&2
        exit 1
      }
      if grep -q '^CONFIG_AMLOGIC_NPU=' .config; then
        echo "Unexpected kernel config: AMLOGIC_NPU is still enabled" >&2
        exit 1
      fi
    '';

    installPhase = ''
      install -Dm0644 .config $out/.config
    '';
  };

  # Build kernel using the pre-generated .config to bypass interactive Q&A and repeated-question failures
  khadasKernel = pkgs.linuxManualConfig {
    # Match the upstream kernel's reported version to satisfy nixpkgs checks
    version = "5.15.137";
    modDirVersion = "5.15.137";
    src = khadasSrc;
    configfile = "${kvimsConfig}/.config";
    allowImportFromDerivation = true;
    extraMeta.branch = "5.15";
  };

  # Khadas ships many VIM1S overlays, but the working Ubuntu image leaves
  # fdt_overlays empty by default. Keep the base board DTB minimal during
  # bring-up and opt into these overlays later once Ethernet/DRM/Wi-Fi are
  # stable.
  overlayNames = [ ];

  # Optional: include a signed U-Boot blob from repo root (for embedding via sdImage.postBuildCommands)
  uBootSigned =
    let p = ../u-boot.bin.sd.bin.signed.new; in
    if builtins.pathExists p then p else null;

  # Optional: prebuilt chainload U-Boot (u-boot.ext) placed at repo root.
  # Use this to avoid compiling vendor U-Boot with a modern toolchain.
  uBootExtPrebuilt =
    let p = ../u-boot.ext; in
    if builtins.pathExists p then p else null;

  dtbPackage = pkgs.stdenv.mkDerivation {
    pname = "kvim1s-dtb";
    version = "5.15-khadas";
    src = khadasSrc;
    nativeBuildInputs = with pkgs; [ gnumake pkg-config gawk bc bison flex dtc gcc python3 ];
    buildPhase = ''
      cp -r $src ./src
      chmod -R u+w ./src
      cd src

      # Preprocess the vendor DTS, but disable GCC's built-in host OS macros.
      # Without -undef, GCC expands node names like "linux,secmon" into
      # "1,secmon", which breaks the reserved-memory nodes that vendor U-Boot
      # expects. Using the vendor source here keeps the original labels and
      # phandle references intact, unlike the decompiled local DTS fallback.
      ${pkgs.gcc}/bin/gcc -E -P -undef -x assembler-with-cpp -D__DTS__ -nostdinc \
        -I ./include \
        -I ./include/dt-bindings \
        -I ./arch/arm64/boot/dts \
        -I ./arch/arm64/boot/dts/amlogic \
        -I ./common_drivers/include \
        -I ./common_drivers/arch/arm64/boot/dts \
        ./common_drivers/arch/arm64/boot/dts/amlogic/kvim1s.dts > kvim1s.pp.dts

      # 2) Compile base DTB
      ${pkgs.dtc}/bin/dtc -I dts -O dtb -@ -b 0 -o kvim1s.dtb kvim1s.pp.dts

      # 3) Compile optional vendor overlays, plus the local bring-up overlays used
      # to disable OP-TEE and force early UART visibility on VIM1S.
      overlays=""
      overlay_dir='${dt-overlays}/overlays/vim1s/5.4'
      if [ -n "${builtins.concatStringsSep " " overlayNames}" ]; then
        for ov in ${builtins.concatStringsSep " " overlayNames}; do
          src="$overlay_dir/$ov.dts"
          if [ ! -f "$src" ]; then
            echo "Overlay '$ov' not found at $src" >&2
            exit 1
          fi
          # Preprocess and compile overlay to .dtbo
          ${pkgs.gcc}/bin/gcc -E -P -x assembler-with-cpp -D__DTS__ -nostdinc \
            -I ./include \
            -I ./include/dt-bindings \
            -I ./arch/arm64/boot/dts \
            -I ./arch/arm64/boot/dts/amlogic \
            -I ./common_drivers/include \
            -I ./common_drivers/arch/arm64/boot/dts \
            -I "$overlay_dir" \
            "$src" > "$ov.pp.dts"
          ${pkgs.dtc}/bin/dtc -I dts -O dtb -@ -o "$ov.dtbo" "$ov.pp.dts"
          overlays="$overlays $ov.dtbo"
        done
      fi

      for src in \
        ${localDtOverlayDir}/disable-optee.dts \
        ${localDtOverlayDir}/console-stdout.dts \
        ${localDtOverlayDir}/ethernet-inphy.dts; do
        ov="$(basename "$src" .dts)"
        ${pkgs.dtc}/bin/dtc -I dts -O dtb -@ -o "$ov.dtbo" "$src"
        overlays="$overlays $ov.dtbo"
      done

      if [ -n "$overlays" ]; then
        ${pkgs.dtc}/bin/fdtoverlay -i kvim1s.dtb -o kvim1s.merged.dtb $overlays
        mv kvim1s.merged.dtb kvim1s.dtb
      fi

      # Vendor U-Boot mutates reserved-memory properties in-place before booti.
      # fdtoverlay writes a tightly packed blob, so leave explicit headroom for
      # those updates or U-Boot hits FDT_ERR_NOSPACE and passes an incomplete DT.
      ${pkgs.dtc}/bin/dtc -I dtb -O dtb -p 0x20000 -o kvim1s.padded.dtb kvim1s.dtb
      mv kvim1s.padded.dtb kvim1s.dtb
    '';
    installPhase = ''
      install -Dm0644 kvim1s.dtb $out/amlogic/kvim1s.dtb
      install -Dm0644 ${dtbOverlayEnv} $out/amlogic/kvim1s.dtb.overlay.env
      if ls *.dtbo >/dev/null 2>&1; then
        mkdir -p $out/amlogic/overlays
        install -m0644 *.dtbo $out/amlogic/overlays/
      fi
    '';
  };

  # Use vendor Khadas 5.15 kernel packages built above. Once
  # allowImportFromDerivation lets linuxManualConfig see CONFIG_MODULES=y, the
  # kernel derivation exposes proper out/dev/modules outputs by itself.
  kernelPkgs = pkgs.linuxPackagesFor khadasKernel;
in
{
  nixpkgs.hostPlatform = lib.mkDefault "aarch64-linux";
  nixpkgs.config.allowUnfree = true;
  # Temporarily bypass NixOS kernel config assertions during bring-up of the vendor kernel.
  # We will re-enable after confirming the final .config satisfies all required flags.
  system.requiredKernelConfig = lib.mkForce [ ];
  # Do not build/embed U-Boot during kernel bring-up; avoid defconfig loops and rely on
  # existing SPI/eMMC loader or the signed SD blob (u-boot.bin.sd.bin.signed.new).
  # Avoid building U-Boot for now (vendor tree fails with modern GCC). We still embed
  # a u-boot.ext if provided at repo root (uBootExtPrebuilt) so chainload works.
  # Avoid building vendor U-Boot for now; rely on signed SD blob embedding to unblock image build.
  khadas.ubootVim1s.enable = true;
  khadas.ubootVim1s.embedInBoot = true;
  khadas.ubootVim1s.defconfig = "kvim1s_defconfig";

  
  boot = {
    kernelPackages = kernelPkgs;
    extraModulePackages = lib.mkForce [ ];
    growPartition = false;

    # Khadas vendor U-Boot scans /boot/extlinux/extlinux.conf from the rootfs.
    loader.generic-extlinux-compatible.enable = true;
    loader.generic-extlinux-compatible.configurationLimit = 1;

    # Keep bring-up on the serial console only. The vendor kernel registers the
    # main UART as ttyS0, so use that for the real Linux console and serial
    # getty. Earlycon still comes from the DT stdout-path.
    kernelParams = lib.mkForce [
      "console=ttyS0,115200n8"
      "console=tty0"
      "earlycon"
      "keep_bootcon"
      "ignore_loglevel"
      "initcall_debug"
      "meson_gx_mmc.dyndbg=+p"
      "optee.disable=1"
      "arm_ffa.disable=1"
    ];

    # Keep initrd narrow; the boot-critical MMC/clock/pinctrl path is built in.
    # Runtime devices such as Ethernet and display can load from the rootfs
    # module tree after switch_root.
    #
    # The vendor 5.15 kernel reports the default zstd-compressed NixOS initrd
    # as corrupt at boot and then stage 1 loses files from /nix/store. Use
    # gzip for bring-up until we can prove zstd is safe on this board.
    initrd.compressor = lib.mkForce "gzip";
    initrd.includeDefaultModules = lib.mkForce false;
    initrd.availableKernelModules = lib.mkForce [ ];
    initrd.kernelModules = lib.mkForce [ ];

    # Stage 2 currently panics when udev auto-loads the vendor DRM stack.
    # Keep the board headless until the aml_drm/aml_media bind path is debugged.
    #
    # Also block the upstream mdio_mux_meson_g12a helper. Ubuntu's working VIM1S
    # image uses the vendor amlogic_mdio_g12a path instead, and letting both
    # claim the same DT alias leaves Ethernet without a usable MAC device.
    blacklistedKernelModules = [ "aml_drm" "mdio_mux_meson_g12a" "brcmfmac" ];

    # Match the working Ubuntu runtime more closely: bring up the Amlogic
    # mailbox service before the vendor Ethernet stack. Live probing on the
    # board shows that loading amlogic_mailbox immediately clears the repeated
    # -EPROBE_DEFER loop for the MDIO mux, Ethernet MAC and HDMI CEC nodes.
    kernelModules = [ "amlogic_mailbox" "dwmac_meson8b" "amlogic_mdio_g12a" "amlogic-wireless" "dhd" ];

    # Keep the vendor MDIO mux from racing ahead of the DWMAC side during
    # coldplug, and make the mailbox provider available before both. Without
    # the mailbox service, the board spins on deferred probes for
    # fe028000.mdio-multiplexer, fdc00000.ethernet and fe044000.aocec.
    extraModprobeConfig = ''
      softdep dwmac_meson8b pre: amlogic_mailbox
      softdep amlogic_mdio_g12a pre: amlogic_mailbox stmmac stmmac_platform dwmac_meson8b
      softdep dhd pre: amlogic-wireless cfg80211
      options dhd firmware_path=/run/current-system/firmware/brcm/ nvram_path=/run/current-system/firmware/brcm/
    '';
  };

  # Device tree: install our vendor-built DTB and reference it
  hardware.deviceTree = {
    enable = true;
    package = lib.mkForce dtbPackage;
    name = "amlogic/kvim1s.dtb";
  };

  # Firmware (Wi-Fi/BT/etc.)
  hardware.firmware = [ pkgs.linux-firmware vim1sWirelessFirmwareCompat ];
  # Khadas' vendor Broadcom stack passes explicit firmware filenames into
  # request_firmware(). On NixOS 25.11 the default xz-compressed firmware tree
  # leaves only *.xz entries under /run/current-system/firmware, which dhd and
  # hciattach do not handle. Keep this board on an uncompressed firmware tree.
  hardware.firmwareCompression = lib.mkForce "none";
  hardware.enableRedistributableFirmware = true;
  hardware.bluetooth.enable = true;
  environment.etc."firmware".source = "${vim1sWirelessFirmwareCompat}/lib/firmware/brcm";

  # Filesystems we want in userspace/initrd
  boot.supportedFilesystems = [ "vfat" "ext4" "btrfs" "f2fs" ];

  # The current blocker is that stage 1 never sees an mmcblk root device.
  # Dump the initrd's device view to UART right after udev/LVM settle so the
  # next boot log tells us whether the SD host failed to bind, enumerated under
  # a different mmc index, or appeared without partitions.
  boot.initrd.postDeviceCommands = lib.mkAfter ''
    echo "===== initrd device debug: /dev/mmc* ====="
    ls -l /dev/mmc* 2>/dev/null || echo "no /dev/mmc* nodes"
    echo "===== initrd device debug: /sys/class/mmc_host ====="
    ls -l /sys/class/mmc_host 2>/dev/null || echo "no /sys/class/mmc_host"
    for host in /sys/class/mmc_host/mmc*; do
      [ -e "$host" ] || continue
      echo "--- $host ---"
      ls -l "$host"
      if [ -r "$host"/uevent ]; then
        cat "$host"/uevent
      fi
    done
    echo "===== initrd device debug: /dev/disk ====="
    find /dev/disk -maxdepth 3 -type l 2>/dev/null | sort | while read -r link; do
      ls -l "$link"
    done
    echo "===== initrd device debug: platform devices ====="
    find /sys/bus/platform/devices -maxdepth 1 -type l 2>/dev/null | grep -E 'fe000000|fe08(8|a|c)000|mmc|sd|pinctrl|clock' || echo "no matching platform devices"
    echo "===== initrd device debug: meson-gx-mmc driver ====="
    ls -l /sys/bus/platform/drivers/meson-gx-mmc 2>/dev/null || echo "meson-gx-mmc driver not registered"
    echo "===== initrd device debug: provider drivers ====="
    ls -l /sys/bus/platform/drivers/amlogic-pinctrl-soc-s4 2>/dev/null || echo "amlogic-pinctrl-soc-s4 driver not registered"
    ls -l /sys/bus/platform/drivers/s4-clkc 2>/dev/null || echo "s4-clkc driver not registered"
    echo "===== initrd device debug: proc device-tree ====="
    for node in \
      /proc/device-tree/soc/apb4@fe000000/clock-controller \
      /proc/device-tree/soc/apb4@fe000000/pinctrl@4000 \
      /proc/device-tree/soc/sd@fe08a000 \
      /proc/device-tree/soc/mmc@fe08c000 \
      /proc/device-tree/soc/sdio@fe088000; do
      [ -d "$node" ] || continue
      echo "--- $node ---"
      [ -r "$node/status" ] && (printf 'status='; tr -d '\000' < "$node/status"; echo)
      [ -r "$node/compatible" ] && (printf 'compatible='; tr -d '\000' < "$node/compatible"; echo)
    done
    if mount -t debugfs none /sys/kernel/debug 2>/dev/null; then
      echo "===== initrd device debug: deferred probe ====="
      cat /sys/kernel/debug/devices_deferred 2>/dev/null || echo "no deferred devices list"
    fi
    echo "===== initrd device debug: dmesg (mmc/pinctrl/clk) ====="
    dmesg | grep -Ei 'mmc|meson-gx-mmc|pinctrl|clkc|fe000000|fe08[8ac]000|sd@fe08a000|mmcblk' || echo "no mmc-related dmesg lines"
    echo "===== initrd device debug end ====="
  '';

  # On the current VIM1S bring-up logs the internal eMMC is mmcblk0 and the
  # removable SD card is mmcblk1. Use the raw SD block nodes for now so stage 1
  # does not depend on udev creating /dev/disk/by-label before it can mount
  # root. We can switch back to a more abstract identifier after initrd userspace
  # is stable on this board.
  fileSystems."/" = lib.mkForce {
    device = "/dev/mmcblk1p2";
    fsType = "ext4";
    options = [ "x-initrd.mount" ];
  };

  fileSystems."/boot/firmware" = lib.mkForce {
    device = "/dev/mmcblk1p1";
    fsType = "vfat";
    options = [ "nofail" "noauto" ];
  };

  # Minimal useful services on first boot
  services.openssh.enable = true;
  services.getty.autologinUser = lib.mkDefault "nixos";
  systemd.services."serial-getty@ttyS0".enable = true;
  systemd.services.bluetooth-khadas = {
    description = "Khadas Bluetooth attach service";
    after = [ "systemd-modules-load.service" ];
    before = [ "bluetooth.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "simple";
      ExecStart = bluetoothKhadasScript;
      Restart = "on-failure";
      RestartSec = "2s";
    };
  };

  users.users.nixos = {
    isNormalUser = true;
    extraGroups = [ "wheel" "networkmanager" ];
    initialPassword = "nixos";
  };
  users.users.root.initialPassword = "root";
  security.sudo.wheelNeedsPassword = false;

  networking.networkmanager.enable = true;
  time.timeZone = "UTC";

  # Pin stateVersion to avoid warnings and ensure stable defaults
  system.stateVersion = "24.05";

  # Smaller image for bring-up
  documentation.nixos.enable = false;

  # sd-image tweaks (base module imported in flake)
  sdImage = {
    imageBaseName = "nixos-vim1s";
    compressImage = true;

    # Override the Raspberry Pi firmware defaults from sd-image-aarch64.nix.
    populateFirmwareCommands = lib.mkForce ''
      mkdir -p firmware/dtb/amlogic
      install -m0644 ${dtbPackage}/amlogic/kvim1s.dtb firmware/dtb/amlogic/kvim1s.dtb
      install -m0644 ${dtbOverlayEnv} firmware/dtb/amlogic/kvim1s.dtb.overlay.env
    '';

    populateRootCommands = lib.mkForce ''
      mkdir -p ./files/boot
      ${config.boot.loader.generic-extlinux-compatible.populateCmd} -c ${config.system.build.toplevel} -d ./files/boot

      mkdir -p ./files/boot/dtb/amlogic
      install -m0644 ${dtbPackage}/amlogic/kvim1s.dtb ./files/boot/dtb/amlogic/kvim1s.dtb
      install -m0644 ${dtbOverlayEnv} ./files/boot/dtb/amlogic/kvim1s.dtb.overlay.env
      install -m0644 ${neutralUEnv} ./files/boot/uEnv.txt

      if ! grep -q '^  FDT ' ./files/boot/extlinux/extlinux.conf; then
        echo "Expected an explicit FDT entry in extlinux.conf" >&2
        exit 1
      fi

      # Keep extlinux on the rootfs, but point vendor U-Boot at a stable board DTB alias.
      sed -i 's|^  FDT .*|  FDT ../dtb/amlogic/kvim1s.dtb|' ./files/boot/extlinux/extlinux.conf
    '';

    # Post-process: (1) optionally embed a signed U‑Boot blob into the SD image's MBR area
    # (2) optionally embed u-boot.ext into the FAT boot partition using mtools without mounting.
    postBuildCommands = lib.mkAfter (
      (lib.optionalString (uBootSigned != null) ''
        echo "Embedding signed U-Boot into $img from ${uBootSigned}"
        # Write MBR region
        dd if=${uBootSigned} of=$img bs=1 count=442 conv=fsync,notrunc
        # Write the rest of the image after the MBR
        dd if=${uBootSigned} of=$img bs=512 skip=1 seek=1 conv=fsync,notrunc
      '')
      +
      (lib.optionalString config.khadas.ubootVim1s.embedInBoot (
        (lib.optionalString (uBootExtPrebuilt != null) ''
          echo "Embedding prebuilt u-boot.ext into FAT boot partition"
          BOOT_START=$(${pkgs.parted}/bin/parted -sm "$img" unit B print | awk -F: '/^1:/ { sub(/B$/,"",$2); print $2 }')
          ${pkgs.mtools}/bin/mcopy -i "$img@@$BOOT_START" ${uBootExtPrebuilt} ::/u-boot.ext
        '')
        +
        (lib.optionalString (config ? system && config.system ? build && config.system.build ? ubootVim1s) ''
          if [ -e ${config.system.build.ubootVim1s}/u-boot/u-boot.ext ]; then
            echo "Embedding built u-boot.ext from system.build.ubootVim1s into FAT boot partition"
            BOOT_START=$(${pkgs.parted}/bin/parted -sm "$img" unit B print | awk -F: '/^1:/ { sub(/B$/,"",$2); print $2 }')
            ${pkgs.mtools}/bin/mcopy -i "$img@@$BOOT_START" ${config.system.build.ubootVim1s}/u-boot/u-boot.ext ::/u-boot.ext
          fi
        '')
      ))
    );
  };

  # Handy tools onboard
  environment.systemPackages = with pkgs; [
    vim
    htop
    ethtool
    iw
    bluez
    alsa-utils
    v4l-utils
    libgpiod
    strace
    lsof
    usbutils
    pciutils
    ubootTools
  ];

  # Make serial console friendlier during bring-up
  console = {
    enable = true;
    earlySetup = true;
    keyMap = "us";
    font = null;
  };

  # Reduce kernel log noise
  boot.kernel.sysctl."kernel.printk" = "7 4 1 7";
}
