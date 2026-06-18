#!/usr/bin/env bash
# Re-exec under bash if started with sh/dash (script uses bash features).
if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi
#
# setup.sh - Install and configure Handheld Daemon (HHD) on CachyOS for the ASUS ROG Ally.
#
# Tested on: CachyOS Handheld Edition, ASUS ROG Ally Z1 Extreme, kernel 6.19+ / 7.0.x.
# Everything else is unverified. See README.md.
#
# Usage:
#   ./setup.sh                 interactive (recommended)
#   ./setup.sh --debug         verbose: trace every command (also: -debug, -d)
#   ./setup.sh --yes           assume yes to prompts (still asks before reboot); also -y
#   ./setup.sh --no-reboot     never prompt to reboot
#   ./setup.sh --help          this help; also -h
#
# Every run writes a full log to ~/hhd-setup-<timestamp>.log and prints a
# diagnostic report at the end you can paste into a GitHub issue or Reddit.

set -uo pipefail

# ---------- args ----------
DEBUG=0; ASSUME_YES=0; REBOOT_PROMPT=1
usage() {
  cat <<'EOH'
setup.sh - Install and configure Handheld Daemon (HHD) on CachyOS for the ASUS ROG Ally.

Tested on: CachyOS Handheld Edition, ASUS ROG Ally Z1 Extreme, kernel 6.19+ / 7.0.x.

Usage:
  ./setup.sh                 interactive (recommended)
  ./setup.sh --debug         verbose: trace every command (also -debug, -d)
  ./setup.sh --yes           assume yes to prompts (still asks before reboot); also -y
  ./setup.sh --no-reboot     never prompt to reboot
  ./setup.sh --help          this help; also -h

Writes a full log to ~/hhd-setup-<timestamp>.log and prints a diagnostic
report at the end you can paste into a GitHub issue or Reddit.
EOH
  exit 0
}
for arg in "$@"; do
  case "$arg" in
    -d|--debug|-debug)   DEBUG=1 ;;
    -y|--yes|-yes)       ASSUME_YES=1 ;;
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

# ---------- debug trace ----------
# In debug mode, send the command trace to the LOG FILE only (fd 9), not the
# console. The console keeps the clean step output; the log has the full trace.
if [[ "$DEBUG" -eq 1 ]]; then
  export PS4='+ ${BASH_SOURCE##*/}:${LINENO}: '
  exec 9>>"$LOGFILE"
  BASH_XTRACEFD=9
  set -x
fi

# ---------- banner ----------
step "HHD setup for CachyOS / ROG Ally"
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

# ---------- 2. kernel + TDP backend ----------
step "2. Kernel and ASUS TDP backend"
KREL="$(uname -r)"; log "kernel: $KREL"
KVER="$(printf '%s' "$KREL" | grep -oE '^[0-9]+\.[0-9]+' || true)"
KMAJ="${KVER%%.*}"; KMIN="${KVER#*.}"
if [[ -n "$KVER" ]] && ! (( KMAJ < 6 || (KMAJ == 6 && KMIN < 19) )); then
  pass "Kernel $KREL (>= 6.19, asus-armoury available)"
else
  warnr "Kernel $KREL is older than 6.19; TDP section may not appear."
  if confirm "Run full update now (pacman -Syu)? You will reboot and re-run after."; then
    sudo pacman -Syu
    ok "Update done. Reboot, then run ./setup.sh again."
    exit 0
  fi
  confirm "Continue without updating?" || { info "Aborted."; exit 0; }
fi

if lsmod | grep -q '^asus_wmi'; then pass "asus_wmi loaded"; else
  warn "asus_wmi not loaded; trying modprobe..."
  sudo modprobe asus_wmi 2>/dev/null && pass "asus_wmi loaded" || warnr "Could not load asus_wmi"
fi
if lsmod | grep -q '^asus_armoury'; then pass "asus_armoury loaded (modern TDP path)"; else
  warn "asus_armoury not loaded; trying modprobe..."
  if sudo modprobe asus_armoury 2>/dev/null && lsmod | grep -q '^asus_armoury'; then
    pass "asus_armoury loaded (modern TDP path)"
  else
    warnr "asus_armoury not loaded yet; it usually loads after the reboot at the end of this script"
  fi
fi
if [[ -r /sys/firmware/acpi/platform_profile_choices ]]; then
  pass "platform_profile_choices: $(cat /sys/firmware/acpi/platform_profile_choices)"
else
  failr "platform_profile_choices missing (ASUS power interface not exposed)"
  confirm "Continue anyway? HHD will not be able to control TDP." || { info "Aborted."; exit 0; }
fi

# ---------- 3. InputPlumber ----------
step "3. Remove InputPlumber"
if pkg_installed inputplumber; then
  warn "InputPlumber installed; it fights HHD over the controller."
  if confirm "Stop, mask, and remove InputPlumber?"; then
    sudo systemctl mask --now inputplumber || true
    if [[ "$ASSUME_YES" -eq 1 ]]; then sudo pacman -R --noconfirm inputplumber; else sudo pacman -R inputplumber; fi
    pass "InputPlumber removed and masked"
  else
    warnr "InputPlumber left in place; HHD button remapping will likely fail"
  fi
else
  pass "InputPlumber not installed"
fi

# ---------- 4. ASUS userspace stack ----------
step "4. Remove conflicting ASUS userspace stack"
ASUS_PKGS=()
for p in asusctl rog-control-center supergfxctl; do pkg_installed "$p" && ASUS_PKGS+=("$p"); done
if (( ${#ASUS_PKGS[@]} > 0 )); then
  warn "Found: ${ASUS_PKGS[*]} (fights adjustor over the platform profile)"
  if confirm "Disable asusd and remove these?"; then
    sudo systemctl disable --now asusd 2>/dev/null || true
    if [[ "$ASSUME_YES" -eq 1 ]]; then sudo pacman -R --noconfirm "${ASUS_PKGS[@]}"; else sudo pacman -R "${ASUS_PKGS[@]}"; fi
    pass "ASUS userspace stack removed"
  else
    warnr "ASUS stack left in place; it may fight adjustor for TDP"
  fi
else
  pass "No conflicting ASUS userspace stack found"
fi

# ---------- 5. install HHD ----------
step "5. Install hhd, adjustor, hhd-ui"
PAC_ARGS=(-S --needed); [[ "$ASSUME_YES" -eq 1 ]] && PAC_ARGS+=(--noconfirm)
if sudo pacman "${PAC_ARGS[@]}" hhd adjustor hhd-ui; then
  pass "Packages installed"
else
  failr "pacman could not install one or more packages"
  err "If not in your repos, use an AUR helper: paru -S hhd adjustor hhd-ui"
  exit 1
fi

# ---------- 6. version sanity ----------
step "6. Version check"
hver="$(pacman -Q hhd | awk '{print $2}')"; aver="$(pacman -Q adjustor | awk '{print $2}')"
log "hhd=$hver adjustor=$aver hhd-ui=$(pacman -Q hhd-ui | awk '{print $2}')"
if [[ "${hver%%.*}" == "${aver%%.*}" ]]; then pass "hhd and adjustor major versions match (${hver%%.*}.x)"; else
  warnr "hhd/adjustor major versions differ (${hver%%.*} vs ${aver%%.*}); daemon may skip the plugin"
fi

# ---------- 7. enable + start ----------
step "7. Enable and start hhd@${REAL_USER}"
sudo systemctl enable --now "hhd@${REAL_USER}"
info "Waiting 5s for the daemon to initialize..."
sleep 5

# ---------- 8. verify ----------
step "8. Verify"
[[ "$(systemctl is-active inputplumber 2>/dev/null || true)" == "active" ]] \
  && failr "InputPlumber active again (something reactivated it)" \
  || pass "InputPlumber not active"

[[ "$(systemctl is-active "hhd@${REAL_USER}" 2>/dev/null || true)" == "active" ]] \
  && pass "hhd@${REAL_USER} active" \
  || failr "hhd@${REAL_USER} not active (see: systemctl status hhd@${REAL_USER})"

if sudo journalctl -u "hhd@${REAL_USER}" -b --no-pager 2>/dev/null | grep -qi 'adjustor_asus'; then
  pass "adjustor ASUS backend loaded (TDP control present)"
else
  warnr "adjustor_asus not seen yet; check the journal in a moment"
fi

if grep -qi 'Handheld Daemon Controller' /proc/bus/input/devices 2>/dev/null; then
  pass "HHD virtual controller present"
else
  warnr "HHD virtual controller not seen yet (often appears after reboot)"
fi

# ---------- 9. diagnostics ----------
diagnostics() {
  set +e
  step "DIAGNOSTIC REPORT (copy from BEGIN to END)"
  echo "----- BEGIN HHD DIAGNOSTICS -----"
  echo "date:   $(date -Is)"
  echo "user:   $(id -un)"
  echo "os:     $(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}")"
  echo "kernel: $(uname -r)"
  echo
  echo "## modules"
  lsmod | grep -iE 'hid_asus|asus_wmi|asus_armoury|asus_nb_wmi|xpad|inputplumber|platform_profile' || echo "(none matched)"
  echo
  echo "## platform profile"
  echo "choices: $(cat /sys/firmware/acpi/platform_profile_choices 2>/dev/null || echo missing)"
  echo "current: $(cat /sys/firmware/acpi/platform_profile 2>/dev/null || echo missing)"
  echo
  echo "## packages"
  for p in hhd adjustor hhd-ui inputplumber asusctl rog-control-center supergfxctl; do
    if pacman -Qq "$p" &>/dev/null; then echo "$p $(pacman -Q "$p" | awk '{print $2}')"; else echo "$p NOT installed"; fi
  done
  echo
  echo "## services"
  for s in "hhd@$(id -un)" inputplumber asusd; do
    echo "$s: active=$(systemctl is-active "$s" 2>/dev/null) enabled=$(systemctl is-enabled "$s" 2>/dev/null)"
  done
  echo
  echo "## hhd journal (filtered, last 40)"
  sudo journalctl -u "hhd@$(id -un)" -b --no-pager 2>/dev/null | grep -iE 'adjustor|asus|tdp|profile|error|overlay' | tail -40 || echo "(none)"
  echo
  echo "## input devices (controllers)"
  grep -iE 'name=' /proc/bus/input/devices 2>/dev/null | grep -iE 'asus|x-box|xbox|dualsense|microsoft|handheld|rog|sony' || echo "(none matched)"
  echo "----- END HHD DIAGNOSTICS -----"
  set -u
}
diagnostics

# ---------- 10. summary ----------
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

# ---------- 11. reboot ----------
step "Next steps"
cat <<EONOTE
- Desktop mode: open the "Handheld Daemon" app to set TDP, fans, RGB, buttons.
- Game Mode: double-tap the small menu button for the overlay.
- After reboot, run ./verify.sh to confirm the live state and check for a
  double controller (the hid_asus_ally blacklist case).
EONOTE
echo
if [[ "$REBOOT_PROMPT" -eq 1 ]]; then
  if confirm "Reboot now for a clean input handoff?"; then sudo reboot; else info "Reboot yourself when ready: sudo reboot"; fi
else
  info "Skipping reboot prompt (--no-reboot). Reboot before using: sudo reboot"
fi
