#!/usr/bin/env bash
#
# fix-hhd.sh — repair a Handheld Daemon install that stopped starting after a
# CachyOS update. Targets the known breakage:
#
#   hhd@<user>.service crash-loops with:
#     ModuleNotFoundError: No module named 'pkg_resources'
#
# Cause: hhd's entrypoint does `import pkg_resources`, which ships inside
# python-setuptools. setuptools >= 83 REMOVED pkg_resources, so once a
# `pacman -Syu` pulls setuptools 83 the daemon exits 1 on every start and
# never activates. This script restores a setuptools that still provides
# pkg_resources (downgraded from the pacman cache), restarts hhd, and offers
# to hold setuptools so the next update doesn't re-break it.
#
# It does NOT reinstall hhd or touch your config. Safe to re-run.
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

step "Handheld Daemon repair (pkg_resources / setuptools)"
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

# ---------- 2. restore pkg_resources from the pacman cache ----------
step "2. Restore pkg_resources (downgrade python-setuptools from cache)"
cur="$(pacman -Q python-setuptools 2>/dev/null | awk '{print $2}')"
fixed=0
shopt -s nullglob
cands=(/var/cache/pacman/pkg/python-setuptools-*.pkg.tar.zst)
shopt -u nullglob
# highest version first, skip the current (broken) one
if (( ${#cands[@]} > 0 )); then
  IFS=$'\n' read -r -d '' -a cands < <(printf '%s\n' "${cands[@]}" | sort -rV && printf '\0')
fi
for cand in "${cands[@]}"; do
  [[ -n "$cur" && "$cand" == *"$cur"* ]] && continue
  info "Trying cached $(basename "$cand")"
  if ${SUDO} pacman -U --noconfirm "$cand" && python -c 'import pkg_resources' 2>/dev/null; then
    fixed=1; break
  fi
done

if (( ! fixed )); then
  err "Could not restore pkg_resources from the pacman cache."
  err "No cached python-setuptools below the broken one was found."
  err "Manual options:"
  err "  1) Grab an older python-setuptools (< 83) and: sudo pacman -U <file>"
  err "  2) Wait for an hhd update that drops the pkg_resources import."
  exit 1
fi
ok "pkg_resources restored (python-setuptools now $(pacman -Q python-setuptools | awk '{print $2}'))"

# ---------- 3. restart the daemon ----------
step "3. Restart ${UNIT}"
${SUDO} systemctl reset-failed "$UNIT" 2>/dev/null || true
${SUDO} systemctl enable --now "$UNIT" 2>/dev/null || ${SUDO} systemctl restart "$UNIT" 2>/dev/null || true
info "Waiting 4s for the daemon to settle..."
sleep 4
if systemctl is-active --quiet "$UNIT"; then
  ok "${UNIT} is active (running). hhd is fixed."
else
  warn "${UNIT} is still not active. Current status:"
  systemctl status "$UNIT" --no-pager 2>&1 | head -15 || true
  warn "The setuptools fix applied, but something else is wrong — check the log above."
fi

# ---------- 4. keep it fixed across the next update ----------
step "4. Prevent re-breakage on the next 'pacman -Syu'"
warn "The next full update will re-upgrade python-setuptools and re-break hhd,"
warn "until hhd upstream stops importing pkg_resources (or setuptools re-adds it)."
if grep -qE '^\s*IgnorePkg\s*=.*python-setuptools' /etc/pacman.conf 2>/dev/null; then
  ok "python-setuptools is already held (IgnorePkg in /etc/pacman.conf)."
else
  info "To hold setuptools at the working version, add it to IgnorePkg."
  do_hold=0
  if [[ -t 0 ]]; then
    read -r -p "$(printf '%s[?]%s Add python-setuptools to IgnorePkg now? [y/N] ' "$c_ylw" "$c_reset")" ans
    [[ "$ans" =~ ^[Yy]$ ]] && do_hold=1
  else
    warn "Running non-interactively — not editing pacman.conf automatically."
    warn "To hold it yourself: add 'IgnorePkg = python-setuptools' under [options] in /etc/pacman.conf"
  fi
  if (( do_hold )); then
    if ${SUDO} sed -i 's/^\[options\]/[options]\nIgnorePkg = python-setuptools/' /etc/pacman.conf; then
      ok "Held python-setuptools. Remove that line from /etc/pacman.conf once hhd is fixed upstream."
    else
      err "Could not edit /etc/pacman.conf — add 'IgnorePkg = python-setuptools' under [options] manually."
    fi
  fi
fi

step "Done"
ok "If hhd is active above, you're good. Reboot if you want a clean input handoff."
