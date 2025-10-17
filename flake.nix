{
  description = "NixOS SD image for Khadas VIM1S (Amlogic S905Y4) using vendor Linux 5.15 and generic extlinux U-Boot";

  inputs = {
    # Choose a stable nixpkgs channel. You can switch to unstable if needed.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.05";

    # Utilities to expose a convenient host-native package output.
    flake-utils.url = "github:numtide/flake-utils";

    # Vendor kernel source: Khadas Linux (VIM1S) 5.15 branch.
    # Using as a non-flake input so the exact commit is locked in flake.lock.
    kernel-khadas = {
      url = "github:khadas/linux/khadas-vims-5.15.y";
      flake = false;
    };

    # Common drivers repo used by Khadas 5.15 kernels (provides kvims_defconfig and kvim1s.dts)
    common_drivers = {
      url = "github:khadas/common_drivers/khadas-vims-5.15.y";
      flake = false;
    };

    # Optional: DT overlay sources (not used in initial boot path).
    dt-overlays = {
      url = "github:khadas/khadas-linux-kernel-dt-overlays";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, flake-utils, kernel-khadas, common_drivers, dt-overlays }:
    let
      # We will expose a build artifact for both x86_64-linux (host) and aarch64-linux (native).
      systems = [ "x86_64-linux" "aarch64-linux" ];
    in
    flake-utils.lib.eachSystem systems (hostSystem:
      let
        pkgs = import nixpkgs { system = hostSystem; };
        lib = nixpkgs.lib;
      in {
        packages = {
          # Build the AArch64 SD image from any host. On x86_64, you need binfmt/qemu-user support.
          vim1s-sd-image =
            (lib.nixosSystem {
              system = "aarch64-linux";
              specialArgs = { inherit kernel-khadas common_drivers dt-overlays; };
              modules = [
                ./modules/vim1s.nix
                # Standard AArch64 SD image generator (creates a VFAT /boot + ext4 root).
                ({ modulesPath, ... }: { imports = [ (modulesPath + "/installer/sd-card/sd-image-aarch64.nix") ]; })
              ];
            }).config.system.build.sdImage;

          default = self.packages.${hostSystem}.vim1s-sd-image;
        };
      }
    ) // {
      # Also expose a conventional nixosConfiguration for direct use
      nixosConfigurations = {
        vim1s = nixpkgs.lib.nixosSystem {
          system = "aarch64-linux";
          specialArgs = { inherit kernel-khadas common_drivers dt-overlays; };
          modules = [
            ./modules/vim1s.nix
            ({ modulesPath, ... }: { imports = [ (modulesPath + "/installer/sd-card/sd-image-aarch64.nix") ]; })
          ];
        };
      };
    };
}
