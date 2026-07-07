#!/usr/bin/env bash
if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi
#
# verify.sh - Read-only post-reboot health check for HHD on CachyOS.
# Auto-detects ASUS ROG Ally vs Lenovo Legion Go and checks EVERYTHING setup.sh
# does: TDP backend, all TDP-control front-ends (HHD app/overlay + in-Steam
# slider), conflict masking, controller, and the optional slider unit chain.
# Changes nothing.
#
# Usage:
#   ./verify.sh            normal
#   ./verify.sh --debug    trace every command (also -debug, -d)
#
# Writes a log to ~/hhd-verify-<timestamp>.log and prints a pasteable report.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -r "$SCRIPT_DIR/lib/device-profile.sh" ]]; then
  printf 'error: lib/device-profile.sh not found next to verify.sh\n' >&2
  exit 1
fi
# shellcheck source=lib/device-profile.sh
source "$SCRIPT_DIR/lib/device-profile.sh"

DEBUG=0
for arg in "$@"; do case "$arg" in -d|--debug|-debug) DEBUG=1 ;; -h|--help) sed -n '5,16p' "$0" | sed 's/^# \{0,1\}//;s/^#//'; exit 0 ;; *) echo "unknown: $arg" >&2; exit 2 ;; esac; done

if [ -t 1 ]; then c_reset=$'\e[0m'; c_red=$'\e[31m'; c_grn=$'\e[32m'; c_ylw=$'\e[33m'; c_bold=$'\e[1m'
else c_reset=''; c_red=''; c_grn=''; c_ylw=''; c_bold=''; fi

LOGFILE="${HOME}/hhd-verify-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee >(sed -u 's/\x1b\[[0-9;]*m//g' >> "$LOGFILE")) 2>&1

FAILS=0; WARNS=0
pass() { printf '%s[PASS]%s %s\n' "$c_grn" "$c_reset" "$*"; }
fail() { printf '%s[FAIL]%s %s\n' "$c_red" "$c_reset" "$*"; FAILS=$((FAILS+1)); }
warn() { printf '%s[WARN]%s %s\n' "$c_ylw" "$c_reset" "$*"; WARNS=$((WARNS+1)); }
sec()  { printf '\n%s-- %s --%s\n' "$c_bold" "$*" "$c_reset"; }
pkg_installed() { pacman -Qq "$1" &>/dev/null; }

[[ "$(id -u)" -eq 0 ]] && { fail "Run as your normal user, not root."; exit 1; }
REAL_USER="$(id -un)"
if [[ "$DEBUG" -eq 1 ]]; then export PS4='+ ${LINENO}: '; exec 9>>"$LOGFILE"; BASH_XTRACEFD=9; set -x; fi

detect_device

printf '%sHHD health check (user: %s)%s\n' "$c_bold" "$REAL_USER" "$c_reset"
echo "device: ${DEVICE_LABEL} (profile=${DEVICE}, tdp=${TDP_KIND:-?})"
echo "kernel: $(uname -r)   log: $LOGFILE"

# ============================================================================
sec "1. Kernel + TDP backend"
# ============================================================================
KVER="$(uname -r | grep -oE '^[0-9]+\.[0-9]+' || true)"; KMAJ="${KVER%%.*}"; KMIN="${KVER#*.}"
if [[ -n "$KVER" ]] && ! (( KMAJ < 6 || (KMAJ == 6 && KMIN < 19) )); then pass "Kernel >= 6.19 ($(uname -r))"; else warn "Kernel < 6.19 ($(uname -r)); TDP may be limited"; fi

for m in "${TDP_MODULES[@]:-}"; do
  [[ -z "$m" ]] && continue
  if mod_loaded "$m"; then pass "$m loaded"; else
    if [[ "$m" == "acpi_call" ]]; then fail "$m not loaded (Legion TDP will not work; install acpi_call-dkms)"
    elif [[ "$m" == "asus_armoury" ]]; then warn "$m not loaded"
    else fail "$m not loaded"; fi
  fi
done

case "$TDP_KIND" in
  asus_wmi)
    if [[ -r /sys/firmware/acpi/platform_profile_choices ]]; then pass "platform_profile: $(cat /sys/firmware/acpi/platform_profile_choices)"; else fail "platform_profile_choices missing"; fi ;;
  acpi_call)
    if [[ -e /proc/acpi/call ]]; then pass "acpi_call interface present (/proc/acpi/call)"; else fail "/proc/acpi/call missing (Legion TDP path)"; fi ;;
  *)
    warn "Unknown device: cannot check a specific TDP interface" ;;
esac

# ============================================================================
sec "2. Packages"
# ============================================================================
for p in hhd hhd-ui; do
  if pkg_installed "$p"; then pass "$p installed ($(pacman -Q "$p" | awk '{print $2}'))"; else fail "$p NOT installed"; fi
done
if pkg_installed adjustor; then pass "adjustor installed ($(pacman -Q adjustor | awk '{print $2}'))"; else warn "adjustor not a separate package (merged into hhd v4+) — OK"; fi
for p in "${EXTRA_PKGS[@]:-}"; do
  [[ -z "$p" ]] && continue
  pkg_installed "$p" && pass "$p installed (device extra)" || fail "$p NOT installed (needed for ${DEVICE} TDP)"
done

# ============================================================================
sec "3. Conflicts masked / gone"
# ============================================================================
# InputPlumber: setup masks + removes it. Either state is fine as long as it's not active.
if [[ "$(systemctl is-active inputplumber 2>/dev/null || true)" == "active" ]]; then
  fail "InputPlumber active (should be masked/removed)"
elif ! pkg_installed inputplumber; then pass "InputPlumber removed"
elif svc_masked inputplumber; then pass "InputPlumber masked"
else warn "InputPlumber present, not active, not masked (could reactivate via D-Bus)"; fi

# PPD + tuned: setup MASKS these. Confirm masked (not merely inactive) if present.
for svc in "$PPD_SVC" "$TUNED_SVC"; do
  short="${svc%.service}"
  if ! svc_exists "$svc"; then pass "$short not present"
  elif [[ "$(systemctl is-active "$svc" 2>/dev/null || true)" == "active" ]]; then fail "$short ACTIVE (fights adjustor; run: sudo systemctl mask --now $svc)"
  elif svc_masked "$svc"; then pass "$short masked"
  else warn "$short present + inactive but NOT masked (can reactivate via D-Bus; mask it)"; fi
done

# vendor userspace daemon (ASUS asusd); none on Lenovo
if [[ -n "$CONFLICT_SVC" ]]; then
  [[ "$(systemctl is-active "$CONFLICT_SVC" 2>/dev/null || true)" == "active" ]] && warn "$CONFLICT_SVC active (conflicts with adjustor TDP)" || pass "$CONFLICT_SVC not active"
fi
# vendor conflict packages still installed?
for p in "${CONFLICT_PKGS[@]:-}"; do
  [[ -z "$p" ]] && continue
  pkg_installed "$p" && warn "$p still installed (vendor stack fights adjustor)" || pass "$p not installed"
done

# ============================================================================
sec "4. HHD daemon + TDP controls (all front-ends)"
# ============================================================================
[[ "$(systemctl is-active "hhd@${REAL_USER}" 2>/dev/null || true)" == "active" ]] && pass "hhd@${REAL_USER} active" || fail "hhd@${REAL_USER} not active (systemctl status hhd@${REAL_USER})"

# HHD API socket: the desktop app, the gamescope overlay, and the in-Steam slider
# all drive TDP through this one socket. If it's live, all front-ends can control TDP.
if [[ -S /run/hhd/api ]]; then pass "HHD API socket live (/run/hhd/api) — app/overlay/slider backend up"
else warn "HHD API socket /run/hhd/api missing (daemon not fully up?)"; fi

# adjustor/TDP plugin actually loaded this boot
adj_log="$(sudo journalctl -u "hhd@${REAL_USER}" -b --no-pager 2>/dev/null | grep -iE 'adjustor|ADJA|thermal profile|setting tdp|lenovo|acpi' | tail -3)"
if [[ -n "$adj_log" ]]; then pass "adjustor/TDP plugin active in this boot's log"
elif [[ "$TDP_KIND" == "asus_wmi" ]] && mod_loaded asus_armoury && [[ -r /sys/firmware/acpi/platform_profile_choices ]]; then pass "TDP backend present (asus_armoury + platform_profile)"
elif [[ "$TDP_KIND" == "acpi_call" ]] && [[ -e /proc/acpi/call ]]; then pass "TDP backend present (acpi_call interface)"
else warn "Could not confirm the TDP backend; open the HHD app and check the TDP section"; fi

# Definitive TDP-control status oracle: hhd.steamos reports whether TDP controls
# are ENABLED (this is the same gate the HHD UI slider and the in-Steam slider use).
if command -v hhd.steamos &>/dev/null; then
  tdp_out="$(hhd.steamos steamos-tdp get 2>/dev/null)"; tdp_rc=$?
  # Upstream semantics: 1=inactive, 2=conflict, anything else=active/enabled.
  case "$tdp_rc" in
    1) warn "HHD TDP controls INACTIVE — turn ON 'Enable TDP Controls' in the HHD app" ;;
    2) fail "HHD TDP controls in CONFLICT — a Decky TDP plugin (SimpleDeckyTDP/PowerControl) is active; disable it" ;;
    *) pass "HHD TDP controls ENABLED (status $tdp_rc; current: ${tdp_out:-?})" ;;
  esac
else
  warn "hhd.steamos helper not found; cannot read TDP-control status (old hhd?)"
fi

# HHD UI (the desktop app / overlay front-end)
if pkg_installed hhd-ui; then pass "hhd-ui installed (desktop app + gamescope overlay TDP/fan/RGB controls)"; else fail "hhd-ui NOT installed (no HHD app UI)"; fi

# pre-setup snapshot (lets uninstall.sh restore the exact pre-install state)
if [[ -r "$(hhd_state_file)" ]]; then pass "pre-setup snapshot present — uninstall will restore the exact pre-install state"
else echo "  pre-setup snapshot: none (uninstall falls back to CachyOS defaults; only setups from v1.0.4+ write one)"; fi

# ============================================================================
sec "5. In-Steam TDP slider (optional SteamOS/Bazzite integration)"
# ============================================================================
if pkg_installed "$STEAMOS_HHD_PKG"; then
  pass "${STEAMOS_HHD_PKG} installed"
  # acpi_call is required for the slider's explicit-watt writes, on ANY device.
  if mod_loaded acpi_call || pkg_installed acpi_call-dkms; then pass "acpi_call available (slider custom-watt writes)"; else warn "acpi_call missing; the slider's custom TDP may not write (install acpi_call-dkms)"; fi
  # system unit
  if [[ "$(systemctl is-active "$STEAMOS_HHD_SYS_SVC" 2>/dev/null || true)" == "active" ]]; then pass "system steamos-manager.service active"
  else warn "system steamos-manager.service not active (D-Bus activated; may still start on demand)"; fi
  # user unit (the one Steam talks to)
  us="$(systemctl --user is-active "$STEAMOS_HHD_USER_SVC" 2>/dev/null || true)"
  if [[ "$us" == "active" ]]; then pass "user steamos-manager.service active"
  else warn "user steamos-manager.service not active — run: systemctl --user enable --now ${STEAMOS_HHD_USER_SVC}"; fi
  # D-Bus service registration
  if [[ -e /usr/share/dbus-1/services/com.steampowered.SteamOSManager1.service || -e /usr/share/dbus-1/system-services/com.steampowered.SteamOSManager1.service ]]; then
    pass "SteamOSManager1 D-Bus service registered"
  else warn "SteamOSManager1 D-Bus service file not found"; fi
  echo "  Slider shows in Steam's Deck performance menu in GAME MODE only, with HHD"
  echo "  'Enable TDP Controls' ON. It coexists with the HHD overlay."
else
  echo "  not installed (optional; add with: ./setup.sh --steam-slider)"
fi

# ============================================================================
sec "6. Controller"
# ============================================================================
echo "Controller devices seen by the kernel:"
grep -iE 'name=' /proc/bus/input/devices 2>/dev/null | grep -iE 'x-box|xbox|dualsense|handheld|rog|legion|microsoft' | sed 's/^/  /' || echo "  (none matched)"
if grep -qi 'Handheld Daemon Controller' /proc/bus/input/devices 2>/dev/null; then pass "HHD virtual controller present"; else warn "HHD virtual controller not present yet"; fi

if [[ "$DEVICE" == "asus" ]]; then
  # report blacklist state (setup/README optional step)
  if [[ -e /etc/modprobe.d/hhd-ally.conf ]]; then pass "hid_asus_ally blacklist present (/etc/modprobe.d/hhd-ally.conf)"; else echo "  hid_asus_ally blacklist: not applied (only needed in the double-controller case)"; fi
  echo
  echo "${c_bold}MANUAL CHECK (ASUS double-controller case):${c_reset}"
  echo "  Steam > Settings > Controller should show ONE controller. If TWO (HHD"
  echo "  emulated PLUS a separate 'ROG Ally'), apply the blacklist (README), else leave it."
elif [[ "$DEVICE" == "lenovo" ]]; then
  # Legion needs xpad + HHD udev rule
  [[ -e /usr/lib/udev/rules.d/83-hhd.rules ]] && pass "HHD udev rules present (83-hhd.rules; xpad binding)" || fail "HHD udev rules missing (/usr/lib/udev/rules.d/83-hhd.rules) — Legion controller may not bind"
  mod_loaded xpad && pass "xpad loaded" || warn "xpad not loaded (Legion controllers bind via xpad)"
  # hid_lenovo_go: controller config driver (rumble/RGB/sleep), Linux 7.1+
  for m in "${CONTROLLER_MODULES[@]:-}"; do
    [[ -z "$m" ]] && continue
    mod_loaded "$m" && pass "$m loaded (controller config: rumble/RGB/sleep)" || warn "$m not loaded — needs Linux 7.1+ (or a kernel with it); Legion controller config unavailable without it"
  done
  echo
  echo "${c_bold}MANUAL CHECK (Legion controllers):${c_reset}"
  echo "  No HID module to blacklist on Legion. If the controller is missing, the"
  echo "  xpad udev binding (above) is the thing to check. Go S = VID 1a86 PID e310."
fi

# ============================================================================
sec "7. Enforced TDP limits (ground truth)"
# ============================================================================
if command -v ryzenadj >/dev/null 2>&1 && mod_loaded ryzen_smu; then
  echo "Enforced limits right now (ryzenadj):"
  sudo ryzenadj -i 2>/dev/null | grep -iE 'STAPM LIMIT|PPT LIMIT' | sed 's/^/  /' || echo "  (ryzenadj read failed)"
else
  echo "For authoritative limits, install the SMU reader once:"
  echo "    sudo pacman -S ryzen_smu-dkms && sudo modprobe ryzen_smu"
  echo "  then: sudo ryzenadj -i | grep -iE 'STAPM|PPT LIMIT'"
fi

# ============================================================================
sec "RESULT"
# ============================================================================
echo "${FAILS} fail, ${WARNS} warn."

# ---- pasteable report ----
echo "------------------------------------------------------------"
echo "----- BEGIN HHD DIAGNOSTICS -----"
echo "date:   $(date -Is)"
echo "device: ${DEVICE_LABEL} (profile=${DEVICE}, tdp=${TDP_KIND:-?})"
echo "dmi:    product_name=$(dmi product_name) sys_vendor=$(dmi sys_vendor)"
echo "os:     $(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}")"
echo "kernel: $(uname -r)"
echo "result: ${FAILS} fail, ${WARNS} warn"
echo "## modules"
lsmod | grep -iE 'hid_asus|asus_wmi|asus_armoury|acpi_call|xpad|inputplumber|platform_profile|hid_lenovo|hid_legion|ryzen_smu' || echo "(no matching modules)"
echo "## packages"
for p in hhd adjustor hhd-ui acpi_call-dkms inputplumber power-profiles-daemon tuned asusctl rog-control-center supergfxctl "$STEAMOS_HHD_PKG"; do
  pacman -Qq "$p" &>/dev/null && echo "$p $(pacman -Q "$p" | awk '{print $2}')" || echo "$p NOT installed"
done
echo "## services"
echo "hhd@${REAL_USER}: active=$(systemctl is-active "hhd@${REAL_USER}" 2>/dev/null) enabled=$(systemctl is-enabled "hhd@${REAL_USER}" 2>/dev/null)"
for s in inputplumber power-profiles-daemon tuned asusd "$STEAMOS_HHD_SYS_SVC"; do
  echo "$s: active=$(systemctl is-active "$s" 2>/dev/null) enabled=$(systemctl is-enabled "$s" 2>/dev/null)"
done
echo "user-$STEAMOS_HHD_USER_SVC: active=$(systemctl --user is-active "$STEAMOS_HHD_USER_SVC" 2>/dev/null)"
echo "## tdp control status"
if command -v hhd.steamos &>/dev/null; then out="$(hhd.steamos steamos-tdp get 2>/dev/null)"; echo "hhd.steamos steamos-tdp get: rc=$? out=${out:-none}"; else echo "hhd.steamos: not found"; fi
echo "## api socket"; [[ -S /run/hhd/api ]] && echo "/run/hhd/api present" || echo "/run/hhd/api MISSING"
echo "## controllers"
grep -iE 'name=' /proc/bus/input/devices 2>/dev/null | grep -iE 'x-box|xbox|dualsense|handheld|rog|legion|microsoft' || true
echo "----- END HHD DIAGNOSTICS -----"
echo
echo "Log saved to: $LOGFILE"
