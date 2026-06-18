#!/usr/bin/env bash
if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi
#
# verify.sh - Read-only post-reboot health check for HHD on CachyOS / ROG Ally.
# Changes nothing. Confirms the live state and the double-controller case.
#
# Usage:
#   ./verify.sh            normal
#   ./verify.sh --debug    trace every command (also -debug, -d)
#
# Writes a log to ~/hhd-verify-<timestamp>.log and prints a pasteable report.

set -uo pipefail

DEBUG=0
for arg in "$@"; do case "$arg" in -d|--debug|-debug) DEBUG=1 ;; -h|--help) sed -n '5,12p' "$0" | sed 's/^# \{0,1\}//;s/^#//'; exit 0 ;; *) echo "unknown: $arg" >&2; exit 2 ;; esac; done

if [ -t 1 ]; then c_reset=$'\e[0m'; c_red=$'\e[31m'; c_grn=$'\e[32m'; c_ylw=$'\e[33m'; c_bold=$'\e[1m'
else c_reset=''; c_red=''; c_grn=''; c_ylw=''; c_bold=''; fi

LOGFILE="${HOME}/hhd-verify-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee >(sed -u 's/\x1b\[[0-9;]*m//g' >> "$LOGFILE")) 2>&1

pass() { printf '%s[PASS]%s %s\n' "$c_grn" "$c_reset" "$*"; }
fail() { printf '%s[FAIL]%s %s\n' "$c_red" "$c_reset" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$c_ylw" "$c_reset" "$*"; }

[[ "$(id -u)" -eq 0 ]] && { fail "Run as your normal user, not root."; exit 1; }
REAL_USER="$(id -un)"
if [[ "$DEBUG" -eq 1 ]]; then export PS4='+ ${LINENO}: '; exec 9>>"$LOGFILE"; BASH_XTRACEFD=9; set -x; fi

printf '%sHHD health check (user: %s)%s\n' "$c_bold" "$REAL_USER" "$c_reset"
echo "kernel: $(uname -r)   log: $LOGFILE"
echo "------------------------------------------------------------"

# kernel
KVER="$(uname -r | grep -oE '^[0-9]+\.[0-9]+' || true)"; KMAJ="${KVER%%.*}"; KMIN="${KVER#*.}"
if [[ -n "$KVER" ]] && ! (( KMAJ < 6 || (KMAJ == 6 && KMIN < 19) )); then pass "Kernel >= 6.19 ($(uname -r))"; else warn "Kernel < 6.19 ($(uname -r)); TDP may be limited"; fi

# modules
lsmod | grep -q '^asus_wmi'     && pass "asus_wmi loaded"     || fail "asus_wmi not loaded"
lsmod | grep -q '^asus_armoury' && pass "asus_armoury loaded" || warn "asus_armoury not loaded"

# platform profile
if [[ -r /sys/firmware/acpi/platform_profile_choices ]]; then pass "platform_profile: $(cat /sys/firmware/acpi/platform_profile_choices)"; else fail "platform_profile_choices missing"; fi

# packages
for p in hhd adjustor hhd-ui; do
  if pacman -Qq "$p" &>/dev/null; then pass "$p installed ($(pacman -Q "$p" | awk '{print $2}'))"; else fail "$p NOT installed"; fi
done

# conflicts gone
[[ "$(systemctl is-active inputplumber 2>/dev/null || true)" == "active" ]] && fail "InputPlumber active (should be gone/masked)" || pass "InputPlumber not active"
[[ "$(systemctl is-active asusd 2>/dev/null || true)" == "active" ]] && warn "asusd active (conflicts with adjustor TDP)" || pass "asusd not active"

# hhd
[[ "$(systemctl is-active "hhd@${REAL_USER}" 2>/dev/null || true)" == "active" ]] && pass "hhd@${REAL_USER} active" || fail "hhd@${REAL_USER} not active"
# TDP backend present?
adj_log="$(sudo journalctl -u "hhd@${REAL_USER}" -b --no-pager 2>/dev/null | grep -iE 'adjustor|ADJA|thermal profile|setting tdp' | tail -3)"
if [[ -n "$adj_log" ]]; then
  pass "adjustor active in this boot's log"
elif lsmod | grep -q '^asus_armoury' && [[ -r /sys/firmware/acpi/platform_profile_choices ]]; then
  pass "TDP backend present (asus_armoury + platform_profile loaded)"
else
  warn "Could not confirm the TDP backend; open the HHD app and check the TDP section"
fi

# Ground-truth enforced limits, if the SMU reader is available (read-only).
if command -v ryzenadj >/dev/null 2>&1 && lsmod | grep -q '^ryzen_smu'; then
  echo "Enforced limits right now (ryzenadj):"
  sudo ryzenadj -i 2>/dev/null | grep -iE 'STAPM LIMIT|PPT LIMIT' | sed 's/^/  /' || echo "  (ryzenadj read failed)"
else
  echo "For authoritative limits, install the SMU reader once:"
  echo "    paru -S ryzen_smu-dkms && sudo modprobe ryzen_smu"
  echo "  then: sudo ryzenadj -i | grep -iE 'STAPM|PPT LIMIT'"
fi
echo
echo "How to confirm the slider actually works (two mechanisms):"
echo "  - PRESETS (silent/balanced/performance/turbo) set the ASUS thermal profile;"
echo "    the firmware applies that profile's limits. /sys/.../asus-nb-wmi/ppt_* does"
echo "    NOT change on presets, only in CUSTOM. Use 'ryzenadj -i' to see each preset's"
echo "    real limits, e.g. switch to turbo and watch STAPM LIMIT rise."
echo "  - CUSTOM writes explicit values to /sys/devices/platform/asus-nb-wmi/ppt_*,"
echo "    so those files change live as you drag the slider:"
echo "      watch -n1 'cat /sys/devices/platform/asus-nb-wmi/ppt_pl1_spl'"

# ---- controller / double-controller check (the Reddit case) ----
echo "------------------------------------------------------------"
echo "Controller devices seen by the kernel:"
grep -iE 'name=' /proc/bus/input/devices 2>/dev/null | grep -iE 'x-box|xbox|dualsense|handheld|rog ally config|microsoft' | sed 's/^/  /' || echo "  (none matched)"

if grep -qi 'Handheld Daemon Controller' /proc/bus/input/devices 2>/dev/null; then
  pass "HHD virtual controller present (HHD is emitting a controller)"
else
  warn "HHD virtual controller not present yet"
fi

echo
echo "${c_bold}MANUAL CHECK (this is what the Reddit reports were about):${c_reset}"
echo "  Open Steam > Settings > Controller. You should see ONE controller."
echo "  If you see TWO (the HHD-emulated one PLUS a separate 'ROG Ally'),"
echo "  the native HID driver is leaking a second pad and you have double input."
echo "  Fix only in that case:"
echo "    echo 'blacklist hid_asus_ally' | sudo tee /etc/modprobe.d/hhd-ally.conf"
echo "    echo 'blacklist hid_asus'      | sudo tee -a /etc/modprobe.d/hhd-ally.conf"
echo "    sudo mkinitcpio -P && sudo reboot"
echo "  Do NOT do this if Steam shows only one controller; it can break input."

# ---- pasteable report ----
echo "------------------------------------------------------------"
echo "----- BEGIN HHD DIAGNOSTICS -----"
echo "date:   $(date -Is)"
echo "os:     $(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}")"
echo "kernel: $(uname -r)"
lsmod | grep -iE 'hid_asus|asus_wmi|asus_armoury|xpad|inputplumber|platform_profile' || echo "(no matching modules)"
for p in hhd adjustor hhd-ui inputplumber asusctl rog-control-center; do
  pacman -Qq "$p" &>/dev/null && echo "$p $(pacman -Q "$p" | awk '{print $2}')" || echo "$p NOT installed"
done
echo "hhd@${REAL_USER}: $(systemctl is-active "hhd@${REAL_USER}" 2>/dev/null)"
grep -iE 'name=' /proc/bus/input/devices 2>/dev/null | grep -iE 'x-box|xbox|dualsense|handheld|rog|microsoft' || true
echo "----- END HHD DIAGNOSTICS -----"
echo
echo "Log saved to: $LOGFILE"
