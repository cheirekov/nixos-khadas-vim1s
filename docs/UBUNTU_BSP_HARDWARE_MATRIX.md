# Ubuntu BSP Hardware Matrix For Khadas VIM1S

Purpose
- Capture what the working Ubuntu/Fenix BSP actually does on VIM1S.
- Use this as the reference when bringing the same hardware up on NixOS.
- Avoid guessing when the vendor image already proves the board support exists.

Reference Assets
- Working vendor boot log:
  - `uart-921600.log`
- NixOS boot log for comparison:
  - `uart-115200.log`
- Decompiled vendor DTS:
  - `kvim1s.dts`
- Vendor boot environment fragment:
  - `uEnv.txt`
- Current Ubuntu image in the repo:
  - `vim1s-ubuntu-24.04-server-linux-5.15-fenix-1.7.5-250925.img.xz`

Working Ubuntu Baseline
- Ubuntu boots and keeps the console on `ttyS0,921600` from kernel boot into
  userspace.
- Ubuntu reaches a login prompt on `ttyS0`.
- Ubuntu proves this vendor BSP can support all of the following on VIM1S:
  - HDMI/DRM stack loads and survives boot
  - Ethernet as `eth0`
  - Wi-Fi as `wlan0` and `wlan1`
  - Bluetooth as `hci0`
  - GPIO input devices
  - IR input devices
  - CEC input device
  - GPIO userspace access through `gpiomem`

Serial And Boot Policy
- Ubuntu bootargs contain:
  - `console=ttyS0,921600`
  - `console=tty0`
- Ubuntu logs show:
  - `ttyS0` is the main console UART
  - `ttyS1` is the Bluetooth UART
- `uEnv.txt` uses:
  - `console=both`
  - `overlay_prefix=s4-s905y4`
  - `overlays=panfrost`
  - `earlycon=on`
- Important implication for NixOS:
  - keep the Linux console on `ttyS0,921600` if we want parity with Ubuntu
  - the current NixOS `115200` console policy is a divergence

Ethernet
- Proven working in Ubuntu:
  - `eth0` exists
- Observed vendor module chain:
  - `dwmac_meson8b`
  - `stmmac_platform`
  - `stmmac`
  - `amlogic_mdio_g12a`
  - `mdio_mux`
  - `amlogic_inphy`
- Important DTS nodes:
  - `mdio-multiplexer@28000`
  - `ethernet@fdc00000`
  - internal PHY under `mdio@1/ethernet_phy@8`
- Useful DTS aliases:
  - `eth_phy`
  - `ext_mdio`
  - `int_mdio`
  - `internal_ephy`
  - `ethmac`
  - `mdio0`
- Important lesson:
  - Ubuntu works with the vendor runtime shape, not with speculative local DT
    changes. NixOS should stay close to the vendor module ordering.

Wi-Fi
- Proven working in Ubuntu:
  - `wlan0`
  - `wlan1`
- Driver stack:
  - `dhd`
  - `amlogic-wireless`
- Chip identification from Ubuntu log:
  - Broadcom `0x4345`
  - AP6256 / BCM43456 family path
- Expected firmware naming:
  - `fw_bcm43456c5_ag.bin`
  - `config_bcm43456c5_ag.txt`
  - `clm_bcm43456c5_ag.blob`
  - `nvram_ap6256.txt`
- Important DTS nodes:
  - `wifi@1` on the SDIO bus
  - `aml_wifi`
  - `wifi_pwm_conf`
- Important lesson:
  - `wlan1` is likely the vendor P2P/secondary interface, not a second radio.
  - NixOS should follow the vendor `dhd` path, not `brcmfmac`.

Bluetooth
- Proven working in Ubuntu:
  - `hci0`
- UART used by Ubuntu:
  - `ttyS1`
- Observed runtime behavior:
  - vendor rfkill init messages
  - `BT_RADIO going: on`
  - `AML_BT: going ON`
- Expected firmware:
  - `BCM4345C5.hcd`
- Important lesson:
  - Bluetooth is not only kernel config; it also depends on a vendor-style
    userspace attach step on `ttyS1`.

HDMI / DRM / CEC
- Proven viable in Ubuntu:
  - the DRM stack loads
  - the system survives boot
  - fb devices are created
  - CEC input appears
- Main vendor modules involved:
  - `aml_drm`
  - `aml_media`
  - `amhdmitx`
- Important DTS nodes:
  - `amhdmitx`
  - `aocec`
  - `drm-amhdmitx`
  - `drm-vpu@0xff900000`
  - `drm-subsystem`
- Important pinctrl groups:
  - `hdmitx_hpd`
  - `hdmitx_ddc`
  - `ee_ceca`
  - `ee_cecb`
- Important Ubuntu observation:
  - HDMI/DRM emits warnings but still comes up.
  - Warnings alone are not a reason to diverge from the BSP.
- Known warning examples from Ubuntu:
  - cyclic dependency fixups around `drm-vpu` and `amhdmitx`
  - `hdmi is not enabled`
  - `osd_axi_sel parser failed and set default 0`
  - `get vic_list from hdmitx dev return 0`
  - vblank warnings during fbdev init
- Important lesson:
  - manual late probing from userspace is safer on NixOS than coldplugging
    `aml_drm` during boot until the vendor runtime contract is reproduced.

GPU / VPU
- Ubuntu shows:
  - `panfrost` loads successfully
  - the vendor DRM/VPU stack also loads
- Important lesson:
  - there are two graphics-related pieces here:
    - `panfrost` for the GPU
    - `aml_drm` / `aml_media` / VPU path for display/video
  - NixOS should avoid forcing extra built-in DRM/VPU symbols until the
    runtime shape matches Ubuntu.

Audio
- DTS shows a large vendor audio topology:
  - `audiobus@0xFE330000`
  - `tdm@0`
  - `tdm@1`
  - `tdm@2`
  - `spdif@0`
  - `spdif@1`
  - `pdm`
  - `auge_sound`
  - codec `t9015`
- Ubuntu logs show these pieces initialize, but with warnings and deferred
  behavior.
- Common warnings in Ubuntu:
  - pinmux conflicts for `pdm`
  - missing `suspend-clk-off`
  - `auge_sound` codec-dai lookup failures
- Important lesson:
  - audio is present in the BSP but should be treated as a later bring-up item
    after networking and HDMI are stable.

IR
- Proven present in Ubuntu:
  - `ir_keypad`
  - `ir_keypad1`
- Main node:
  - `fe084040.ir`
- Important lesson:
  - IR support exists already in the vendor BSP and should not require new
    kernel invention.

Buttons
- Proven present in Ubuntu:
  - `gpio_keypad`
- Main DTS node:
  - `gpio_keypad`

LEDs
- DTS nodes of interest:
  - `pwmleds`
  - `state_led`
- Ubuntu behavior:
  - user observed LED activity on the working vendor image
- Important lesson:
  - LED behavior is probably a mix of DTS wiring and userspace trigger setup.

GPIO Userspace
- Proven present in Ubuntu:
  - `gpiomem-aml`
- Main DTS node:
  - `gpiomem`
- Important lesson:
  - GPIO access should be testable later with normal userspace tooling once the
    base image is stable.

Thermal / Fan / Cooling
- DTS contains cooling/thermal structures and fan-related thresholds, but the
  current logs do not yet prove actual fan control on hardware.
- Treat this as a later validation item, not as evidence of a current failure.

What To Copy From Ubuntu Into NixOS
- Serial policy:
  - `ttyS0,921600` for the main console
  - `ttyS1` reserved for Bluetooth attach
- Runtime module shape:
  - follow the vendor Ethernet and wireless module ordering
- Firmware naming:
  - use the Broadcom/AP6256-compatible vendor filenames
- Userspace glue:
  - keep the Bluetooth attach service model
  - expect LED behavior and some board quirks to need userspace setup
- DTS expectations:
  - prefer the vendor base DTB and minimal overlays
  - avoid speculative local DT edits unless Ubuntu proves they are required

What Not To Copy Blindly
- Do not copy every Ubuntu bootarg into NixOS.
  - Many are Android/vendor-specific and are passed through to userspace.
- Do not treat every Ubuntu warning as a bug to “fix”.
  - The BSP survives with several noisy warnings.
- Do not force large HDMI/VPU/VOUT blocks to `=y` just because Ubuntu loads the
  feature set.
  - The vendor runtime shape matters more than blunt built-in enablement.

Recommended NixOS Bring-Up Order
1. Preserve the last known-good networking baseline.
2. Align the serial console policy with Ubuntu.
3. Keep HDMI out of early boot and probe it manually from userspace.
4. After HDMI is stable, validate:
   - audio
   - IR
   - LEDs
   - buttons
   - GPIO
   - thermal/fan
   - VPU/video acceleration

Hardware Checklist After HDMI
- Ethernet with a real cable
- Wi-Fi association and traffic
- Bluetooth scan and pairing
- HDMI hotplug and mode detection
- Audio playback/capture
- IR key events
- LED triggers
- Button events
- GPIO userspace access
- Fan / PWM header behavior
- Video acceleration / VPU usage
