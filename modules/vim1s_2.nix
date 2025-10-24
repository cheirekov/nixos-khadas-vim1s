{ lib, pkgs, config, ... }:
let
  # Optional prebuilt signed first-stage U‑Boot image to flash into the SD image MBR.
  # If present at repo root, it will be embedded; otherwise, nothing is changed.
  uBootSigned =
    let p = ../u-boot.bin.sd.bin.signed.new; in
    if builtins.pathExists p then p else null;

in
# Minimal VIM1S profile using stock nixpkgs 5.15 kernel only.
# - No vendor U-Boot build
# - No custom kernel or DTB build
# - Keeps sd-image configuration simple so it builds cleanly
#
# How to use (example flake wiring):
#   outputs = { self, nixpkgs, ... }: {
#     nixosConfigurations.vim1s2 = nixpkgs.lib.nixosSystem {
#       system = "aarch64-linux";
#       modules = [
#         ./modules/vim1s_2.nix
#         # your common modules...
#       ];
#     };
#     packages.aarch64-linux.vim1s2-sd-image =
#       nixpkgs.lib.getAttr "sdImage" self.nixosConfigurations.vim1s2.config.system.build;
#   };
#
# Then build:
#   nix build -L .#vim1s2-sd-image --accept-flake-config
#
# Notes:
# - This produces a standard NixOS SD image with the stock linux 5.15 kernel.
# - No DTB or U-Boot customization is performed here. The platform firmware/U‑Boot
#   is expected to provide a suitable device tree (or you can place one manually
#   on the boot partition and update extlinux.conf after flashing).
# - Serial consoles are enabled for bring-up; adjust as needed.
{
  # Target architecture
  nixpkgs.hostPlatform = lib.mkDefault "aarch64-linux";
  nixpkgs.config.allowUnfree = true;

  # Stock nixpkgs kernel 5.15
  boot.kernelPackages = pkgs.linuxPackages_5_15;

  # Use generic extlinux loader (no GRUB/EFI)
  boot.loader.generic-extlinux-compatible.enable = true;
  boot.loader.generic-extlinux-compatible.configurationLimit = 1;

  # Keep /boot on root filesystem (ext4) in the SD image
  fileSystems."/boot" = lib.mkForce {
    device = "/dev/disk/by-label/NIXOS_SD";
    fsType = "ext4";
    options = [ "nofail" ];
  };

  # Basic kernel command line for bring-up (UART + root on label)
  boot.kernelParams = [
    "root=LABEL=NIXOS_SD"
    "rootfstype=ext4"
    #"rootdelay=3"
  ];

  # Do not enforce NixOS required kernel config checks here (pure stock kernel)
  #system.requiredKernelConfig = lib.mkForce [ ];

  # Do not force a deviceTree. The loader may supply one; you can also drop your
  # own DTB on /boot and patch /boot/extlinux/extlinux.conf manually post-flash.
  #hardware.deviceTree.enable = lib.mkDefault false;
hardware.firmware = [ pkgs.armbian-firmware pkgs.linux-firmware ];
  # Minimal services and users
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

  # Smaller image defaults
  documentation.nixos.enable = false;

  # sd-image minimal tweaks
  sdImage = {
    imageBaseName = "nixos-vim1s2";
    compressImage = false;

    # Post-process the SD image:
    #  - If u-boot.bin.sd.bin.signed.new exists at repo root, embed it into the image MBR + remainder.
    postBuildCommands = lib.mkAfter (
      (lib.optionalString (uBootSigned != null) ''
        echo "Embedding signed U-Boot into $img from ${uBootSigned}"
        # Write MBR region (first 444 bytes)
        dd if=${uBootSigned} of=$img bs=1 count=444 conv=fsync,notrunc
        # Write the remainder starting at sector 1
        dd if=${uBootSigned} of=$img bs=512 skip=1 seek=1 conv=fsync,notrunc
      '')
    );
  };

  # Handy tools onboard
  environment.systemPackages = with pkgs; [
    vim
    htop
    ethtool
    usbutils
    pciutils
  ];

  # Friendlier serial console
  console = {
    enable = true;
    earlySetup = true;
    keyMap = "us";
    font = null;
  };

  # Reduce log noise slightly
  boot.kernel.sysctl."kernel.printk" = "7 4 1 7";

  system.stateVersion = "24.05";
}
