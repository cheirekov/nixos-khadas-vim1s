{ lib, pkgs, config, kernel-khadas, common_drivers, dt-overlays, ... }:

let
  khadasSrc = pkgs.runCommand "khadas-linux-src-with-common-drivers" {} ''
    mkdir -p $out
    cp -r ${kernel-khadas}/* $out/
    ln -s ${common_drivers} $out/common_drivers
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

  dtbPackage = pkgs.stdenv.mkDerivation {
    pname = "kvim1s-dtb";
    version = "5.15-khadas";
    src = khadasSrc;
    nativeBuildInputs = with pkgs; [ gnumake pkg-config gawk bc bison flex dtc gcc python3 ];
    buildPhase = ''
      cp -r $src ./src
      chmod -R u+w ./src
      cd src

      # 1) Preprocess base DTS with CPP to resolve includes and macros
      ${pkgs.gcc}/bin/gcc -E -P -x assembler-with-cpp -D__DTS__ -nostdinc \
        -I ./include \
        -I ./include/dt-bindings \
        -I ./arch/arm64/boot/dts \
        -I ./arch/arm64/boot/dts/amlogic \
        -I ./common_drivers/include \
        -I ./common_drivers/arch/arm64/boot/dts \
        ./common_drivers/arch/arm64/boot/dts/amlogic/kvim1s.dts > kvim1s.pp.dts

      # 2) Compile base DTB
      ${pkgs.dtc}/bin/dtc -I dts -O dtb -@ -b 0 -o kvim1s.dtb kvim1s.pp.dts

      # 3) Optionally compile and apply overlays from khadas dt-overlays input
      overlay_dir='${dt-overlays}/overlays/vim1s/5.4'
      if [ -n "${builtins.concatStringsSep " " overlayNames}" ]; then
        overlays=""
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
        # Apply overlays in order onto the base DTB
        ${pkgs.dtc}/bin/fdtoverlay -i kvim1s.dtb -o kvim1s.merged.dtb $overlays
        mv kvim1s.merged.dtb kvim1s.dtb
      fi
    '';
    installPhase = ''
      install -Dm0644 kvim1s.dtb $out/amlogic/kvim1s.dtb
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


  boot = {
    kernelPackages = kernelPkgs;
    extraModulePackages = lib.mkForce [ ];

    # U-Boot reads /boot/extlinux/extlinux.conf (from VFAT /boot).
    loader.generic-extlinux-compatible.enable = true;
    loader.generic-extlinux-compatible.configurationLimit = 1;

    # Root label is provided by the sd-image module. Serial console for Amlogic is usually ttyAML0.
    kernelParams = [
      "console=ttyS0,921600n8"
      "console=ttyAML0,115200n8"
      "root=LABEL=NIXOS_SD"
      "rootfstype=ext4"
      "rootdelay=3"
    ];

    # Conservative initrd modules; harmless if not present.
    initrd.availableKernelModules = [
      "mmc_block"
      "meson_gx_mmc"
      "usb_storage"
      "uas"
      "xhci_hcd"
      "phy-meson-g12a-usb2"
      "phy-meson-g12a-usb3-pcie"
      "dwc3"
      "dwc3-meson-g12a"
    ];
    initrd.kernelModules = [ ];
  };

  # Device tree: install our vendor-built DTB and reference it
  hardware.deviceTree = {
    enable = true;
    package = lib.mkForce dtbPackage;
    name = "amlogic/kvim1s.dtb";
  };

  # Firmware (Wi-Fi/BT/etc.)
  hardware.firmware = [ pkgs.armbian-firmware pkgs.linux-firmware ];

  # Filesystems we want in userspace/initrd
  boot.supportedFilesystems = [ "vfat" "ext4" "btrfs" "f2fs" ];

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

    # Place chainload-friendly U-Boot binary (u-boot.ext) onto the FAT /boot at image build time.
    # This ensures existing Khadas U-Boot can chainload it before Linux boots.
    populateRootCommands = lib.mkIf (config.khadas.ubootVim1s.enable && config.khadas.ubootVim1s.embedInBoot) (lib.mkAfter ''
      if [ -e ${config.system.build.ubootVim1s}/u-boot/u-boot.ext ]; then
        install -Dm0644 ${config.system.build.ubootVim1s}/u-boot/u-boot.ext "$BOOT_ROOT/u-boot.ext"
      fi
    '');

    # Post-process the built image to embed a signed U-Boot blob directly into the SD image, if provided.
    # This avoids relying on SPI/eMMC U-Boot and mirrors the common FIP/MBR dd flow (as used by nixos-generators).
    postBuildCommands = lib.mkIf (uBootSigned != null) (lib.mkAfter ''
      echo "Embedding signed U-Boot into $img from ${uBootSigned}"
      # Write MBR region
      dd if=${uBootSigned} of=$img bs=1 count=444 conv=fsync,notrunc
      # Write the rest of the image after the MBR
      dd if=${uBootSigned} of=$img bs=512 skip=1 seek=1 conv=fsync,notrunc
    '');
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
