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
    # Relax warnings and hardening for legacy vendor U‑Boot on modern toolchains.
    NIX_CFLAGS_COMPILE = lib.concatStringsSep " " [
      "-Wno-error"
      "-Wno-array-bounds"
      "-Wno-error=enum-int-mismatch"
      "-Wno-stringop-overflow"
      "-Wno-stringop-truncation"
    ];
    hardeningDisable = [ "fortify" ];

    buildPhase = ''
      runHook preBuild
      cp -r "$src" ./src
      chmod -R u+w ./src
      cd src

      # Honor explicit defconfig from Nix option if provided
      DEF_FROM_CFG='${lib.escapeShellArg (if (config.khadas.ubootVim1s.defconfig or null) != null then config.khadas.ubootVim1s.defconfig else "")}'
      defcfg=""
      if [ -n "$DEF_FROM_CFG" ]; then
        defcfg="$DEF_FROM_CFG"
      fi

      # Auto-detect ONLY a VIM1S defconfig; do not fallback to other boards.
      if [ -z "$defcfg" ]; then
        if [ -d configs ]; then
          # Match kvim1s_defconfig or khadas-vim1s_defconfig variants.
          defcfg="$(ls configs | grep -E '(^|/)k?vim1s(_.*)?_defconfig$' | head -n1 || true)"
        fi
      fi
      if [ -z "$defcfg" ]; then
        # Fallback: some Khadas trees store defconfigs under board/*/defconfigs.
        alt="$(find . -type f -path './board/*/defconfigs/kvim1s_defconfig' | head -n1 || true)"
        if [ -n "$alt" ]; then
          echo "Found kvim1s_defconfig at $alt; copying into configs/ for U-Boot build system"
          mkdir -p configs
          cp -f "$alt" "configs/kvim1s_defconfig"
          defcfg="kvim1s_defconfig"
        fi
      fi

      if [ -z "$defcfg" ]; then
        echo "No VIM1S defconfig found (expected kvim1s_defconfig or khadas-vim1s_defconfig). Aborting." >&2
        echo "Available Khadas/VIM defconfigs (for reference):" >&2
        if [ -d configs ]; then ls configs | grep -E '(khadas|vim)' >&2 || true; fi
        exit 1
      fi
      echo "Using U-Boot defconfig: $defcfg"

      # Nix sandbox has no /bin; patch any hardcoded /bin/pwd to 'pwd'.
      grep -RIl '/bin/pwd' . | xargs -r sed -i 's:/bin/pwd:pwd:g'

      # Strip any hard-coded -Werror in the tree to ensure warnings don't halt the build.
      grep -RIl -- '-Werror' . | xargs -r sed -i 's/-Werror//g'

      # Soften diagnostics for ancient vendor tree on modern GCC.
      # Enable FIT support in host tools to satisfy image_* and fit_* symbols
      # Build host tools with FIT support but WITHOUT signature paths (avoid OpenSSL/fit signature code)
      export HOSTCFLAGS="''${HOSTCFLAGS:-} -Wno-error -Wno-array-bounds -DCONFIG_FIT -UCONFIG_FIT_SIGNATURE -DCONFIG_SHA256 -DCONFIG_SHA1"
      export KCFLAGS="''${KCFLAGS:-} -Wno-error -Wno-array-bounds -Wno-error=enum-int-mismatch"
      export KBUILD_CFLAGS="''${KBUILD_CFLAGS:-} -Wno-error -Wno-array-bounds -Wno-error=enum-int-mismatch -DCONFIG_FIT -UCONFIG_FIT_SIGNATURE -DCONFIG_SHA256 -DCONFIG_SHA1"
      export CFLAGS="''${CFLAGS:-} -Wno-error"
      # Host linker occasionally drops needed objects; disable --as-needed.
      export LDFLAGS="''${LDFLAGS:-} -Wl,--no-as-needed"

      # Build out-of-tree into ./build to avoid Makefile mkdir/pwd issues.
      make O=build "$defcfg"
      make -j"$NIX_BUILD_CORES" O=build HOSTCFLAGS="$HOSTCFLAGS" KCFLAGS="$KCFLAGS" KBUILD_CFLAGS="$KBUILD_CFLAGS"
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p "$out/u-boot"
      # Prefer artifacts from O=build; fallback to src/ if present there.
      for f in u-boot.bin u-boot-nodtb.bin u-boot.itb u-boot.bin.sd.bin; do
        if [ -f "build/$f" ]; then
          install -Dm0644 "build/$f" "$out/u-boot/$f"
        elif [ -f "src/$f" ]; then
          install -Dm0644 "src/$f" "$out/u-boot/$f"
        fi
      done
      # Provide a chainload-friendly file name. Prefer u-boot.itb, else u-boot.bin from build/ then src/
      if [ -f "build/u-boot.itb" ]; then
        install -Dm0644 "build/u-boot.itb" "$out/u-boot/u-boot.ext"
      elif [ -f "src/u-boot.itb" ]; then
        install -Dm0644 "src/u-boot.itb" "$out/u-boot/u-boot.ext"
      elif [ -f "build/u-boot.bin" ]; then
        install -Dm0644 "build/u-boot.bin" "$out/u-boot/u-boot.ext"
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
    defconfig = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "kvim1s_defconfig";
      description = "Override defconfig file name to use when building Khadas U-Boot (e.g., kvim1s_defconfig). If null, auto-detect a VIM1S defconfig from configs/.";
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
