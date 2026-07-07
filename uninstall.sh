#!/usr/bin/env bash
# Re-exec under bash if started with sh/dash (script uses bash features).
if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi
#
# uninstall.sh - Reverse setup.sh: remove HHD and restore the pre-install state
#                on CachyOS. Auto-detects ASUS ROG Ally vs Lenovo Legion Go and
#                reverses exactly what setup.sh did for that device.
#
# It restores the machine to its PRE-SETUP state using the snapshot setup.sh
# writes before it changes anything (falling back to known CachyOS Handheld
# defaults if the snapshot is missing). In order it:
#   - disables and stops hhd@<user>
#   - removes steamos-manager-hhd-git (the slider) BEFORE hhd (it depends on hhd),
#     then removes hhd, adjustor, hhd-ui (+ device extras like acpi_call-dkms)
#   - unmasks + restores power-profiles-daemon / tuned to their prior state
#   - restores InputPlumber if it was installed before setup
#   - reinstalls stock steamos-manager if the slider replaced it (CachyOS default)
#   - reinstalls ONLY the vendor packages setup actually removed (never guesses)
#   - removes the hid_asus_ally blacklist (if present) + rebuilds initramfs
#   - (optionally) deletes the HHD user config and setup logs
#
# Refuses to run as root, asks before every destructive step, never reboots
# without asking. Runs under bash; re-execs itself if launched with sh.
#
# Usage:
#   ./uninstall.sh                interactive (recommended)
#   ./uninstall.sh --debug        verbose: trace every command to the log; also -d
#   ./uninstall.sh --yes          assume yes to prompts (still asks before reboot); also -y
#   ./uninstall.sh --no-restore   do NOT reinstall/unmask InputPlumber/PPD/vendor stack; just remove HHD
#   ./uninstall.sh --purge        also delete ~/.config/hhd and ~/hhd-setup-*.log
#   ./uninstall.sh --no-reboot    never prompt to reboot
#   ./uninstall.sh --help         this help; also -h
#
# Writes a full log to ~/hhd-uninstall-<timestamp>.log.

set -uo pipefail

# ---------- locate + source the device profile library ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -r "$SCRIPT_DIR/lib/device-profile.sh" ]]; then
  printf 'error: lib/device-profile.sh not found next to uninstall.sh\n' >&2
  exit 1
fi
# shellcheck source=lib/device-profile.sh
source "$SCRIPT_DIR/lib/device-profile.sh"

# ---------- args ----------
DEBUG=0; ASSUME_YES=0; REBOOT_PROMPT=1; RESTORE=1; PURGE=0
usage() {
  cat <<'EOH'
uninstall.sh - Reverse setup.sh: remove HHD and restore the pre-install state.

Auto-detects ASUS ROG Ally vs Lenovo Legion Go and reverses what setup.sh did.

Usage:
  ./uninstall.sh                interactive (recommended)
  ./uninstall.sh --debug        verbose: trace every command to the log; also -d
  ./uninstall.sh --yes          assume yes to prompts (still asks before reboot); also -y
  ./uninstall.sh --no-restore   do NOT reinstall/unmask InputPlumber/PPD/vendor stack; just remove HHD
  ./uninstall.sh --purge        also delete ~/.config/hhd and ~/hhd-setup-*.log
  ./uninstall.sh --no-reboot    never prompt to reboot
  ./uninstall.sh --help         this help; also -h

Writes a log to ~/hhd-uninstall-<timestamp>.log.
EOH
  exit 0
}
for arg in "$@"; do
  case "$arg" in
    -d|--debug|-debug)   DEBUG=1 ;;
    -y|--yes|-yes)       ASSUME_YES=1 ;;
    --no-restore)        RESTORE=0 ;;
    --purge)             PURGE=1 ;;
    --no-reboot)         REBOOT_PROMPT=0 ;;
    -h|--help|-help)     usage ;;
    *) printf 'unknown option: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

# ---------- colors ----------
if [ -t 1 ]; then
  c_reset=$'\e[0m'; c_red=$'\e[31m'; c_grn=$'\e[32m'; c_ylw=$'\e[33m'; c_blu=$'\e[34m'; c_bold=$'\e[1m'
else
  c_reset=''; c_red=''; c_grn=''; c_ylw=''; c_blu=''; c_bold=''
fi

# ---------- logging ----------
LOGFILE="${HOME}/hhd-uninstall-$(date +%Y%m%d-%H%M%S).log"
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
# svc_masked / svc_exists / detect_device come from lib/device-profile.sh

# ---------- debug trace ----------
if [[ "$DEBUG" -eq 1 ]]; then
  export PS4='+ ${BASH_SOURCE##*/}:${LINENO}: '
  exec 9>>"$LOGFILE"
  BASH_XTRACEFD=9
  set -x
fi

# ---------- banner ----------
step "HHD uninstall for CachyOS"
log "date:    $(date -Is)"
log "args:    debug=$DEBUG yes=$ASSUME_YES restore=$RESTORE purge=$PURGE reboot_prompt=$REBOOT_PROMPT"
log "logfile: $LOGFILE"

# ---------- 1. preconditions ----------
step "1. Preconditions"
if [[ "$(id -u)" -eq 0 ]]; then
  failr "Running as root. Re-run WITHOUT sudo; the hhd@<user> service is keyed to your username."
  exit 1
fi
REAL_USER="$(id -un)"
pass "Running as user: ${REAL_USER}"

if ! command -v pacman &>/dev/null; then
  failr "pacman not found. This targets CachyOS (Arch-based)."
  exit 1
fi

detect_device
pass "Device: ${DEVICE_LABEL} (profile=${DEVICE})"

# ---- load the pre-setup snapshot (written by setup.sh) for a faithful restore ----
# Defaults assume the CachyOS Handheld image shipped InputPlumber + stock
# steamos-manager (verified true), so with no snapshot we still restore those.
STATE_FILE="$(hhd_state_file)"
PRE_INPUTPLUMBER_INSTALLED=1; PRE_INPUTPLUMBER_ENABLED="enabled"
PRE_PPD_INSTALLED=1; PRE_PPD_ENABLED="enabled"
PRE_TUNED_INSTALLED=0; PRE_TUNED_ENABLED="unknown"
PRE_STEAMOS_STOCK_INSTALLED=1
PRE_VENDOR_REMOVED=""
PRE_SLIDER_INSTALLED=0
if [[ -r "$STATE_FILE" ]]; then
  # shellcheck source=/dev/null
  source "$STATE_FILE"
  pass "Loaded pre-setup snapshot ($STATE_FILE) — restoring exactly what was here"
  HAVE_STATE=1
else
  warnr "No pre-setup snapshot found; restoring known CachyOS Handheld defaults (InputPlumber + steamos-manager, no vendor stack)"
  HAVE_STATE=0
fi

info "This removes HHD and (unless --no-restore) unmasks PPD/InputPlumber and puts"
info "the vendor userspace stack back. It reverses what setup.sh did."
confirm "Proceed with uninstall?" || { info "Aborted."; exit 0; }

# ---------- 2. stop + disable hhd ----------
step "2. Stop and disable hhd@${REAL_USER}"
if [[ -n "$(systemctl is-enabled "hhd@${REAL_USER}" 2>/dev/null)$(systemctl is-active "hhd@${REAL_USER}" 2>/dev/null)" ]]; then
  sudo systemctl disable --now "hhd@${REAL_USER}" 2>/dev/null \
    && pass "hhd@${REAL_USER} disabled and stopped" \
    || warnr "Could not fully disable hhd@${REAL_USER} (may already be gone)"
else
  pass "hhd@${REAL_USER} not enabled/active"
fi

# ---------- 3. remove HHD stack (in dependency order) ----------
# IMPORTANT: steamos-manager-hhd-git depends on hhd>=4.1, so it MUST be removed
# BEFORE hhd or the hhd removal fails ("removing hhd breaks dependency ...").
step "3. Remove HHD stack"

# 3a. in-Steam slider first (it depends on hhd)
if pkg_installed "$STEAMOS_HHD_PKG"; then
  warn "${STEAMOS_HHD_PKG} installed (the in-Steam TDP slider; depends on hhd)."
  if confirm "Disable and remove ${STEAMOS_HHD_PKG}?"; then
    systemctl --user disable --now "$STEAMOS_HHD_USER_SVC" 2>/dev/null || true
    sudo systemctl disable --now "$STEAMOS_HHD_SYS_SVC" 2>/dev/null || true
    if pac -Rns "$STEAMOS_HHD_PKG"; then pass "${STEAMOS_HHD_PKG} removed"; else failr "Could not remove ${STEAMOS_HHD_PKG}"; fi
  else
    warnr "Kept ${STEAMOS_HHD_PKG} — this will BLOCK removing hhd (it depends on it)"
  fi
else
  pass "${STEAMOS_HHD_PKG} not installed"
fi

# 3b. hhd / adjustor / hhd-ui
HHD_PKGS=()
for p in hhd-ui adjustor hhd; do pkg_installed "$p" && HHD_PKGS+=("$p"); done
if (( ${#HHD_PKGS[@]} > 0 )); then
  warn "Installed: ${HHD_PKGS[*]}"
  if confirm "Remove these packages?"; then
    if pac -Rns "${HHD_PKGS[@]}"; then pass "HHD packages removed"; else failr "Could not remove HHD packages (a reverse dependency may still be installed)"; fi
  else
    warnr "Left HHD packages in place"
  fi
else
  pass "No HHD packages installed"
fi

# 3c. device extras (e.g. acpi_call-dkms). Ask separately — may be wanted elsewhere.
for p in "${EXTRA_PKGS[@]:-}"; do
  [[ -z "$p" ]] && continue
  if pkg_installed "$p"; then
    if confirm "Also remove device extra '$p' (installed for ${DEVICE} TDP)?"; then
      if pac -Rns "$p"; then pass "Removed $p"; else failr "Could not remove $p"; fi
    else
      info "Kept $p"
    fi
  fi
done

# ---------- 4. HHD user config ----------
step "4. HHD user config"
HHD_CFG="${HOME}/.config/hhd"
if [[ -e "$HHD_CFG" ]]; then
  if [[ "$PURGE" -eq 1 ]] || confirm "Delete HHD user config at ${HHD_CFG}? (your TDP/button profiles)"; then
    rm -rf "$HHD_CFG" && pass "Removed ${HHD_CFG}" || warnr "Could not remove ${HHD_CFG}"
  else
    info "Kept ${HHD_CFG}"
  fi
else
  pass "No HHD user config found"
fi

# ---------- 5. remove hid_asus_ally blacklist (README manual step, ASUS) ----------
step "5. Controller HID blacklist"
BLFILE="/etc/modprobe.d/hhd-ally.conf"
if [[ -e "$BLFILE" ]]; then
  warn "Found $BLFILE (the hid_asus_ally blacklist from the README)."
  if confirm "Remove it and rebuild initramfs so the native ASUS HID driver loads normally?"; then
    sudo rm -f "$BLFILE" && pass "Removed $BLFILE"
    if command -v mkinitcpio &>/dev/null; then
      sudo mkinitcpio -P && pass "initramfs rebuilt" || warnr "mkinitcpio failed; rebuild manually"
    elif command -v dracut &>/dev/null; then
      sudo dracut --force --regenerate-all && pass "initramfs rebuilt (dracut)" || warnr "dracut failed; rebuild manually"
    else
      warnr "No mkinitcpio/dracut found; rebuild your initramfs manually"
    fi
  else
    info "Kept $BLFILE"
  fi
else
  pass "No hid_asus_ally blacklist present"
fi

# svc_restore <unit> <was_enabled>: unmask, then bring back to its prior state.
# Many of these units (PPD, InputPlumber) are D-Bus/socket-activated with no
# [Install] section, so `enable` fails though they work — fall back to start.
svc_restore() {
  local svc="$1" was="$2" short="${1%.service}"
  svc_masked "$svc" && { sudo systemctl unmask "$svc" 2>/dev/null && pass "$short unmasked" || warnr "Could not unmask $short"; }
  # Clear any failed/start-limit state left from the teardown churn (e.g. PPD can
  # briefly fail to own its D-Bus name right after HHD's replacement is removed),
  # so we don't leave a unit stuck in 'failed (start-limit-hit)'.
  sudo systemctl reset-failed "$svc" 2>/dev/null || true
  case "$was" in
    disabled|masked|unknown|"")
      sudo systemctl start "$svc" 2>/dev/null && info "$short started (was not enabled; D-Bus/socket activated)" || info "$short left to D-Bus-activate on demand" ;;
    *)
      if sudo systemctl enable --now "$svc" 2>/dev/null; then pass "$short enabled + started"
      elif sudo systemctl start "$svc" 2>/dev/null; then pass "$short started (no [Install]; D-Bus activated)"
      else info "$short will D-Bus-activate on demand"; fi ;;
  esac
}

# ---------- 6. restore power-profiles-daemon / tuned ----------
step "6. Restore power-profiles-daemon / TuneD"
if [[ "$RESTORE" -eq 1 ]]; then
  [[ "$PRE_PPD_INSTALLED" -eq 1 ]] && svc_restore "$PPD_SVC" "$PRE_PPD_ENABLED" || { svc_masked "$PPD_SVC" && sudo systemctl unmask "$PPD_SVC" 2>/dev/null; pass "power-profiles-daemon: nothing to restore"; }
  if [[ "$PRE_TUNED_INSTALLED" -eq 1 ]]; then svc_restore "$TUNED_SVC" "$PRE_TUNED_ENABLED"; else
    svc_masked "$TUNED_SVC" && { sudo systemctl unmask "$TUNED_SVC" 2>/dev/null && pass "tuned unmasked"; } || pass "tuned: nothing to restore"
  fi
else
  info "--no-restore: leaving PPD/tuned masked as-is"
fi

# ---------- 7. restore InputPlumber ----------
step "7. InputPlumber"
svc_masked inputplumber && { sudo systemctl unmask inputplumber 2>/dev/null && pass "InputPlumber unmasked" || warnr "Could not unmask InputPlumber"; }
if [[ "$RESTORE" -eq 1 && "$PRE_INPUTPLUMBER_INSTALLED" -eq 1 ]]; then
  if pkg_installed inputplumber; then pass "InputPlumber already installed"
  elif pac -S --needed inputplumber; then pass "InputPlumber reinstalled"; else warnr "Could not reinstall InputPlumber"; fi
  pkg_installed inputplumber && svc_restore inputplumber "$PRE_INPUTPLUMBER_ENABLED"
elif [[ "$RESTORE" -eq 1 ]]; then
  info "InputPlumber was not installed before setup — leaving it out"
else
  info "--no-restore: leaving InputPlumber as-is"
fi

# ---------- 8. restore stock steamos-manager ----------
# The slider (steamos-manager-hhd-git) replaced stock steamos-manager, which
# CachyOS Handheld ships by default. Put stock back (it was removed in step 3).
step "8. Stock steamos-manager"
if [[ "$RESTORE" -eq 1 && "$PRE_STEAMOS_STOCK_INSTALLED" -eq 1 ]]; then
  if pkg_installed "$STEAMOS_STOCK_PKG"; then
    pass "${STEAMOS_STOCK_PKG} already installed"
  elif pac -S --needed "$STEAMOS_STOCK_PKG"; then
    pass "${STEAMOS_STOCK_PKG} reinstalled (CachyOS default)"
  else
    warnr "Could not reinstall ${STEAMOS_STOCK_PKG}"
  fi
  pkg_installed "$STEAMOS_STOCK_PKG" && svc_restore "$STEAMOS_STOCK_SVC" "enabled"
elif [[ "$RESTORE" -eq 1 ]]; then
  info "Stock steamos-manager was not present before setup — leaving it out"
else
  info "--no-restore: not restoring stock steamos-manager"
fi

# ---------- 9. restore vendor userspace stack (ONLY what setup removed) ----------
step "9. Vendor userspace stack"
if [[ "$RESTORE" -eq 1 && -n "${PRE_VENDOR_REMOVED// }" ]]; then
  read -ra VENDOR_LIST <<< "$PRE_VENDOR_REMOVED"
  MISSING=()
  for p in "${VENDOR_LIST[@]}"; do pkg_installed "$p" || MISSING+=("$p"); done
  if (( ${#MISSING[@]} > 0 )); then
    info "setup removed these; restoring: ${MISSING[*]}"
    if pac -S --needed "${MISSING[@]}"; then pass "Vendor stack restored"; else warnr "Could not restore (may be AUR: paru -S ...)"; fi
  else
    pass "Vendor stack already present"
  fi
  if [[ -n "$CONFLICT_SVC" ]] && pkg_installed "${VENDOR_LIST[0]}"; then
    sudo systemctl enable --now "$CONFLICT_SVC" 2>/dev/null && pass "${CONFLICT_SVC} enabled" || info "${CONFLICT_SVC} not enabled"
  fi
elif [[ "$RESTORE" -eq 1 ]]; then
  pass "No vendor packages were removed by setup — nothing to restore"
else
  info "--no-restore: not restoring the vendor userspace stack"
fi

# ---------- 9b. consume the pre-setup snapshot ----------
if [[ "$RESTORE" -eq 1 && -n "$STATE_FILE" && -e "$STATE_FILE" ]]; then
  rm -f "$STATE_FILE" 2>/dev/null && info "Removed the pre-setup snapshot (restore complete)"
fi

# ---------- 10. logs ----------
step "10. Setup logs"
if compgen -G "${HOME}/hhd-setup-*.log" >/dev/null; then
  if [[ "$PURGE" -eq 1 ]] || confirm "Delete old ~/hhd-setup-*.log files?"; then
    rm -f "${HOME}"/hhd-setup-*.log && pass "Removed setup logs" || warnr "Could not remove setup logs"
  else
    info "Kept setup logs"
  fi
else
  pass "No setup logs found"
fi

# ---------- 10. verify ----------
step "11. Verify"
pkg_installed hhd && failr "hhd still installed" || pass "hhd removed"
[[ "$(systemctl is-active "hhd@${REAL_USER}" 2>/dev/null || true)" == "active" ]] \
  && failr "hhd@${REAL_USER} still active" || pass "hhd@${REAL_USER} not active"
svc_masked inputplumber && warnr "InputPlumber still masked" || pass "InputPlumber not masked"
if [[ "$RESTORE" -eq 1 ]]; then
  svc_masked "$PPD_SVC" && warnr "power-profiles-daemon still masked" || pass "power-profiles-daemon not masked"
fi

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
- HHD is removed. If you restored InputPlumber/PPD, reboot for a clean handoff.
- If you removed the hid_asus_ally blacklist, a reboot is required for the native
  ASUS HID driver to load again.
EONOTE
echo
if [[ "$REBOOT_PROMPT" -eq 1 ]]; then
  if confirm "Reboot now?"; then sudo reboot; else info "Reboot yourself when ready: sudo reboot"; fi
else
  info "Skipping reboot prompt (--no-reboot). Reboot before using: sudo reboot"
fi
