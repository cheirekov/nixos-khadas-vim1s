{ lib, pkgs, config, kernel-khadas, common_drivers, dt-overlays, ... }:

let
  khadasSrc = pkgs.runCommand "khadas-linux-src-with-common-drivers" {} ''
    mkdir -p $out
    cp -r ${kernel-khadas}/* $out/
    ln -s ${common_drivers} $out/common_drivers
  '';

  overlayNames = [ "4k2k_fb" "i2cm_e" "i2s" "onewire" "panfrost" "pwm_f" "spdifout" "spi0" "uart_c" ];

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
        for name in ${builtins.concatStringsSep " " overlayNames}; do
          src="$overlay_dir/${name}.dts"
          if [ ! -f "$src" ]; then
            echo "Overlay '$name' not found at $src" >&2
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
            "$src" > "${name}.pp.dts"
          ${pkgs.dtc}/bin/dtc -I dts -O dtb -@ -o "${name}.dtbo" "${name}.pp.dts"
          overlays="$overlays ${name}.dtbo"
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

  # Use 5.15 LTS for better compatibility with Khadas VIM1S vendor DTB
  kernelPkgs = pkgs.linuxPackages_5_15;
in
{
  nixpkgs.hostPlatform = lib.mkDefault "aarch64-linux";

  boot = {
    kernelPackages = kernelPkgs;

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
  hardware.firmware = [ pkgs.linux-firmware ];

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
