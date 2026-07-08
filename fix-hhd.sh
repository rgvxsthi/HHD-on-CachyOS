#!/usr/bin/env bash
#
# fix-hhd.sh — repair a Handheld Daemon install that stopped starting after a
# CachyOS update. Targets the known breakage:
#
#   hhd@<user>.service crash-loops with:
#     ModuleNotFoundError: No module named 'pkg_resources'
#
# Cause: hhd's entrypoint uses `pkg_resources` (from python-setuptools) to
# discover its plugins. setuptools >= 81 REMOVED pkg_resources, so once a
# CachyOS `pacman -Syu` pulls a newer setuptools the module is gone and the
# daemon exits 1 on every start and never activates. (Downgrading setuptools
# does NOT help: the current packages don't ship pkg_resources at all.)
#
# Fix: install a tiny `pkg_resources` compatibility shim that provides just the
# bit hhd needs (`iter_entry_points`), backed by the standard-library
# `importlib.metadata`. This is upstream-safe, survives hhd reinstalls/updates,
# and needs no setuptools downgrade or package hold. Remove it once hhd stops
# importing pkg_resources (see uninstall.sh, or delete the shim dir).
#
# Does NOT reinstall hhd or touch your config. Safe to re-run.
#
#   bash fix-hhd.sh
#   curl -fsSL https://raw.githubusercontent.com/rgvxsthi/HHD-on-CachyOS/main/fix-hhd.sh | bash
#
set -uo pipefail

# ---------- pretty output ----------
if [[ -t 1 ]]; then
  c_grn=$'\033[32m'; c_ylw=$'\033[33m'; c_red=$'\033[31m'; c_blu=$'\033[34m'
  c_bold=$'\033[1m'; c_reset=$'\033[0m'
else
  c_grn=""; c_ylw=""; c_red=""; c_blu=""; c_bold=""; c_reset=""
fi
ts()   { date '+%H:%M:%S'; }
info() { printf '%s %s[*]%s %s\n' "$(ts)" "$c_blu" "$c_reset" "$*"; }
ok()   { printf '%s %s[+]%s %s\n' "$(ts)" "$c_grn" "$c_reset" "$*"; }
warn() { printf '%s %s[!]%s %s\n' "$(ts)" "$c_ylw" "$c_reset" "$*"; }
err()  { printf '%s %s[x]%s %s\n' "$(ts)" "$c_red" "$c_reset" "$*"; }
step() { printf '\n%s========== %s ==========%s\n' "$c_bold" "$*" "$c_reset"; }

SUDO="sudo"

# ---------- who runs hhd ----------
REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || id -un)}"
[[ -z "$REAL_USER" || "$REAL_USER" == "root" ]] && REAL_USER="$(id -un)"
UNIT="hhd@${REAL_USER}"

step "Handheld Daemon repair (pkg_resources / importlib.metadata shim)"
info "Target service: ${UNIT}"

# ---------- 0. sanity: is hhd even installed? ----------
if ! pacman -Qq hhd &>/dev/null; then
  err "hhd is not installed. This script only repairs a broken hhd, it does not install it."
  err "Run the full installer instead: setup.sh"
  exit 1
fi
info "hhd $(pacman -Q hhd | awk '{print $2}'), python-setuptools $(pacman -Q python-setuptools 2>/dev/null | awk '{print $2}' || echo '(not installed)')"

# ---------- 1. is this actually the pkg_resources breakage? ----------
step "1. Diagnose"
if python -c 'import pkg_resources' 2>/dev/null; then
  ok "pkg_resources already imports — this is NOT the setuptools breakage."
  if systemctl is-active --quiet "$UNIT"; then
    ok "${UNIT} is active. Nothing to repair."
    exit 0
  fi
  warn "${UNIT} is not active, but pkg_resources is fine — different problem."
  warn "Most recent daemon log:"
  ${SUDO} journalctl -u "$UNIT" -b --no-pager 2>/dev/null | tail -20 || true
  warn "Try: sudo systemctl restart ${UNIT}   (and report the log above if it persists)"
  exit 1
fi
warn "pkg_resources is missing — confirmed setuptools breakage (hhd will crash-loop)."

# ---------- 2. install the pkg_resources compatibility shim ----------
step "2. Install pkg_resources shim (backed by importlib.metadata)"
PURELIB="$(python -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])' 2>/dev/null)"
if [[ -z "$PURELIB" || ! -d "$PURELIB" ]]; then
  err "Could not locate the python site-packages directory."
  exit 1
fi
SHIM_DIR="$PURELIB/pkg_resources"
info "Site-packages: $PURELIB"

# Refuse to clobber a real pkg_resources (older machines may still have one).
if [[ -e "$SHIM_DIR/__init__.py" ]] && ! grep -q 'HHD-on-CachyOS' "$SHIM_DIR/__init__.py" 2>/dev/null; then
  err "A pkg_resources already exists at $SHIM_DIR and is not our shim — not touching it."
  exit 1
fi

read -r -d '' SHIM <<'PYEOF' || true
# pkg_resources compatibility shim installed by HHD-on-CachyOS (fix-hhd.sh).
# setuptools >= 81 removed pkg_resources, but hhd still imports it for plugin
# discovery. This provides only the small subset hhd uses (iter_entry_points),
# backed by the standard-library importlib.metadata. Safe to delete once hhd no
# longer imports pkg_resources.
from importlib.metadata import entry_points as _entry_points


class _EntryPoint:
    def __init__(self, ep):
        self._ep = ep
        self.name = ep.name

    def resolve(self):
        return self._ep.load()

    def load(self, *args, **kwargs):
        return self._ep.load()


def iter_entry_points(group, name=None):
    for ep in _entry_points(group=group):
        if name is None or ep.name == name:
            yield _EntryPoint(ep)
PYEOF

${SUDO} install -d "$SHIM_DIR" || { err "Could not create $SHIM_DIR"; exit 1; }
if printf '%s\n' "$SHIM" | ${SUDO} tee "$SHIM_DIR/__init__.py" >/dev/null; then
  ${SUDO} python -c "import compileall, sys; compileall.compile_dir('$SHIM_DIR', quiet=1)" 2>/dev/null || true
  if python -c 'import pkg_resources; next(iter(pkg_resources.iter_entry_points("hhd.plugins")), None)' 2>/dev/null; then
    ok "pkg_resources shim installed and imports cleanly."
  else
    err "Shim written but 'import pkg_resources' still fails — aborting."
    exit 1
  fi
else
  err "Could not write the shim to $SHIM_DIR."
  exit 1
fi

# ---------- 3. restart the daemon ----------
step "3. Restart ${UNIT}"
${SUDO} systemctl reset-failed "$UNIT" 2>/dev/null || true
${SUDO} systemctl enable --now "$UNIT" 2>/dev/null || ${SUDO} systemctl restart "$UNIT" 2>/dev/null || true
info "Waiting 5s for the daemon to settle..."
sleep 5
if systemctl is-active --quiet "$UNIT"; then
  ok "${UNIT} is active (running). hhd is fixed."
else
  warn "${UNIT} is not active yet. Current status:"
  systemctl status "$UNIT" --no-pager 2>&1 | head -15 || true
  warn "If it is stuck on 'Trying to acquire hhd lock', a stale hhd process may hold the lock:"
  warn "  sudo systemctl stop ${UNIT}; sudo pkill -9 -f '[p]ython /usr/bin/hhd'; sudo systemctl start ${UNIT}"
fi

step "Done"
ok "If hhd is active above, you're good. Reboot if you want a clean input handoff."
info "The shim stays in place across updates. Remove it (or run uninstall.sh) once hhd"
info "ships a version that no longer imports pkg_resources."
