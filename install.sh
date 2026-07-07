#!/usr/bin/env bash
# Re-exec under bash if started with sh/dash.
if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi
#
# install.sh - one-line bootstrap for HHD-on-CachyOS.
#
# Downloads the whole project (setup.sh, verify.sh, uninstall.sh AND the lib/
# folder they depend on) into a directory, then runs the action you asked for.
#
# Usage (pick one):
#   curl -fsSL https://raw.githubusercontent.com/rgvxsthi/HHD-on-CachyOS/main/install.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/rgvxsthi/HHD-on-CachyOS/main/install.sh | bash -s -- --steam-slider
#   curl -fsSL https://raw.githubusercontent.com/rgvxsthi/HHD-on-CachyOS/main/install.sh | bash -s -- verify
#   curl -fsSL https://raw.githubusercontent.com/rgvxsthi/HHD-on-CachyOS/main/install.sh | bash -s -- uninstall
#
# The first argument chooses the action (setup | verify | uninstall); anything
# else is passed through to that script. With no action, it runs setup.
#
# Environment overrides:
#   HHD_DIR   install location            (default: $HOME/HHD-on-CachyOS)
#   HHD_REF   git tag/branch to fetch      (default: latest release, else main)
#   HHD_REPO  owner/repo                    (default: rgvxsthi/HHD-on-CachyOS)
#   HHD_NO_RUN=1  download only, do not run anything

set -uo pipefail

REPO="${HHD_REPO:-rgvxsthi/HHD-on-CachyOS}"
DIR="${HHD_DIR:-$HOME/HHD-on-CachyOS}"

c_b=$'\e[1m'; c_y=$'\e[33m'; c_r=$'\e[31m'; c_g=$'\e[32m'; c_0=$'\e[0m'
say()  { printf '%s[hhd]%s %s\n' "$c_b" "$c_0" "$*"; }
warn() { printf '%s[hhd]%s %s\n' "$c_y" "$c_0" "$*"; }
die()  { printf '%s[hhd] error:%s %s\n' "$c_r" "$c_0" "$*" >&2; exit 1; }

[[ "$(id -u)" -eq 0 ]] && die "Run this as your normal user, not root (setup needs your username)."

# ---- pick the action ----
ACTION="setup"
case "${1:-}" in
  setup|verify|uninstall) ACTION="$1"; shift ;;
  ""|-*)                  ACTION="setup" ;;   # no arg, or a flag for setup
  *)                      die "unknown action '${1}' (use: setup | verify | uninstall)" ;;
esac
SCRIPT="${ACTION}.sh"

# ---- prerequisites ----
command -v tar >/dev/null 2>&1 || die "tar is required."
if command -v curl >/dev/null 2>&1; then DL=(curl -fsSL); DLO=(curl -fsSL -o)
elif command -v wget >/dev/null 2>&1; then DL=(wget -qO-);  DLO=(wget -qO)
else die "need curl or wget."; fi

# ---- resolve the ref: explicit HHD_REF, else latest release tag, else main ----
REF="${HHD_REF:-}"
if [[ -z "$REF" ]]; then
  # Capture the API response first, then parse (avoid curl SIGPIPE from `| grep -m1`).
  api="$("${DL[@]}" "https://api.github.com/repos/${REPO}/releases/latest" 2>/dev/null || true)"
  tag="$(printf '%s' "$api" | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')"
  if [[ -n "$tag" ]]; then REF="$tag"; else warn "no release found via API; falling back to main"; REF="main"; fi
fi
say "repo=${REPO} ref=${REF} dir=${DIR}"

# ---- download + extract the tarball (includes lib/) ----
TMP="$(mktemp -d)" || die "mktemp failed."
trap 'rm -rf "$TMP"' EXIT
TARBALL="https://codeload.github.com/${REPO}/tar.gz/${REF}"
say "downloading ${TARBALL} ..."
"${DLO[@]}" "$TMP/src.tar.gz" "$TARBALL" || die "download failed (ref '${REF}' not found?)."

mkdir -p "$DIR" || die "cannot create ${DIR}"
tar -xzf "$TMP/src.tar.gz" -C "$DIR" --strip-components=1 || die "extract failed."

[[ -r "$DIR/lib/device-profile.sh" ]] || die "lib/device-profile.sh missing after extract (bad tarball?)."
chmod +x "$DIR"/setup.sh "$DIR"/verify.sh "$DIR"/uninstall.sh 2>/dev/null || true
say "installed to ${DIR}"

# ---- run the chosen script ----
if [[ "${HHD_NO_RUN:-0}" == "1" ]]; then
  say "download only (HHD_NO_RUN=1). Run it yourself: cd ${DIR} && ./${SCRIPT}"
  exit 0
fi
[[ -x "$DIR/$SCRIPT" ]] || die "$SCRIPT not found in ${DIR}"
say "running ./${SCRIPT} $*"
cd "$DIR" || die "cannot cd ${DIR}"
exec ./"$SCRIPT" "$@"
