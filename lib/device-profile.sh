#!/usr/bin/env bash
# shellcheck disable=SC2034  # vars here are consumed by the scripts that source this lib
# lib/device-profile.sh - Device detection + per-device profile for the HHD
# installer/uninstaller. Sourced by setup.sh and uninstall.sh so both share ONE
# source of truth for what differs between handhelds.
#
# Detected-device globals set by detect_device():
#   DEVICE          short id: asus | lenovo | unknown
#   DEVICE_LABEL    human name for logs
#   TDP_KIND        asus_wmi | acpi_call         (how adjustor drives TDP)
#   TDP_MODULES     kernel modules to load/verify for the TDP path
#   TDP_CHECK_PATH  sysfs/proc path that must exist for TDP to work
#   EXTRA_PKGS      device-specific packages to install (beyond hhd/adjustor/hhd-ui)
#   CONFLICT_PKGS   userspace packages that fight adjustor over TDP (removed on install)
#   CONFLICT_SVC    systemd service to disable before removing CONFLICT_PKGS ("" if none)
#   HID_BLACKLIST   native HID modules to blacklist ONLY in the double-controller case
#   NEEDS_UDEV_XPAD 1 if the device relies on HHD's udev rule binding xpad (Legion)
#   KERNEL_NOTE     free-text note about kernel requirements for this device
#
# Detection is DMI-based (/sys/class/dmi/id/product_name). No root needed to read it.
# Facts sourced from hhd-dev/hhd (master) and archived hhd-dev/adjustor (main),
# now merged into hhd as of v4. See lib/README or the hhd-device-facts memory.

# ============================================================================
# Shared across all supported handhelds
# ============================================================================
# InputPlumber conflicts on every device (grabs controller + keyboard HID), so
# the core script handles it directly, not per-profile.
#
# power-profiles-daemon (PPD) + TuneD: CONFIRMED hard conflict, device-agnostic.
# adjustor writes /sys/firmware/acpi/platform_profile directly (ASUS path) AND
# registers the PPD D-Bus names (org.freedesktop.UPower.PowerProfiles /
# net.hadess.PowerProfiles) on BOTH devices. If PPD or tuned runs, adjustor can't
# own the bus name (and on ASUS also fights the sysfs node) -> TDP silently fails.
# adjustor only auto-masks them when HHD_PPD_MASK is set; on a vanilla CachyOS
# install it does NOT, so we handle it ourselves.
# Fix = MASK (not `pacman -R`): removal drags out desktop power panels that depend
# on the PPD D-Bus API (which adjustor's replacement then serves), and plain
# `disable` can be reactivated via D-Bus/socket.
# Source: adjustor src/adjustor/drivers/gpu/__init__.py (~L126-170), ppd.py, core/platform.py
PPD_SVC="power-profiles-daemon.service"
PPD_ACTION="mask"           # none | mask | remove
TUNED_SVC="tuned.service"   # adjustor treats tuned identically to PPD
TUNED_ACTION="mask"
# Upstream-native alternative to masking: set HHD_PPD_MASK=1 in hhd@.service env
# and let adjustor mask PPD/tuned itself. setup.sh exposes this as an opt-in.
HHD_PPD_MASK_ENV_ALT=1

# steamos-manager: never auto-REMOVE. Valve/SteamOS component; NOT in CachyOS repos
# or the CachyOS-Handheld tree. Stock steamos-manager is not a conflict.
STEAMOS_MGR_ACTION="none"   # never touch stock steamos-manager

# OPT-IN integration: the in-Steam / gamescope TDP slider (SteamOS/Bazzite Deck
# performance menu) driving HHD. Provided by the AUR fork below, which:
#   - provides+conflicts 'steamos-manager' (drop-in replace; can't co-install stock)
#   - depends hhd>=4.1; makedepends git/rust/clang/speech-dispatcher (builds from source)
#   - ships NO .install hook -> nothing is auto-enabled; we enable the units ourselves
# Activation: enable the *user* unit steamos-manager.service (WantedBy graphical-session,
# ordered Before gamescope-session-plus@steam) + the system unit; both D-Bus activated.
# The slider only appears in the gamescope Game Mode session, needs HHD "Enable TDP
# Controls" ON, and coexists with the HHD overlay (both feed one adjustor backend).
# Decky TDP plugins (SimpleDeckyTDP/PowerControl) make HHD report "conflict" -> disable them.
# steamos-tdp writes explicit watts, so acpi_call is needed for the custom-TDP path.
# Source: aur steamos-manager-hhd-git PKGBUILD, hhd-dev/steamos-manager-hhd (Makefile,
#         data/{system,user}/*.service, src/power.rs), hhd src/hhd/http/steamos.py, adjustor/hhd.py
STEAMOS_HHD_PKG="steamos-manager-hhd-git"
STEAMOS_HHD_USER_SVC="steamos-manager.service"    # systemctl --user
STEAMOS_HHD_SYS_SVC="steamos-manager.service"     # system (root)
# Stock steamos-manager: CachyOS Handheld DOES ship this by default (cachyos repo).
# The slider (STEAMOS_HHD_PKG) provides+conflicts it, so installing the slider
# REPLACES stock steamos-manager. On uninstall we reinstall stock if it was there.
STEAMOS_STOCK_PKG="steamos-manager"
STEAMOS_STOCK_SVC="steamos-manager.service"

# hhd_state_file -> path where setup.sh records the pre-install snapshot that
# uninstall.sh reads to restore the machine to exactly its pre-setup state.
hhd_state_file() { printf '%s/hhd-on-cachyos/pre-setup.env' "${XDG_STATE_HOME:-$HOME/.local/state}"; }

# aur_makepkg_install <pkgbase> <assume_yes 0|1> -> builds and installs an AUR
# package directly with git + makepkg. No AUR helper (paru/yay) required.
# `makepkg -s` pulls missing build/runtime deps from the official repos via pacman,
# which is enough here because STEAMOS_HHD_PKG has no AUR-only dependencies.
# Must run as a NORMAL user (makepkg refuses root); it uses sudo itself for pacman.
# Returns 0 on a successful install, 1 on any failure. Temp dir is always cleaned.
# aur_makepkg_install <pkgbase> <assume_yes 0|1> [conflict_pkg]
# If conflict_pkg is given, it is a currently-installed package that the built
# package `conflicts`+`provides` (e.g. steamos-manager-hhd-git vs steamos-manager).
# Under --noconfirm pacman defaults the "remove conflicting package?" prompt to No,
# so we BUILD first, then remove the conflicting package (deps are satisfied by the
# new one's `provides`), then install — build-first so a build failure never leaves
# the machine with the conflicting package removed and nothing in its place.
aur_makepkg_install() {
  local pkg="$1" ay="${2:-0}" conflict="${3:-}"

  # Toolchain needed to build any AUR package (via the tty-aware pac()).
  ASSUME_YES="$ay" pac -S --needed git base-devel || return 1

  local tmp rc=1
  tmp="$(mktemp -d)" || return 1
  if git clone --depth 1 "https://aur.archlinux.org/${pkg}.git" "$tmp/${pkg}"; then
    # Build only (-f, no -i). makepkg's dep install runs an inner `sudo pacman`
    # that prompts; under `curl | bash` stdin is the pipe, so read from /dev/tty.
    local mkok=0
    if [[ "$ay" -eq 1 ]]; then ( cd "$tmp/${pkg}" && makepkg -sf --noconfirm ) && mkok=1
    elif [[ -e /dev/tty ]]; then ( cd "$tmp/${pkg}" && makepkg -sf </dev/tty ) && mkok=1
    else ( cd "$tmp/${pkg}" && makepkg -sf --noconfirm ) && mkok=1; fi

    if [[ "$mkok" -eq 1 ]]; then
      local built
      built="$(find "$tmp/${pkg}" -maxdepth 1 -name '*.pkg.tar.*' ! -name '*-debug-*' 2>/dev/null | head -1)"
      if [[ -n "$built" ]]; then
        # Clear the conflicting package first so the install is prompt-free.
        [[ -n "$conflict" ]] && pacman -Qq "$conflict" &>/dev/null && { ASSUME_YES="$ay" pac -Rdd "$conflict" || true; }
        ASSUME_YES="$ay" pac -U "$built" && rc=0
      fi
    fi
  fi
  rm -rf "$tmp"
  return "$rc"
}

dmi() { cat "/sys/class/dmi/id/$1" 2>/dev/null; }

# svc_exists <unit> -> 0 if the systemd unit exists on this system (installed,
# enabled, disabled, or masked), 1 if genuinely absent. Robust across systemd
# versions: `systemctl cat` returns non-zero for absent units but also for masked
# ones, so fall back to a unit-file table match for the masked case.
svc_exists() {
  systemctl cat "$1" &>/dev/null && return 0
  # Capture first (avoid `... | grep -q` SIGPIPE under pipefail).
  local out; out="$(systemctl list-unit-files "$1" --no-legend 2>/dev/null)"
  [[ -n "$out" ]] && grep -q "^${1}[[:space:]]" <<<"$out"
}

# svc_masked <unit> -> 0 if the unit is masked.
svc_masked() { [[ "$(systemctl is-enabled "$1" 2>/dev/null || true)" == "masked" ]]; }

# pac <pacman args...> -> run pacman, working even under `curl | bash` where stdin
# is the pipe (EOF) and interactive pacman prompts would otherwise abort. When
# ASSUME_YES=1 uses --noconfirm; otherwise reads pacman's prompts from /dev/tty
# (the real terminal) so the user can answer; falls back to --noconfirm if there
# is no tty at all. Callers should already have gated the action with confirm().
pac() {
  if [[ "${ASSUME_YES:-0}" -eq 1 ]]; then sudo pacman --noconfirm "$@"
  elif [[ -e /dev/tty ]]; then sudo pacman "$@" </dev/tty
  else sudo pacman --noconfirm "$@"; fi
}

# mod_loaded <module> -> 0 if the kernel module is loaded.
# Uses awk (consumes all of lsmod) instead of `lsmod | grep -q`: under
# `set -o pipefail`, grep -q exits on first match, lsmod gets SIGPIPE (141), and
# pipefail reports the pipeline as FAILED even though the module IS loaded -- a
# race that misfires more often for modules near the top of lsmod. awk reads the
# whole stream, so there is no SIGPIPE and the result is deterministic.
mod_loaded() { lsmod | awk -v m="$1" '$1==m{f=1} END{exit f?0:1}'; }

detect_device() {
  local vendor product board
  vendor="$(dmi sys_vendor)"
  product="$(dmi product_name)"
  board="$(dmi board_name)"

  DEVICE="unknown"; DEVICE_LABEL="Unknown device"
  TDP_KIND=""; TDP_MODULES=(); TDP_CHECK_PATH=""
  EXTRA_PKGS=(); CONFLICT_PKGS=(); CONFLICT_SVC=""
  HID_BLACKLIST=(); CONTROLLER_MODULES=(); NEEDS_UDEV_XPAD=0; KERNEL_NOTE=""

  # ---- ASUS ROG Ally: substring match on product_name ----
  # Source: hhd src/hhd/device/rog_ally/__init__.py, adjustor core/const.py ASUS_DATA
  if [[ "$product" == *"ROG Ally"* || "$product" == *"ROG Xbox Ally"* ]]; then
    DEVICE="asus"
    DEVICE_LABEL="ASUS ${product}"
    TDP_KIND="asus_wmi"
    TDP_MODULES=(asus_wmi asus_armoury)                 # mainline >=6.19 TDP path
    TDP_CHECK_PATH="/sys/firmware/acpi/platform_profile"
    EXTRA_PKGS=()                                        # nothing beyond hhd stack
    # asusctl/rog-control-center/supergfxctl drive the same platform profile and
    # asus-armoury PPT attrs; asusd auto-starts from a udev rule.
    CONFLICT_PKGS=(asusctl rog-control-center supergfxctl)
    CONFLICT_SVC="asusd"
    # Double-controller fix (ONLY if Steam shows two pads). ASUS-only udev/HID.
    HID_BLACKLIST=(hid_asus_ally hid_asus)
    NEEDS_UDEV_XPAD=0
    KERNEL_NOTE="Ally/Ally X: asus-wmi/asus-armoury mainline since 6.19; only the ROG Z13 (2025) hard-requires the Bazzite kernel. Gyro (bmi260) needs the linux-g14/OGC kernel."
    return 0
  fi

  # ---- Lenovo Legion Go family: EXACT product_name code match ----
  # Source: hhd src/hhd/device/legion_go/__init__.py, adjustor src/adjustor/hhd.py
  #   LEGION_GO_DMIS   = 83E1 (Go 8APU1), 83N0/83N1 (Go 2)
  #   LEGION_GO_S_DMIS = 83L3 (Z2 Go), 83N6 (Z1E), 83Q2/83Q3 (Go S)
  case "$product" in
    83E1|83N0|83N1|83L3|83N6|83Q2|83Q3)
      DEVICE="lenovo"
      DEVICE_LABEL="Lenovo Legion Go (${product})"
      # Legion drives TDP via the acpi_call module (\\_SB.GZFD GameZone WMI over
      # /proc/acpi/call), NOT platform_profile. This is the key Lenovo dependency.
      # Source: adjustor core/acpi.py, core/lenovo.py, drivers/lenovo/__init__.py
      TDP_KIND="acpi_call"
      TDP_MODULES=(acpi_call)
      TDP_CHECK_PATH="/proc/acpi/call"
      EXTRA_PKGS=(acpi_call-dkms)                        # provides the acpi_call module on Arch/CachyOS
      # No Lenovo analogue of asusd/asusctl exists -> nothing to remove here.
      CONFLICT_PKGS=()
      CONFLICT_SVC=""
      # No Legion HID module to blacklist. Instead the controllers need xpad bound
      # via HHD's shipped udev rule (usr/lib/udev/rules.d/83-hhd.rules), esp. the
      # Go S (VID 1a86 PID e310). Ensure HHD's udev rules are installed.
      HID_BLACKLIST=()
      # hid_lenovo_go: mainline HID driver for the Legion Go/Go S/Go 2 controllers
      # (queued for Linux 7.1). Exposes the controllers' config: rumble intensity,
      # RGB, auto-sleep, calibration, OS mode -- i.e. what HHD drives for Legion.
      # Auto-loads via modalias when the controller is present on a kernel that has
      # it; we ensure it's loaded and warn if the kernel is too old.
      # NOTE: verify the exact module name on the target kernel (may be hid_legion /
      # hid_lenovo_legion_go depending on the merged naming). src: hid.git for-7.1/lenovo-v2.
      CONTROLLER_MODULES=(hid_lenovo_go)
      NEEDS_UDEV_XPAD=1
      KERNEL_NOTE="Legion deps: acpi_call (TDP) + xpad binding via HHD's udev rule for the controllers, plus the hid_lenovo_go driver (Linux 7.1+) for controller config (rumble/RGB/sleep). On older kernels hid_lenovo_go is absent -> use a 7.1+/Bazzite kernel for full Legion controller config. Go 2 (83N0/83N1) specifics UNCONFIRMED."
      return 0
      ;;
  esac

  # ---- unknown ----
  DEVICE="unknown"
  DEVICE_LABEL="Unknown (vendor='${vendor:-?}' product='${product:-?}' board='${board:-?}')"
  return 0
}
