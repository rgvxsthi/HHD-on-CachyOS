#!/usr/bin/env bash
# Re-exec under bash if started with sh/dash (script uses bash features).
if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi
#
# setup.sh - Install and configure Handheld Daemon (HHD) on CachyOS.
#
# Supports ASUS ROG Ally / Ally X / ROG Xbox Ally and Lenovo Legion Go / Go S / Go 2.
# The device is auto-detected from DMI and the right actions are applied
# (see lib/device-profile.sh).
#
# Tested on: CachyOS Handheld Edition, ASUS ROG Ally Z1 Extreme, kernel 6.19+ / 7.0.x.
# Lenovo support is derived from HHD source and is UNVERIFIED on real hardware.
#
# Usage:
#   ./setup.sh                 interactive (recommended)
#   ./setup.sh --debug         verbose: trace every command (also -debug, -d)
#   ./setup.sh --yes           assume yes to prompts (still asks before reboot); also -y
#   ./setup.sh --no-reboot     never prompt to reboot
#   ./setup.sh --help          this help; also -h
#
# Every run writes a full log to ~/hhd-setup-<timestamp>.log and prints a
# diagnostic report at the end you can paste into a GitHub issue or Reddit.

set -uo pipefail

# ---------- locate + source the device profile library ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -r "$SCRIPT_DIR/lib/device-profile.sh" ]]; then
  printf 'error: lib/device-profile.sh not found next to setup.sh\n' >&2
  exit 1
fi
# shellcheck source=lib/device-profile.sh
source "$SCRIPT_DIR/lib/device-profile.sh"

# ---------- args ----------
DEBUG=0; ASSUME_YES=0; REBOOT_PROMPT=1; STEAM_SLIDER="ask"
usage() {
  cat <<'EOH'
setup.sh - Install and configure Handheld Daemon (HHD) on CachyOS.

Supports ASUS ROG Ally family and Lenovo Legion Go family (auto-detected).
Tested on CachyOS Handheld Edition, ASUS ROG Ally Z1 Extreme, kernel 6.19+ / 7.0.x.
Lenovo support is derived from HHD source and unverified on hardware.

Usage:
  ./setup.sh                   interactive (recommended)
  ./setup.sh --debug           verbose: trace every command (also -debug, -d)
  ./setup.sh --yes             assume yes to prompts (still asks before reboot); also -y
  ./setup.sh --steam-slider    also install steamos-manager-hhd (in-Steam TDP slider, AUR)
  ./setup.sh --no-steam-slider skip the in-Steam TDP slider without asking
  ./setup.sh --no-reboot       never prompt to reboot
  ./setup.sh --help            this help; also -h

Writes a full log to ~/hhd-setup-<timestamp>.log and prints a diagnostic
report at the end you can paste into a GitHub issue or Reddit.
EOH
  exit 0
}
for arg in "$@"; do
  case "$arg" in
    -d|--debug|-debug)   DEBUG=1 ;;
    -y|--yes|-yes)       ASSUME_YES=1 ;;
    --steam-slider)      STEAM_SLIDER="yes" ;;
    --no-steam-slider)   STEAM_SLIDER="no" ;;
    --no-reboot)         REBOOT_PROMPT=0 ;;
    -h|--help|-help)     usage ;;
    *) printf 'unknown option: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

# ---------- colors (captured before output is redirected) ----------
if [ -t 1 ]; then
  c_reset=$'\e[0m'; c_red=$'\e[31m'; c_grn=$'\e[32m'; c_ylw=$'\e[33m'; c_blu=$'\e[34m'; c_bold=$'\e[1m'
else
  c_reset=''; c_red=''; c_grn=''; c_ylw=''; c_blu=''; c_bold=''
fi

# ---------- logging: tee everything to a logfile (ANSI stripped in the file) ----------
LOGFILE="${HOME}/hhd-setup-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee >(sed -u 's/\x1b\[[0-9;]*m//g' >> "$LOGFILE")) 2>&1

ts()   { date '+%H:%M:%S'; }
log()  { printf '%s %s\n' "$(ts)" "$*"; }
info() { printf '%s %s[*]%s %s\n'  "$(ts)" "$c_blu" "$c_reset" "$*"; }
ok()   { printf '%s %s[ok]%s %s\n' "$(ts)" "$c_grn" "$c_reset" "$*"; }
warn() { printf '%s %s[!]%s %s\n'  "$(ts)" "$c_ylw" "$c_reset" "$*"; }
err()  { printf '%s %s[x]%s %s\n'  "$(ts)" "$c_red" "$c_reset" "$*"; }
step() { printf '\n%s========== %s ==========%s\n' "$c_bold" "$*" "$c_reset"; }

declare -a SUMMARY
pass()  { ok "$1";  SUMMARY+=("PASS|$1"); }
warnr() { warn "$1"; SUMMARY+=("WARN|$1"); }
failr() { err "$1"; SUMMARY+=("FAIL|$1"); }

confirm() {
  [[ "$ASSUME_YES" -eq 1 ]] && { info "auto-yes: $1"; return 0; }
  if [[ ! -e /dev/tty ]]; then warn "no TTY for prompt; defaulting to NO: $1"; return 1; fi
  local ans
  printf '\n%s[?]%s %s [y/N] ' "$c_ylw" "$c_reset" "$1" > /dev/tty
  read -r ans < /dev/tty || true
  if [[ "$ans" =~ ^[Yy]$ ]]; then log "  -> yes"; return 0; else log "  -> no"; return 1; fi
}

pkg_installed() { pacman -Qq "$1" &>/dev/null; }
# svc_masked / svc_exists / detect_device / aur_makepkg_install come from lib/device-profile.sh

# ---------- debug trace ----------
if [[ "$DEBUG" -eq 1 ]]; then
  export PS4='+ ${BASH_SOURCE##*/}:${LINENO}: '
  exec 9>>"$LOGFILE"
  BASH_XTRACEFD=9
  set -x
fi

# ---------- banner ----------
step "HHD setup for CachyOS"
log "date:    $(date -Is)"
log "args:    debug=$DEBUG yes=$ASSUME_YES reboot_prompt=$REBOOT_PROMPT"
log "logfile: $LOGFILE"

# ---------- 1. not root ----------
step "1. Preconditions"
if [[ "$(id -u)" -eq 0 ]]; then
  failr "Running as root. Re-run WITHOUT sudo; the hhd@<user> service needs your username."
  exit 1
fi
REAL_USER="$(id -un)"
pass "Running as user: ${REAL_USER}"

if ! command -v pacman &>/dev/null; then
  failr "pacman not found. This targets CachyOS (Arch-based)."
  exit 1
fi
if [[ -r /etc/os-release ]] && grep -qi cachyos /etc/os-release; then
  pass "CachyOS detected: $(. /etc/os-release; echo "${PRETTY_NAME:-?}")"
else
  warnr "Not detected as CachyOS. Untested here."
  confirm "Continue anyway?" || { info "Aborted."; exit 0; }
fi

# ---------- 1b. detect device ----------
detect_device
case "$DEVICE" in
  asus)   pass "Device: ${DEVICE_LABEL}" ;;
  lenovo)
    pass "Device: ${DEVICE_LABEL}"
    warnr "Lenovo support is unverified on hardware; proceeding with the Legion profile." ;;
  *)
    warnr "Unrecognized handheld: ${DEVICE_LABEL}"
    info "No device profile matched. The shared steps (InputPlumber, PPD, HHD install)"
    info "will still run, but TDP module/package choices may be wrong."
    confirm "Continue with generic handling?" || { info "Aborted."; exit 0; } ;;
esac
log "profile: TDP_KIND=${TDP_KIND:-none} modules=[${TDP_MODULES[*]:-}] extra_pkgs=[${EXTRA_PKGS[*]:-}] conflicts=[${CONFLICT_PKGS[*]:-}]"

# ---------- 1c. snapshot pre-setup state (so uninstall restores faithfully) ----------
# Captured BEFORE any change. uninstall.sh reads this to put back exactly what
# was here (InputPlumber, stock steamos-manager, PPD/tuned state, vendor pkgs).
STATE_FILE="$(hhd_state_file)"
if [[ -e "$STATE_FILE" ]]; then
  # Write-once: a re-run must NOT clobber the true pre-install baseline with
  # already-modified state. uninstall.sh removes the snapshot, so a fresh setup
  # after an uninstall writes a new one.
  pass "Pre-setup snapshot already exists ($STATE_FILE); keeping the original"
elif mkdir -p "$(dirname "$STATE_FILE")" 2>/dev/null; then
  {
    echo "# hhd-on-cachyos pre-setup snapshot (used by uninstall.sh). Do not edit."
    echo "PRE_SAVED_AT='$(date -Is)'"
    echo "PRE_DEVICE='$DEVICE'"
    echo "PRE_INPUTPLUMBER_INSTALLED=$(pkg_installed inputplumber && echo 1 || echo 0)"
    echo "PRE_INPUTPLUMBER_ENABLED='$(systemctl is-enabled inputplumber 2>/dev/null || echo unknown)'"
    echo "PRE_PPD_INSTALLED=$(pkg_installed power-profiles-daemon && echo 1 || echo 0)"
    echo "PRE_PPD_ENABLED='$(systemctl is-enabled power-profiles-daemon 2>/dev/null || echo unknown)'"
    echo "PRE_TUNED_INSTALLED=$(pkg_installed tuned && echo 1 || echo 0)"
    echo "PRE_TUNED_ENABLED='$(systemctl is-enabled tuned 2>/dev/null || echo unknown)'"
    echo "PRE_STEAMOS_STOCK_INSTALLED=$(pkg_installed "$STEAMOS_STOCK_PKG" && echo 1 || echo 0)"
    echo "PRE_VENDOR_REMOVED=''"
    echo "PRE_SLIDER_INSTALLED=0"
  } > "$STATE_FILE"
  pass "Saved pre-setup snapshot ($STATE_FILE) for a faithful uninstall"
else
  warnr "Could not write pre-setup snapshot; uninstall will fall back to CachyOS defaults"
  STATE_FILE=""
fi
# helper: record a key=value action into the snapshot (last line wins when sourced)
state_record() { [[ -n "$STATE_FILE" ]] && printf '%s\n' "$1" >> "$STATE_FILE"; }

# ---------- 2. kernel + TDP backend ----------
step "2. Kernel and TDP backend"
KREL="$(uname -r)"; log "kernel: $KREL"
KVER="$(printf '%s' "$KREL" | grep -oE '^[0-9]+\.[0-9]+' || true)"
KMAJ="${KVER%%.*}"; KMIN="${KVER#*.}"
if [[ -n "$KVER" ]] && ! (( KMAJ < 6 || (KMAJ == 6 && KMIN < 19) )); then
  pass "Kernel $KREL (>= 6.19)"
else
  warnr "Kernel $KREL is older than 6.19; TDP support may not appear."
  if confirm "Run full update now (pacman -Syu)? You will reboot and re-run after."; then
    pac -Syu
    ok "Update done. Reboot, then run ./setup.sh again."
    exit 0
  fi
  confirm "Continue without updating?" || { info "Aborted."; exit 0; }
fi
[[ -n "$KERNEL_NOTE" ]] && info "$KERNEL_NOTE"

# Load and verify the device's TDP modules.
for m in "${TDP_MODULES[@]:-}"; do
  [[ -z "$m" ]] && continue
  if mod_loaded "$m"; then
    pass "$m loaded"
  else
    warn "$m not loaded; trying modprobe..."
    if sudo modprobe "$m" 2>/dev/null && mod_loaded "$m"; then
      pass "$m loaded"
    else
      warnr "$m not loaded yet (Legion: install acpi_call-dkms below; ASUS: usually loads after reboot)"
    fi
  fi
done

# Verify the TDP interface path.
if [[ -n "$TDP_CHECK_PATH" ]]; then
  if [[ -e "$TDP_CHECK_PATH" ]]; then
    if [[ "$TDP_KIND" == "asus_wmi" && -r "$TDP_CHECK_PATH" ]]; then
      pass "platform_profile choices: $(cat /sys/firmware/acpi/platform_profile_choices 2>/dev/null || echo '?')"
    else
      pass "TDP interface present: $TDP_CHECK_PATH"
    fi
  else
    warnr "TDP interface $TDP_CHECK_PATH missing (expected for ${TDP_KIND}); TDP may not work until modules/pkgs are in place"
  fi
fi

# ---------- 3. InputPlumber (shared) ----------
step "3. Remove InputPlumber"
if pkg_installed inputplumber; then
  warn "InputPlumber installed; it fights HHD over the controller."
  if confirm "Stop, mask, and remove InputPlumber?"; then
    sudo systemctl mask --now inputplumber || true
    if pac -R inputplumber; then pass "InputPlumber removed and masked"; else failr "Could not remove InputPlumber"; fi
  else
    warnr "InputPlumber left in place; HHD button remapping will likely fail"
  fi
else
  pass "InputPlumber not installed"
fi

# ---------- 4. power-profiles-daemon + TuneD (shared) ----------
step "4. Mask power-profiles-daemon / TuneD"
info "adjustor writes the power profile directly and serves the PPD D-Bus API itself;"
info "PPD or TuneD running alongside it makes TDP silently fail. Upstream masks them."
for pair in "${PPD_SVC}:${PPD_ACTION}" "${TUNED_SVC}:${TUNED_ACTION}"; do
  svc="${pair%%:*}"; act="${pair##*:}"
  [[ "$act" == "none" ]] && continue
  short="${svc%.service}"
  if svc_masked "$svc"; then
    pass "$short already masked"
    continue
  fi
  if ! svc_exists "$svc"; then
    pass "$short not present"
    continue
  fi
  if [[ "$(systemctl is-active "$svc" 2>/dev/null || true)" != "active" && \
        "$(systemctl is-enabled "$svc" 2>/dev/null || true)" == "disabled" ]]; then
    info "$short present but inactive+disabled; masking anyway to stop D-Bus reactivation."
  fi
  if confirm "Mask $short so it can't fight adjustor over TDP?"; then
    sudo systemctl mask --now "$svc" 2>/dev/null \
      && pass "$short masked" \
      || warnr "Could not mask $short"
  else
    warnr "$short left running; TDP control may silently fail"
  fi
done

# ---------- 5. device-specific userspace conflicts ----------
step "5. Conflicting vendor userspace"
if (( ${#CONFLICT_PKGS[@]} > 0 )); then
  FOUND_PKGS=()
  for p in "${CONFLICT_PKGS[@]}"; do pkg_installed "$p" && FOUND_PKGS+=("$p"); done
  if (( ${#FOUND_PKGS[@]} > 0 )); then
    warn "Found: ${FOUND_PKGS[*]} (fights adjustor over the platform profile)"
    if confirm "Disable ${CONFLICT_SVC:-service} and remove these?"; then
      [[ -n "$CONFLICT_SVC" ]] && sudo systemctl disable --now "$CONFLICT_SVC" 2>/dev/null || true
      if pac -R "${FOUND_PKGS[@]}"; then
        pass "Vendor userspace stack removed"
        state_record "PRE_VENDOR_REMOVED='${FOUND_PKGS[*]}'"
      else failr "Could not remove vendor stack"; fi
    else
      warnr "Vendor stack left in place; it may fight adjustor for TDP"
    fi
  else
    pass "No conflicting vendor userspace found"
  fi
else
  pass "No vendor userspace conflicts for this device (${DEVICE})"
fi

# ---------- 6. install HHD (+ device extras) ----------
step "6. Install hhd, adjustor, hhd-ui${EXTRA_PKGS:+ + extras}"
INSTALL_PKGS=(hhd adjustor hhd-ui "${EXTRA_PKGS[@]:-}")
# drop any empty element from the extras expansion
CLEAN_PKGS=(); for p in "${INSTALL_PKGS[@]}"; do [[ -n "$p" ]] && CLEAN_PKGS+=("$p"); done
(( ${#EXTRA_PKGS[@]:-0} > 0 )) && info "Device extras: ${EXTRA_PKGS[*]} (Legion needs acpi_call for TDP)"
if pac -S --needed "${CLEAN_PKGS[@]}"; then
  pass "Packages installed: ${CLEAN_PKGS[*]}"
else
  failr "pacman could not install one or more packages"
  err "If not in your repos, use an AUR helper: paru -S ${CLEAN_PKGS[*]}"
  exit 1
fi

# Legion: TDP module comes from acpi_call-dkms just installed; try loading now.
if [[ "$TDP_KIND" == "acpi_call" ]]; then
  if sudo modprobe acpi_call 2>/dev/null && [[ -e /proc/acpi/call ]]; then
    pass "acpi_call loaded (Legion TDP path ready)"
  else
    warnr "acpi_call not loaded yet; it should load after the reboot at the end"
  fi
fi

# ---------- 7. version sanity ----------
step "7. Version check"
hver="$(pacman -Q hhd | awk '{print $2}')"; aver="$(pacman -Q adjustor 2>/dev/null | awk '{print $2}')"
log "hhd=$hver adjustor=${aver:-bundled} hhd-ui=$(pacman -Q hhd-ui 2>/dev/null | awk '{print $2}')"
if [[ -n "$aver" && "${hver%%.*}" != "${aver%%.*}" ]]; then
  warnr "hhd/adjustor major versions differ (${hver%%.*} vs ${aver%%.*}); daemon may skip the plugin"
elif [[ -z "$aver" ]]; then
  info "adjustor not a separate package (merged into hhd as of v4) — fine."
else
  pass "hhd and adjustor major versions match (${hver%%.*}.x)"
fi

# ---------- 8. enable + start ----------
step "8. Enable and start hhd@${REAL_USER}"
sudo systemctl enable --now "hhd@${REAL_USER}"
info "Waiting 5s for the daemon to initialize..."
sleep 5

# ---------- 8b. optional: in-Steam TDP slider (SteamOS/Bazzite style) ----------
step "8b. Optional: in-Steam TDP slider"
do_slider=0
case "$STEAM_SLIDER" in
  yes) do_slider=1 ;;
  no)  info "Skipping (--no-steam-slider)." ;;
  ask)
    # Do NOT pull a heavy AUR build silently under --yes; require an explicit
    # --steam-slider for unattended runs. Only prompt in a real interactive run.
    if [[ "$ASSUME_YES" -eq 1 ]]; then
      info "Skipping the in-Steam slider under --yes. Pass --steam-slider to opt in."
    elif confirm "Install steamos-manager-hhd for the in-Steam TDP slider (SteamOS/Bazzite Deck menu)? Builds from AUR and replaces stock steamos-manager."; then
      do_slider=1
    else
      info "Skipped."
    fi ;;
esac
if [[ "$do_slider" -eq 1 ]]; then
  if [[ "$(id -u)" -eq 0 ]]; then
    warnr "Cannot build the AUR slider as root; re-run setup.sh as your user. Skipping."
  else
    # steamos-tdp writes explicit watts via acpi_call; ensure the module is available.
    if ! pkg_installed acpi_call-dkms && ! mod_loaded acpi_call; then
      info "Installing acpi_call-dkms (needed for the slider's custom-watt TDP writes)."
      pac -S --needed acpi_call-dkms || warnr "acpi_call-dkms install failed; the slider's custom TDP may not write"
    fi
    info "Building ${STEAMOS_HHD_PKG} directly from the AUR with makepkg"
    info "(installs git/base-devel + pulls rust/clang; this takes a while)..."
    if aur_makepkg_install "$STEAMOS_HHD_PKG" "$ASSUME_YES"; then
      pass "${STEAMOS_HHD_PKG} installed (replaces stock steamos-manager)"
      state_record "PRE_SLIDER_INSTALLED=1"
      sudo systemctl enable --now "$STEAMOS_HHD_SYS_SVC" 2>/dev/null \
        && pass "system steamos-manager.service enabled" \
        || warnr "could not enable system steamos-manager.service"
      if systemctl --user enable --now "$STEAMOS_HHD_USER_SVC" 2>/dev/null; then
        pass "user steamos-manager.service enabled"
      else
        warnr "could not enable the USER steamos-manager.service now (no graphical session bus?)."
        info "Run this inside your desktop session: systemctl --user enable --now ${STEAMOS_HHD_USER_SVC}"
      fi
      info "Finish in the HHD app: turn ON 'Enable TDP Controls'."
      info "The slider appears in Steam's Deck performance menu in GAME MODE (gamescope),"
      info "not desktop Big Picture. Disable any Decky TDP plugin (SimpleDeckyTDP/PowerControl)"
      info "or HHD reports a conflict and greys the slider out. The HHD overlay keeps working."
    else
      warnr "${STEAMOS_HHD_PKG} build/install failed; see the makepkg output above"
      info "Manual retry: git clone https://aur.archlinux.org/${STEAMOS_HHD_PKG}.git && cd ${STEAMOS_HHD_PKG} && makepkg -si"
    fi
  fi
fi

# ---------- 9. verify ----------
step "9. Verify"
[[ "$(systemctl is-active inputplumber 2>/dev/null || true)" == "active" ]] \
  && failr "InputPlumber active again (something reactivated it)" \
  || pass "InputPlumber not active"

for svc in "$PPD_SVC" "$TUNED_SVC"; do
  short="${svc%.service}"
  [[ "$(systemctl is-active "$svc" 2>/dev/null || true)" == "active" ]] \
    && warnr "$short still active (TDP may fail)" || true
done

[[ "$(systemctl is-active "hhd@${REAL_USER}" 2>/dev/null || true)" == "active" ]] \
  && pass "hhd@${REAL_USER} active" \
  || failr "hhd@${REAL_USER} not active (see: systemctl status hhd@${REAL_USER})"

# Capture first, then grep the string (a `journalctl | grep -q` under pipefail can
# SIGPIPE when grep matches early and wrongly report a failure).
jout="$(sudo journalctl -u "hhd@${REAL_USER}" -b --no-pager 2>/dev/null || true)"
if grep -qiE 'adjustor|tdp' <<<"$jout"; then
  pass "adjustor/TDP activity in the journal"
else
  warnr "no adjustor/TDP journal lines yet; check again in a moment"
fi

if grep -qi 'Handheld Daemon Controller' /proc/bus/input/devices 2>/dev/null; then
  pass "HHD virtual controller present"
else
  warnr "HHD virtual controller not seen yet (often appears after reboot)"
fi

if [[ "$NEEDS_UDEV_XPAD" -eq 1 ]]; then
  info "Legion: controllers rely on HHD's udev rule binding xpad. If the controller"
  info "is missing after reboot, confirm /usr/lib/udev/rules.d/83-hhd.rules is present."
fi

# ---------- 10. diagnostics ----------
diagnostics() {
  set +e
  step "DIAGNOSTIC REPORT (copy from BEGIN to END)"
  echo "----- BEGIN HHD DIAGNOSTICS -----"
  echo "date:   $(date -Is)"
  echo "user:   $(id -un)"
  echo "device: ${DEVICE_LABEL} (profile=${DEVICE}, tdp=${TDP_KIND})"
  echo "os:     $(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}")"
  echo "kernel: $(uname -r)"
  echo "dmi:    product_name=$(dmi product_name) sys_vendor=$(dmi sys_vendor)"
  echo
  echo "## modules"
  lsmod | grep -iE 'hid_asus|asus_wmi|asus_armoury|acpi_call|xpad|inputplumber|platform_profile' || echo "(none matched)"
  echo
  echo "## TDP interface"
  if [[ "$TDP_KIND" == "acpi_call" ]]; then
    echo "acpi_call: $( [[ -e /proc/acpi/call ]] && echo present || echo MISSING )"
  else
    echo "platform_profile choices: $(cat /sys/firmware/acpi/platform_profile_choices 2>/dev/null || echo missing)"
    echo "platform_profile current: $(cat /sys/firmware/acpi/platform_profile 2>/dev/null || echo missing)"
  fi
  echo
  echo "## packages"
  for p in hhd adjustor hhd-ui acpi_call-dkms inputplumber power-profiles-daemon tuned asusctl rog-control-center supergfxctl; do
    if pacman -Qq "$p" &>/dev/null; then echo "$p $(pacman -Q "$p" | awk '{print $2}')"; else echo "$p NOT installed"; fi
  done
  echo
  echo "## services"
  for s in "hhd@$(id -un)" inputplumber power-profiles-daemon tuned asusd; do
    echo "$s: active=$(systemctl is-active "$s" 2>/dev/null) enabled=$(systemctl is-enabled "$s" 2>/dev/null)"
  done
  echo
  echo "## hhd journal (filtered, last 40)"
  sudo journalctl -u "hhd@$(id -un)" -b --no-pager 2>/dev/null | grep -iE 'adjustor|asus|lenovo|acpi|tdp|profile|error|overlay' | tail -40 || echo "(none)"
  echo
  echo "## input devices (controllers)"
  grep -iE 'name=' /proc/bus/input/devices 2>/dev/null | grep -iE 'asus|x-box|xbox|dualsense|microsoft|handheld|rog|legion|sony' || echo "(none matched)"
  echo "----- END HHD DIAGNOSTICS -----"
  set -u
}
diagnostics

# ---------- 11. summary ----------
step "SUMMARY"
fails=0; warns=0
for row in "${SUMMARY[@]}"; do
  s="${row%%|*}"; t="${row#*|}"
  case "$s" in
    PASS) printf '%s[PASS]%s %s\n' "$c_grn" "$c_reset" "$t" ;;
    WARN) printf '%s[WARN]%s %s\n' "$c_ylw" "$c_reset" "$t"; warns=$((warns+1)) ;;
    FAIL) printf '%s[FAIL]%s %s\n' "$c_red" "$c_reset" "$t"; fails=$((fails+1)) ;;
  esac
done
echo
log "Result: $fails fail, $warns warn."
log "Full log saved to: $LOGFILE"

# ---------- 12. reboot ----------
step "Next steps"
cat <<EONOTE
- Desktop mode: open the "Handheld Daemon" app to set TDP, fans, RGB, buttons.
- Game Mode: double-tap the small menu button for the overlay.
- After reboot, run ./verify.sh to confirm the live state.
EONOTE
echo
if [[ "$REBOOT_PROMPT" -eq 1 ]]; then
  if confirm "Reboot now for a clean input handoff?"; then sudo reboot; else info "Reboot yourself when ready: sudo reboot"; fi
else
  info "Skipping reboot prompt (--no-reboot). Reboot before using: sudo reboot"
fi
