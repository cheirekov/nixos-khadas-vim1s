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

      # Seed .config from nixpkgs 5.15 kernel config (meets NixOS requirements), then adapt to Khadas vendor Kconfig
      cp ${pkgs.linuxPackages_5_15.kernel.configfile} .config
      chmod u+w .config

      # Minimal fragment to satisfy NixOS kernel assertions
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
# Ensure Amlogic Meson platform is enabled in vendor tree
CONFIG_ARCH_MESON=y
CONFIG_AMLOGIC_DRIVER=y
CONFIG_AMLOGIC_IN_KERNEL_MODULES=y
CONFIG_AMLOGIC_GPIO=y

# VIM1S uses vendor S4 provider drivers from common_drivers for pinctrl and
# the main clock controller. Without these, the MMC hosts exist in DT but stay
# stuck in deferred probe waiting on fe000000.apb4:pinctrl@4000 and
# fe000000.clock-controller.
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
CONFIG_AMLOGIC_PINCTRL_MESON=y
CONFIG_AMLOGIC_PINCTRL_MESON_S4=y

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
    extraMeta.branch = "5.15";
  };

  overlayNames = [ "4k2k_fb" "i2cm_e" "i2s" "onewire" "panfrost" "pwm_f" "spdifout" "spi0" "uart_c" ];

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

      for src in ${localDtOverlayDir}/disable-optee.dts ${localDtOverlayDir}/console-stdout.dts; do
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

  # Use vendor Khadas 5.15 kernel packages built above.
  # Provide a 'dev' attribute pointing to the kernel's default output so external
  # module builders (e.g. ZFS) can locate /lib/modules/${modDirVersion}/{source,build}.
  kernelPkgs = pkgs.linuxPackagesFor (khadasKernel // { dev = khadasKernel; });
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

    # Khadas vendor U-Boot scans /boot/extlinux/extlinux.conf from the rootfs.
    loader.generic-extlinux-compatible.enable = true;
    loader.generic-extlinux-compatible.configurationLimit = 1;

    # U-Boot leaves UART_B running at 921600, so earlycon stays readable at that
    # rate. The vendor ttyAML driver later reprograms this port from a 24 MHz
    # crystal clock, and 921600 is far enough off to corrupt the runtime serial
    # console. Use 115200 once Linux takes over.
    kernelParams = lib.mkForce [
      "console=ttyAML0,115200n8"
      "console=tty0"
      "earlycon"
      "ignore_loglevel"
      "initcall_debug"
      "meson_gx_mmc.dyndbg=+p"
      "nokaslr"
      "optee=off"
      "optee.disable=1"
      "arm_ffa.disable=1"
    ];

    # Conservative initrd modules; harmless if not present.
    # Kernel was built effectively monolithic (no .ko installed). Avoid initrd
    # module-closure failures by not expecting any modules during bring-up.
    initrd.includeDefaultModules = lib.mkForce false;
    initrd.availableKernelModules = lib.mkForce [ ];
    initrd.kernelModules = lib.mkForce [ ];
  };

  # Device tree: install our vendor-built DTB and reference it
  hardware.deviceTree = {
    enable = true;
    package = lib.mkForce dtbPackage;
    name = "amlogic/kvim1s.dtb";
  };

  # Firmware (Wi-Fi/BT/etc.)
  hardware.firmware = [ pkgs.armbian-firmware pkgs.linux-firmware ];
  hardware.enableRedistributableFirmware = true;

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

  # Early userspace on this vendor kernel is not reliably exposing the ext4
  # root partition under /dev/disk/by-label/NIXOS_SD in time for stage 1, even
  # though the SD/MMC drivers are built in. Use the concrete SD device path for
  # bring-up and keep the firmware partition optional.
  fileSystems."/" = lib.mkForce {
    device = "/dev/mmcblk0p2";
    fsType = "ext4";
    options = [ "x-initrd.mount" ];
  };

  fileSystems."/boot/firmware" = lib.mkForce {
    device = "/dev/mmcblk0p1";
    fsType = "vfat";
    options = [ "nofail" "noauto" ];
  };

  # Minimal useful services on first boot
  services.openssh.enable = true;
  services.getty.autologinUser = lib.mkDefault "nixos";

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
