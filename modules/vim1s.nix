{ lib, pkgs, config, kernel-khadas, common_drivers, dt-overlays, ... }:

let
  khadasSrc = pkgs.runCommand "khadas-linux-src-with-common-drivers" {} ''
    mkdir -p $out
    cp -r ${kernel-khadas}/* $out/
    ln -s ${common_drivers} $out/common_drivers
  '';

  dtbPackage = pkgs.stdenv.mkDerivation {
    pname = "kvim1s-dtb";
    version = "5.15-khadas";
    src = khadasSrc;
    nativeBuildInputs = (with pkgs; [ gnumake pkg-config gawk bc bison flex dtc gcc python3 ]) ++ [ pkgs.pkgsCross.aarch64-multiplatform.stdenv.cc ];
    buildPhase = ''
      cp -r $src ./src
      chmod -R u+w ./src
      cd src
      # Overlay Khadas common_drivers into kernel tree so Kbuild can find DTS and headers
      mkdir -p ./arch/arm64/boot/dts
      cp -rL ./common_drivers/arch/arm64/boot/dts/* ./arch/arm64/boot/dts/ || true
      mkdir -p ./include
      cp -rL ./common_drivers/include/* ./include/ 2>/dev/null || true
      # Build the target DTB using the kernel's build system (handles CPP and dt-bindings)
      make -j"$NIX_BUILD_CORES" ARCH=arm64 \
        CROSS_COMPILE=${pkgs.pkgsCross.aarch64-multiplatform.stdenv.cc.targetPrefix} \
        DTC=${pkgs.dtc}/bin/dtc \
        "arch/arm64/boot/dts/amlogic/kvim1s.dtb"
    '';
    installPhase = ''
      install -Dm0644 arch/arm64/boot/dts/amlogic/kvim1s.dtb $out/dtbs/amlogic/kvim1s.dtb
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
      "console=ttyAML0,115200n8"
      "root=LABEL=NIXOS_SD"
      "rootfstype=ext4"
      # If storage init is slow, uncomment:
      # "rootdelay=3"
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
    # overlays = [ "amlogic/kvim1s-your-overlay.dtbo" ];
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
