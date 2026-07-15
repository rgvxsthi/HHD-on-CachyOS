#!/usr/bin/env bash
# Re-exec under bash if started with sh/dash.
if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi
#
# diag-dualsense.sh — read-only diagnostic for the HHD "emulated controller works
# in the HHD overlay but not in the system or games" problem (typically after
# switching emulation from Xbox to DualSense).
#
# Changes NOTHING. Only reads state and prints it. Safe to run and to share the
# output. Some checks use sudo for logs/udev; it will ask once.
#
#   bash diag-dualsense.sh
#   curl -fsSL <url>/diag-dualsense.sh | bash
#
# Redirect to a file to share:
#   bash diag-dualsense.sh 2>&1 | tee hhd-dualsense-diag.txt
#
set -uo pipefail

if [[ -t 1 ]]; then
  b=$'\033[1m'; g=$'\033[32m'; y=$'\033[33m'; r=$'\033[31m'; c=$'\033[36m'; z=$'\033[0m'
else
  b=""; g=""; y=""; r=""; c=""; z=""
fi
sec()  { printf '\n%s========== %s ==========%s\n' "$b" "$*" "$z"; }
ok()   { printf '  %s[+]%s %s\n' "$g" "$z" "$*"; }
no()   { printf '  %s[!]%s %s\n' "$y" "$z" "$*"; }
bad()  { printf '  %s[x]%s %s\n' "$r" "$z" "$*"; }
info() { printf '  %s[*]%s %s\n' "$c" "$z" "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

USER_NAME="${SUDO_USER:-$(id -un)}"
UNIT="hhd@${USER_NAME}"

sec "READ FIRST"
info "Switch HHD to DUALSENSE emulation BEFORE running this (open the HHD overlay,"
info "set the emulated controller to DualSense). In Xbox mode there is no DualSense"
info "node to inspect and sections 5/6 will show nothing useful."

sec "0. Environment"
info "user=${USER_NAME}  unit=${UNIT}"
info "kernel=$(uname -r)"
have hhd && info "hhd $(hhd --version 2>/dev/null || echo '?')" || bad "hhd binary not found in PATH"
if have pacman; then
  info "pkg hhd: $(pacman -Q hhd 2>/dev/null || echo 'not installed')"
fi

sec "1. HHD service"
if systemctl is-active --quiet "$UNIT"; then
  ok "${UNIT} is active (running)."
else
  bad "${UNIT} is NOT active — emulation can't work at all. Check: systemctl status ${UNIT}"
fi
info "State (enabled?): $(systemctl is-enabled "$UNIT" 2>/dev/null || echo '?')"

sec "2. Which controller mode is HHD configured for?"
# HHD stores runtime state under the user's config; grep for the emulation mode.
STATE=""
for f in "/home/${USER_NAME}/.config/hhd/state.yml" \
         "/home/${USER_NAME}/.local/state/hhd/state.yml" \
         "/root/.config/hhd/state.yml"; do
  [[ -r "$f" ]] && { STATE="$f"; break; }
done
if [[ -n "$STATE" ]]; then
  info "state file: $STATE"
  grep -inE 'mode|dualsense|xbox|controller|emulat' "$STATE" 2>/dev/null | sed 's/^/    /' | head -30 \
    || no "no controller/mode keys matched in state file"
else
  no "no readable HHD state.yml found (checked ~/.config, ~/.local/state, /root)."
  info "Open the HHD overlay and confirm the emulated controller = DualSense."
fi

sec "3. uinput module (needed to create the virtual pad)"
if lsmod 2>/dev/null | grep -q '^uinput'; then
  ok "uinput loaded."
else
  no "uinput not shown in lsmod (may be builtin). Check: modinfo uinput"
fi

sec "4. HHD udev rules present"
found_rule=0
for d in /usr/lib/udev/rules.d /etc/udev/rules.d /run/udev/rules.d; do
  for f in "$d"/*hhd*.rules; do
    [[ -e "$f" ]] && { ok "rule: $f"; found_rule=1; }
  done
done
[[ "$found_rule" -eq 0 ]] && no "no *hhd*.rules found — emulated nodes may lack user (uaccess) permission."

sec "5. Emulated gamepad — evdev nodes"
# Real DualSense / HHD's DS5 emulation shows as 'Sony ... DualSense' or 'Handheld Daemon'.
if [[ -d /dev/input/by-id ]]; then
  ls -l /dev/input/by-id/ 2>/dev/null | grep -iE 'sony|dualsense|dualshock|handheld|hhd|xbox|microsoft|gamepad' \
    | sed 's/^/    /' || no "no matching by-id symlinks"
fi
echo "  --- all event devices (name : handlers : perms) ---"
if have python3 && [[ -r /proc/bus/input/devices ]]; then
  # Print each input device's Name and its event/js handlers, then the node perms.
  python3 - <<'PY' 2>/dev/null || no "could not parse /proc/bus/input/devices"
import re, os, stat
blocks = open('/proc/bus/input/devices').read().split('\n\n')
for blk in blocks:
    name = re.search(r'N: Name="([^"]*)"', blk)
    hand = re.search(r'H: Handlers=(.*)', blk)
    if not name: continue
    n = name.group(1); h = hand.group(1).strip() if hand else ''
    nodes = [t for t in h.split() if t.startswith(('event','js'))]
    perms = []
    for nd in nodes:
        p = '/dev/input/'+nd
        try:
            st = os.stat(p); perms.append(f"{nd}={stat.filemode(st.st_mode)}")
        except OSError:
            perms.append(nd+"=?")
    print(f"    {n!r:40}  {' '.join(perms)}")
PY
else
  cat /proc/bus/input/devices 2>/dev/null | grep -E 'Name=|Handlers=' | sed 's/^/    /'
fi

sec "6. hidraw nodes (DualSense identity lives here — this is the usual culprit)"
shopt -s nullglob
hr=(/dev/hidraw*)
if [[ ${#hr[@]} -eq 0 ]]; then
  bad "no /dev/hidraw* nodes at all."
else
  for n in "${hr[@]}"; do
    # ACL matters: uaccess grants the logged-in user read even if group is root.
    perm="$(ls -l "$n" 2>/dev/null | awk '{print $1, $3, $4}')"
    acl=""
    have getfacl && acl="$(getfacl -p "$n" 2>/dev/null | grep -E "^user:${USER_NAME}:" | tr -d ' ' || true)"
    printf '    %s  [%s]  %s\n' "$n" "$perm" "${acl:-no-user-acl}"
  done
  info "If the DualSense hidraw shows owner root:root, mode crw------- AND no 'user:${USER_NAME}:...' ACL,"
  info "your session/games CANNOT read it — that's why only HHD sees it. (cause #1: udev/uaccess)"
fi
shopt -u nullglob

sec "7. Who is holding the hidraw nodes?"
if have fuser; then
  for n in /dev/hidraw*; do
    [[ -e "$n" ]] || continue
    holders="$(sudo fuser -v "$n" 2>&1 | tail -n +2 || true)"
    [[ -n "$holders" ]] && printf '    %s: %s\n' "$n" "$holders"
  done
else
  no "fuser not installed (skip). Install psmisc to see holders."
fi

sec "8. Steam Input (only relevant if it fails in Steam games but works on the desktop)"
if pgrep -x steam >/dev/null 2>&1; then
  info "Steam is running."
else
  info "Steam not running now."
fi
info "MANUAL CHECK: Steam -> Settings -> Controller -> 'PlayStation Configuration Support'."
info "  Disabled = Steam ignores the emulated DualSense. Toggle it and retest a game."

sec "9. Recent HHD log (last 25 lines)"
sudo journalctl -u "$UNIT" -b --no-pager 2>/dev/null | tail -25 | sed 's/^/    /' \
  || no "could not read journal (need sudo / adm group)."

sec "Summary — how to read this"
cat <<EOF
  Decide from section 5/6:
    * A DualSense evdev node exists but is NOT user-readable, or the hidraw in
      section 6 is root-only with no user ACL  -> CAUSE #1 (udev/uaccess).
      Try:  sudo udevadm control --reload-rules && sudo udevadm trigger
            sudo systemctl restart ${UNIT}   (then re-run this script)
      If still root-only, the HHD udev rules (section 4) are missing/not tagging
      the emulated node uaccess.
    * Node looks fine and readable, but games still don't see it -> restart HHD
      or REBOOT for a clean re-grab (CAUSE #2), then recheck.
    * Works on the desktop (evtest sees it) but only Steam games fail ->
      CAUSE #3, the Steam Input toggle in section 8.

  To capture input live (does the SYSTEM see the pad at all?):
      sudo evtest        # pick the DualSense/Handheld device, press buttons
EOF
echo
