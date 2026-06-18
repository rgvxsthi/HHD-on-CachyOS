#!/usr/bin/env bash
#
# setup.sh - Install and configure Handheld Daemon (HHD) on CachyOS for the ASUS ROG Ally.
#
# Tested on: CachyOS Handheld Edition, ASUS ROG Ally Z1 Extreme, kernel 6.19+.
# Everything else is unverified. See README.md.
#
# What it does, in order:
#   1. Refuses to run as root (the hhd@<user> unit needs your real username).
#   2. Checks you are on an Arch/pacman system and warns if not CachyOS.
#   3. Checks the kernel is 6.19+ and that the ASUS TDP backend is exposed.
#   4. Removes InputPlumber (stop + mask + remove) so it stops fighting HHD.
#   5. Removes the ASUS userspace stack (asusctl / rog-control-center) if present.
#   6. Installs hhd, adjustor, hhd-ui.
#   7. Enables and starts hhd@<user>.
#   8. Verifies the daemon and the adjustor TDP backend.
#   9. Prompts you to reboot.
#
# Usage:
#   ./setup.sh        interactive (recommended)
#   ./setup.sh -y     assume yes to all prompts (still won't reboot without asking)
#   ./setup.sh -h     help

set -euo pipefail

ASSUME_YES=0

# ---------- pretty output ----------
c_reset=$'\e[0m'; c_red=$'\e[31m'; c_grn=$'\e[32m'; c_ylw=$'\e[33m'; c_blu=$'\e[34m'; c_bold=$'\e[1m'
info() { printf '%s[*]%s %s\n' "$c_blu" "$c_reset" "$*"; }
ok()   { printf '%s[ok]%s %s\n' "$c_grn" "$c_reset" "$*"; }
warn() { printf '%s[!]%s %s\n' "$c_ylw" "$c_reset" "$*"; }
err()  { printf '%s[x]%s %s\n' "$c_red" "$c_reset" "$*" >&2; }
hr()   { printf '%s\n' "------------------------------------------------------------"; }

confirm() {
  # confirm "question" -> returns 0 for yes
  local q="$1"
  if [[ "$ASSUME_YES" -eq 1 ]]; then return 0; fi
  local ans
  read -r -p "$(printf '%s[?]%s %s [y/N] ' "$c_ylw" "$c_reset" "$q")" ans
  [[ "$ans" =~ ^[Yy]$ ]]
}

pkg_installed() { pacman -Qq "$1" &>/dev/null; }

usage() {
  sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//; s/^#//' | head -n 30
  exit 0
}

while getopts ":yh" opt; do
  case "$opt" in
    y) ASSUME_YES=1 ;;
    h) usage ;;
    *) err "unknown option"; exit 2 ;;
  esac
done

hr
printf '%sHHD setup for CachyOS / ROG Ally%s\n' "$c_bold" "$c_reset"
hr

# ---------- 1. not as root ----------
if [[ "$(id -u)" -eq 0 ]]; then
  err "Run this as your normal user, not root. The hhd@<user> service needs your username."
  err "If you used sudo, run it again without sudo. The script will call sudo itself where needed."
  exit 1
fi
REAL_USER="$(id -un)"
info "Configuring for user: ${c_bold}${REAL_USER}${c_reset}"

# ---------- 2. pacman / CachyOS check ----------
if ! command -v pacman &>/dev/null; then
  err "pacman not found. This script targets CachyOS (Arch-based). Aborting."
  exit 1
fi
if [[ -r /etc/os-release ]] && ! grep -qi cachyos /etc/os-release; then
  warn "This does not look like CachyOS. The script may still work on Arch, but it is untested there."
  confirm "Continue anyway?" || { info "Aborted."; exit 0; }
fi

# ---------- 3. kernel + TDP backend ----------
hr
info "Checking kernel and ASUS TDP backend..."
KREL="$(uname -r)"
KVER="$(printf '%s' "$KREL" | grep -oE '^[0-9]+\.[0-9]+' || true)"
KMAJ="${KVER%%.*}"; KMIN="${KVER#*.}"
info "Kernel: $KREL"
if [[ -z "$KVER" ]] || (( KMAJ < 6 || (KMAJ == 6 && KMIN < 19) )); then
  warn "Kernel is older than 6.19. The asus-armoury TDP driver is mainline from 6.19."
  warn "On an older kernel the TDP section may not appear."
  if confirm "Run a full system update now (pacman -Syu)? You will then need to reboot and re-run this script."; then
    sudo pacman -Syu
    ok "Update done. Reboot, then run ./setup.sh again."
    exit 0
  fi
  confirm "Continue without updating (TDP may not work)?" || { info "Aborted."; exit 0; }
else
  ok "Kernel 6.19+ detected."
fi

if lsmod | grep -q '^asus_wmi'; then
  ok "asus_wmi module loaded."
else
  warn "asus_wmi not loaded. Trying to load it..."
  sudo modprobe asus_wmi 2>/dev/null || warn "Could not load asus_wmi. TDP may not work."
fi

if [[ -r /sys/firmware/acpi/platform_profile_choices ]]; then
  ok "Platform profile interface present: $(cat /sys/firmware/acpi/platform_profile_choices)"
else
  warn "/sys/firmware/acpi/platform_profile_choices is missing."
  warn "The ASUS power interface is not exposed. Installing HHD will not fix this; it is a kernel issue."
  confirm "Continue anyway?" || { info "Aborted."; exit 0; }
fi

# ---------- 4. InputPlumber ----------
hr
if pkg_installed inputplumber; then
  warn "InputPlumber is installed. It fights HHD over the controller and the ASUS button device."
  if confirm "Stop, mask, and remove InputPlumber?"; then
    sudo systemctl mask --now inputplumber || true
    if [[ "$ASSUME_YES" -eq 1 ]]; then
      sudo pacman -R --noconfirm inputplumber
    else
      sudo pacman -R inputplumber
    fi
    ok "InputPlumber removed and masked."
  else
    warn "Leaving InputPlumber in place. HHD button remapping will likely not work."
  fi
else
  ok "InputPlumber not installed."
fi

# ---------- 5. ASUS userspace stack ----------
hr
ASUS_PKGS=()
for p in asusctl rog-control-center supergfxctl; do
  if pkg_installed "$p"; then ASUS_PKGS+=("$p"); fi
done
if (( ${#ASUS_PKGS[@]} > 0 )); then
  warn "Found ASUS userspace stack: ${ASUS_PKGS[*]}. This conflicts with adjustor over the platform profile."
  if confirm "Disable asusd and remove these packages?"; then
    sudo systemctl disable --now asusd 2>/dev/null || true
    if [[ "$ASSUME_YES" -eq 1 ]]; then
      sudo pacman -R --noconfirm "${ASUS_PKGS[@]}"
    else
      sudo pacman -R "${ASUS_PKGS[@]}"
    fi
    ok "ASUS userspace stack removed."
  else
    warn "Leaving the ASUS stack in place. It may fight adjustor for TDP control."
  fi
else
  ok "No conflicting ASUS userspace stack found."
fi

# ---------- 6. install HHD ----------
hr
info "Installing hhd, adjustor, hhd-ui..."
PAC_ARGS=(-S --needed)
[[ "$ASSUME_YES" -eq 1 ]] && PAC_ARGS+=(--noconfirm)
if ! sudo pacman "${PAC_ARGS[@]}" hhd adjustor hhd-ui; then
  err "pacman could not install one or more packages."
  err "If they are not in your repos, install with an AUR helper, e.g.: paru -S hhd adjustor hhd-ui"
  exit 1
fi
ok "Packages installed."

# ---------- 7. version sanity ----------
hver="$(pacman -Q hhd | awk '{print $2}')"
aver="$(pacman -Q adjustor | awk '{print $2}')"
hmaj="${hver%%.*}"; amaj="${aver%%.*}"
info "hhd ${hver}, adjustor ${aver}"
if [[ "$hmaj" != "$amaj" ]]; then
  warn "hhd and adjustor major versions differ (${hmaj} vs ${amaj}). The daemon may skip the plugin."
  warn "Consider updating both: sudo pacman -Syu"
else
  ok "hhd and adjustor major versions match."
fi

# ---------- 8. enable + start ----------
hr
info "Enabling and starting hhd@${REAL_USER}..."
sudo systemctl enable --now "hhd@${REAL_USER}"
sleep 4

# ---------- 9. verify ----------
hr
info "Verifying..."
if [[ "$(systemctl is-active inputplumber 2>/dev/null || true)" == "active" ]]; then
  warn "InputPlumber is active again. Something reactivated it. Re-run and remove it."
else
  ok "InputPlumber is not active."
fi

if [[ "$(systemctl is-active "hhd@${REAL_USER}" 2>/dev/null || true)" == "active" ]]; then
  ok "hhd@${REAL_USER} is active."
else
  err "hhd@${REAL_USER} is not active. Check: systemctl status hhd@${REAL_USER}"
fi

if sudo journalctl -u "hhd@${REAL_USER}" -b --no-pager 2>/dev/null | grep -qi 'adjustor_asus'; then
  ok "adjustor ASUS backend loaded. TDP control should be present."
else
  warn "Did not see adjustor_asus in the log yet. Give it a moment, then check:"
  warn "  sudo journalctl -u hhd@${REAL_USER} -b --no-pager | grep -iE 'adjustor|asus|profile'"
fi

# ---------- 10. reboot ----------
hr
ok "Setup finished."
echo
echo "Next:"
echo "  - Desktop mode: open the 'Handheld Daemon' app to set TDP, fans, RGB, buttons."
echo "  - Game Mode: double-tap the small menu button to open the overlay."
echo "  - Overlay errors in the desktop-session journal are normal; the overlay only renders in gamescope."
echo
if confirm "Reboot now for a clean input handoff?"; then
  sudo reboot
else
  info "Reboot yourself when ready: sudo reboot"
fi
