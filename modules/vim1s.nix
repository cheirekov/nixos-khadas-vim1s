{ lib, pkgs, kernel-khadas, common_drivers, dt-overlays, ... }:

let
  khadasSrc = pkgs.runCommand "khadas-linux-src-with-common-drivers" {} ''
    mkdir -p $out
    cp -r ${kernel-khadas}/* $out/
    ln -s ${common_drivers} $out/common_drivers
  '';
  
  kvimsConfig = pkgs.stdenv.mkDerivation {
    pname = "kvims-config";
    version = "5.15.137";
    src = khadasSrc;
    nativeBuildInputs = with pkgs; [ bison flex perl gnumake pkg-config gawk bc ];
    buildPhase = ''
      cp -r $src ./src
      chmod -R u+w ./src
      cd src
      # Generate base config from Khadas defconfig
      make ARCH=arm64 KCONFIG_DEFCONFIG=common_drivers/arch/arm64/configs/kvims_defconfig defconfig
      # Merge NixOS-required kernel options
      cat > ../nixos-required.config <<'EOF'
      CONFIG_DEVTMPFS=y
      CONFIG_DEVTMPFS_MOUNT=y
      CONFIG_CGROUPS=y
      CONFIG_CGROUP_PIDS=y
      CONFIG_MEMCG=y
      CONFIG_NAMESPACES=y
      CONFIG_USER_NS=y
      CONFIG_PID_NS=y
      CONFIG_NET_NS=y
      CONFIG_UTS_NS=y
      CONFIG_IPC_NS=y
      CONFIG_INOTIFY_USER=y
      CONFIG_SIGNALFD=y
      CONFIG_TIMERFD=y
      CONFIG_EPOLL=y
      CONFIG_NET=y
      CONFIG_UNIX=y
      CONFIG_SYSFS=y
      CONFIG_PROC_FS=y
      CONFIG_FHANDLE=y
      CONFIG_SECCOMP=y
      CONFIG_TMPFS=y
      CONFIG_TMPFS_POSIX_ACL=y
      CONFIG_TMPFS_XATTR=y
      CONFIG_AUTOFS_FS=y
      CONFIG_CRYPTO_USER_API_HASH=y
      CONFIG_CRYPTO_HMAC=y
      CONFIG_CRYPTO_SHA256=y
      CONFIG_BLK_DEV_INITRD=y
      CONFIG_MODULES=y
      CONFIG_BINFMT_ELF=y
      CONFIG_EXT4_FS=y
      CONFIG_EXT4_FS_POSIX_ACL=y
      CONFIG_EXT4_FS_SECURITY=y
      CONFIG_MSDOS_FS=y
      CONFIG_VFAT_FS=y
      CONFIG_BTRFS_FS=m
      CONFIG_F2FS_FS=m
      CONFIG_BPF_SYSCALL=y
      CONFIG_CGROUP_BPF=y
      # Some NixOS assertions expect DMI; enable ACPI+DMI if possible on arm64
      CONFIG_ACPI=y
      CONFIG_DMI=y
      CONFIG_DMIID=y
      EOF
      ./scripts/kconfig/merge_config.sh -m .config ../nixos-required.config || true
      yes "" | make ARCH=arm64 olddefconfig
    '';
    installPhase = ''
      mkdir -p $out
      cp .config $out/.config
    '';
  };

  vendorKernel = pkgs.linuxManualConfig {
    version = "5.15.137-khadas-vim1s";
    src = khadasSrc;
    stdenv = pkgs.stdenv;
    extraMeta.branch = "5.15";
    modDirVersion = "5.15.137";
    configfile = "${kvimsConfig}/.config";

    # Build with newer GCC by disabling Werror and noisy warnings from this vendor 5.4 tree
    extraMakeFlags = [
      "WERROR=0"
      "CONFIG_WERROR=n"
      "CONFIG_CC_WERROR=n"
      "KCFLAGS=-Wno-error -Wno-array-compare -Wno-dangling-pointer -Wno-int-conversion"
      "KBUILD_CFLAGS=-Wno-error -Wno-array-compare -Wno-dangling-pointer -Wno-int-conversion"
      "HOSTCFLAGS=-Wno-error"
    ];


  };

  vendorPackages = pkgs.linuxPackagesFor vendorKernel;
in
{
  nixpkgs.hostPlatform = lib.mkDefault "aarch64-linux";

  boot = {
    kernelPackages = vendorPackages;

    # U-Boot reads /boot/extlinux/extlinux.conf (from VFAT /boot).
    loader.generic-extlinux-compatible.enable = true;
    loader.generic-extlinux-compatible.configurationLimit = 1;

    # Root label is provided by the sd-image module. Serial console for Amlogic is usually ttyAML0.
    kernelParams = [
      "console=ttyAML0,115200n8"
      "root=LABEL=NIXOS_SD"
      "rootfstype=ext4"
    ];

    # Conservative initrd modules; harmless if not present.
    initrd.availableKernelModules = [
      "mmc_block"
      "sdhci_meson_gx"
      "usb_storage"
      "uas"
      "xhci_hcd"
      "phy_meson_g12a_usb2"
      "phy_meson_g12a_usb3_pcie"
      "dwc3"
      "dwc3_meson_g12a"
    ];
    initrd.kernelModules = [ ];
  };

  # Copy DTB(s) into /boot/dtb and reference via extlinux.conf.
  hardware.deviceTree = {
    enable = true;
    name = "amlogic/kvim1s.dtb";
    # If overlays are desired later, they can be added like:
    # overlays = [ "amlogic/kvim1s-uart.dtbo" ];
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

  # Slightly faster/smaller image for bring-up
  documentation.nixos.enable = false;

  # sd-image tweaks (base module imported in flake)
  sdImage = {
    imageBaseName = "nixos-vim1s";
    compressImage = true;
    # You can tune the root partition size later if needed:
    # rootPartitionSize = 4096; # MiB
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
