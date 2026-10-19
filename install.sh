#!/usr/bin/env bash
# commander-installer — audited bootstrap for the Commander worker
# (https://runcommander.com). Source: https://github.com/dekimuhq/commander-installer
#
# What it does, in order:
#   1. Downloads the current worker release from runcommander.com/releases:
#        commander-worker.tar.gz, commander-worker.tar.gz.sha256, install.sh
#   2. Verifies the tarball against the published sha256 — missing or
#      mismatching checksum = stop. Nothing is installed.
#   3. Checks the archive layout: flat entries only, no absolute paths, no
#      "..", and the two files the worker installer needs must be present.
#   4. Prints the sha256 of the downloaded install.sh.
#   5. --verify-only stops here (no root needed). Otherwise, as root, it runs
#      that install.sh with the verified tarball. Everything that touches the
#      system happens in that script — read it; README.md lists its steps.
#
# This script itself: creates a temp dir, downloads three files, reads them.
# It installs nothing, writes nothing outside its work dir, and needs no root.
#
# Usage:
#   curl -fsSLO https://raw.githubusercontent.com/dekimuhq/commander-installer/main/install.sh
#   bash install.sh --verify-only          # download + verify into ./commander-release, read it
#   sudo bash install.sh                   # verify again, then run the worker installer
#
# Options:
#   --verify-only          download, verify, list — exit 0 on success, never needs root
#   --workdir DIR          keep downloads in DIR (default: a temp dir, deleted on exit;
#                          --verify-only defaults to ./commander-release and keeps it)
#   --release-base URL     release directory (default: https://runcommander.com/releases)
#
# Do not pipe this script into sh: the worker's setup wizard reads your keys
# from the terminal, and a pipe is not a terminal.

set -euo pipefail

RELEASE_BASE="https://runcommander.com/releases"
TARBALL="commander-worker.tar.gz"
SUMFILE="${TARBALL}.sha256"
WORKER_INSTALLER="install.sh"
VERIFY_ONLY=0
WORKDIR=""

say() { printf '[bootstrap] %s\n' "$*"; }
die() { printf '[bootstrap] ERROR: %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --verify-only) VERIFY_ONLY=1 ;;
    --workdir) [[ -n "${2:-}" ]] || die "--workdir needs a directory"; WORKDIR="$2"; shift ;;
    --release-base) [[ -n "${2:-}" ]] || die "--release-base needs a URL"; RELEASE_BASE="${2%/}"; shift ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
  shift
done

for tool in curl sha256sum tar; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool is required"
done

# ── 1. work dir + download ───────────────────────────────────────────────────
KEEP_WORKDIR=1
if [[ -z "$WORKDIR" ]]; then
  if [[ $VERIFY_ONLY -eq 1 ]]; then
    WORKDIR="./commander-release"
  else
    WORKDIR="$(mktemp -d)"
    KEEP_WORKDIR=0
  fi
fi
mkdir -p "$WORKDIR"
WORKDIR="$(cd "$WORKDIR" && pwd)"
if [[ $KEEP_WORKDIR -eq 0 ]]; then
  trap 'rm -f "$WORKDIR/$TARBALL" "$WORKDIR/$SUMFILE" "$WORKDIR/$WORKER_INSTALLER"; rmdir "$WORKDIR" 2>/dev/null || true' EXIT
fi

fetch() {
  # $1 = file name under RELEASE_BASE. -f turns a 404 into a non-zero exit.
  curl -fsSL --retry 3 --retry-delay 2 -o "$WORKDIR/$1" "$RELEASE_BASE/$1"
}

say "release: $RELEASE_BASE"
fetch "$TARBALL" || die "could not download $RELEASE_BASE/$TARBALL"
fetch "$SUMFILE" || die "no checksum published at $RELEASE_BASE/$SUMFILE — refusing to install an unverifiable tarball"
fetch "$WORKER_INSTALLER" || die "could not download $RELEASE_BASE/$WORKER_INSTALLER"

# ── 2. checksum ──────────────────────────────────────────────────────────────
# Expected format: "<64 hex>  commander-worker.tar.gz" (what `sha256sum` emits),
# so a stray HTML page or a hash for a different file name is rejected before
# sha256sum -c gets to read it.
if ! grep -Eqx "[0-9a-f]{64}  $TARBALL" "$WORKDIR/$SUMFILE"; then
  die "$SUMFILE is not a sha256sum line for $TARBALL — refusing to install"
fi
( cd "$WORKDIR" && sha256sum -c --status "$SUMFILE" ) \
  || die "sha256 mismatch on $TARBALL — refusing to install"
say "sha256 OK: $(cut -d' ' -f1 "$WORKDIR/$SUMFILE")"

# ── 3. archive layout ────────────────────────────────────────────────────────
# The release is flat: ./server.mjs, ./commander-worker.service, optionally
# ./commander-license.pub. Anything nested, absolute, or climbing out is
# rejected because the worker installer extracts straight into /opt.
LISTING="$(tar -tzf "$WORKDIR/$TARBALL")"
while IFS= read -r entry; do
  [[ "$entry" == "./" ]] && continue
  [[ "$entry" =~ ^\./[^/]+$ ]] || die "unexpected archive entry '$entry' — refusing to install"
  [[ "$entry" == *..* ]] && die "unexpected archive entry '$entry' — refusing to install"
done <<< "$LISTING"
for required in ./server.mjs ./commander-worker.service; do
  grep -qx "$required" <<< "$LISTING" || die "archive is missing $required — wrong tarball?"
done
say "archive layout OK:"
while IFS= read -r entry; do printf '             %s\n' "$entry"; done <<< "$LISTING"

# ── 4. the worker installer ──────────────────────────────────────────────────
# There is no published hash for install.sh; it comes over HTTPS from the same
# origin as the release. Its hash is printed so you can compare it across
# downloads and machines, and read the file before it runs as root.
say "worker installer sha256: $(sha256sum "$WORKDIR/$WORKER_INSTALLER" | cut -d' ' -f1) ($(wc -c < "$WORKDIR/$WORKER_INSTALLER") bytes)"

if [[ $VERIFY_ONLY -eq 1 ]]; then
  say "verify-only: nothing installed. Files kept in $WORKDIR"
  say "read $WORKDIR/$WORKER_INSTALLER, then: sudo bash $0 --workdir $WORKDIR"
  exit 0
fi

# ── 5. hand off (root from here) ─────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "root is needed from here: sudo bash $0 (or --verify-only to stop before this point)"
[[ -t 0 ]] || die "stdin is not a terminal — the setup wizard needs one; download this script and run it, do not pipe it"

say "handing off to the worker installer with the verified tarball"
bash "$WORKDIR/$WORKER_INSTALLER" "$WORKDIR/$TARBALL"
