#!/usr/bin/env bash
#
# verify.sh - Read-only health check for HHD on CachyOS / ROG Ally.
# Changes nothing. Run it after a reboot to confirm the stack is healthy.
#
# Usage: ./verify.sh

set -uo pipefail

c_reset=$'\e[0m'; c_red=$'\e[31m'; c_grn=$'\e[32m'; c_ylw=$'\e[33m'; c_bold=$'\e[1m'
pass() { printf '%s[PASS]%s %s\n' "$c_grn" "$c_reset" "$*"; }
fail() { printf '%s[FAIL]%s %s\n' "$c_red" "$c_reset" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$c_ylw" "$c_reset" "$*"; }

REAL_USER="$(id -un)"
[[ "$(id -u)" -eq 0 ]] && { fail "Run as your normal user, not root."; exit 1; }

printf '%sHHD health check (user: %s)%s\n' "$c_bold" "$REAL_USER" "$c_reset"
echo "------------------------------------------------------------"

# kernel
KREL="$(uname -r)"
KVER="$(printf '%s' "$KREL" | grep -oE '^[0-9]+\.[0-9]+' || true)"
KMAJ="${KVER%%.*}"; KMIN="${KVER#*.}"
if [[ -n "$KVER" ]] && ! (( KMAJ < 6 || (KMAJ == 6 && KMIN < 19) )); then
  pass "Kernel $KREL (6.19+)"
else
  warn "Kernel $KREL is older than 6.19. TDP may be limited or absent."
fi

# asus_wmi
if lsmod | grep -q '^asus_wmi'; then pass "asus_wmi loaded"; else fail "asus_wmi not loaded"; fi

# platform profile
if [[ -r /sys/firmware/acpi/platform_profile_choices ]]; then
  pass "platform_profile_choices: $(cat /sys/firmware/acpi/platform_profile_choices)"
else
  fail "platform_profile_choices missing (ASUS power interface not exposed)"
fi

# packages
for p in hhd adjustor hhd-ui; do
  if pacman -Qq "$p" &>/dev/null; then pass "$p installed ($(pacman -Q "$p" | awk '{print $2}'))"; else fail "$p NOT installed"; fi
done

# inputplumber should be gone/inactive
ip_state="$(systemctl is-active inputplumber 2>/dev/null || true)"
if [[ "$ip_state" == "active" ]]; then fail "InputPlumber is active (should be removed/masked)"; else pass "InputPlumber not active ($ip_state)"; fi

# hhd active
hhd_state="$(systemctl is-active "hhd@${REAL_USER}" 2>/dev/null || true)"
if [[ "$hhd_state" == "active" ]]; then pass "hhd@${REAL_USER} active"; else fail "hhd@${REAL_USER} not active ($hhd_state)"; fi

# adjustor backend in journal
if sudo journalctl -u "hhd@${REAL_USER}" -b --no-pager 2>/dev/null | grep -qi 'adjustor_asus'; then
  pass "adjustor ASUS backend loaded (TDP control present)"
else
  warn "adjustor_asus not seen in this boot's log. Check the daemon log."
fi

echo "------------------------------------------------------------"
echo "Desktop mode: configure in the 'Handheld Daemon' app."
echo "Game Mode: double-tap the small menu button for the overlay."
