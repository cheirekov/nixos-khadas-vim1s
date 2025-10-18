{ lib, pkgs, config, uboot-khadas, ... }:

let
  ubootVim1s = pkgs.stdenv.mkDerivation {
    pname = "uboot-khadas-vim1s";
    version = "v2019.01-khadas";
    src = uboot-khadas;

    nativeBuildInputs = with pkgs; [
      bc
      bison
      flex
      dtc
      swig
      python3
      pkg-config
      openssl
      gnumake
      gcc
      pkgsCross.aarch64-multiplatform.stdenv.cc
    ];

    enableParallelBuilding = true;
    makeFlags = [ "CROSS_COMPILE=${pkgs.pkgsCross.aarch64-multiplatform.stdenv.cc.targetPrefix}" ];

    buildPhase = ''
      runHook preBuild
      cp -r "$src" ./src
      chmod -R u+w ./src
      cd src
      # Try likely defconfigs in order; stop on first that works.
      if ! make khadas-vim1s_defconfig 2>/dev/null; then
        if ! make kvim1s_defconfig 2>/dev/null; then
          if ! make vim1s_defconfig 2>/dev/null; then
            echo "No suitable defconfig for VIM1S found in Khadas U-Boot tree" >&2
            exit 1
          fi
        fi
      fi
      make -j"$NIX_BUILD_CORES"
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p "$out/u-boot"
      # Copy common artifacts if they exist
      for f in u-boot.bin u-boot-nodtb.bin u-boot.itb u-boot.bin.sd.bin; do
        if [ -f "src/$f" ]; then
          install -Dm0644 "src/$f" "$out/u-boot/$f"
        fi
      done
      # Provide a chainload-friendly file name. If no better format exists, copy u-boot.bin as u-boot.ext
      if [ -f "src/u-boot.itb" ]; then
        install -Dm0644 "src/u-boot.itb" "$out/u-boot/u-boot.ext"
      elif [ -f "src/u-boot.bin" ]; then
        install -Dm0644 "src/u-boot.bin" "$out/u-boot/u-boot.ext"
      fi
      runHook postInstall
    '';

    meta = with lib; {
      description = "Khadas U-Boot for VIM1S (Amlogic S905Y4), packaged for NixOS";
      homepage = "https://github.com/khadas/u-boot/tree/khadas-vims-v2019.01";
      license = licenses.gpl2Plus;
      platforms = [ "aarch64-linux" ];
    };
  };
in
{
  options.khadas.ubootVim1s = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Build Khadas U-Boot for VIM1S and include it in the system closure.";
    };
    installChainloadFile = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "If enabled, a one-shot service copies u-boot.ext into /boot/u-boot.ext on first boot if missing.";
    };
    embedInBoot = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        When true, embed the built u-boot.ext into the SD image's /boot partition at image build time.
        This enables chainloading our U-Boot directly from the existing Khadas SPI/eMMC U-Boot.
        When false (default), the image won't depend on building U-Boot and will rely on the onboard U-Boot.
      '';
    };
  };

  config = lib.mkIf (config.khadas.ubootVim1s.enable) {
    # Only build U-Boot when we actually need to embed or install it
    system.build.ubootVim1s = lib.mkIf (config.khadas.ubootVim1s.embedInBoot || config.khadas.ubootVim1s.installChainloadFile) ubootVim1s;

    # Convenience tools onboard (don't force building U-Boot unless requested)
    environment.systemPackages = [ pkgs.ubootTools ];

    # First-boot copy to /boot for safe chainloading
    systemd.services."khadas-install-uboot-ext" = lib.mkIf config.khadas.ubootVim1s.installChainloadFile {
      description = "Install Khadas U-Boot (u-boot.ext) onto /boot for chainloading (once)";
      after = [ "local-fs.target" ];
      wants = [ "local-fs.target" ];
      unitConfig.ConditionPathIsDirectory = "/boot";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.bash}/bin/bash -euxo pipefail -c '\
          if [ -d /boot ] && [ -w /boot ]; then \
            if [ ! -e /boot/u-boot.ext ] && [ -e ${ubootVim1s}/u-boot/u-boot.ext ]; then \
              install -Dm0644 ${ubootVim1s}/u-boot/u-boot.ext /boot/u-boot.ext; \
              sync; \
            fi; \
          fi'";
        RemainAfterExit = true;
      };
      wantedBy = [ "multi-user.target" ];
    };
  };
}
