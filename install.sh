#!/bin/sh
# commander-installer — single-shot install of commander-worker on a fresh
# Ubuntu 24.04 LTS box.
#
#     curl -fsSL https://raw.githubusercontent.com/dekimuhq/commander-installer/main/install.sh | sudo sh
#
# Audit before piping. This script is intentionally short, POSIX-shell only,
# idempotent, and contains zero secrets. Source: github.com/dekimuhq/commander-installer
#
# What it does:
#   1. Checks Ubuntu 24.04 + root.
#   2. Installs Node.js 22 from NodeSource (if missing).
#   3. Creates a dedicated `commander` system user (no shell login).
#   4. Fetches a pinned commander-worker tarball from the public Vercel
#      Blob mirror, verifies its sha256, extracts to /home/commander/worker.
#   5. Drops a /etc/commander-worker/env skeleton (placeholders only).
#   6. Installs a systemd unit `commander-worker.service`. Does NOT start it.
#   7. Prints a "next steps" block: fill envs, then `systemctl start`.
#
# Re-running this script is safe: every step no-ops if already done.

set -eu

WORKER_VERSION="v0.1.0"
WORKER_REPO="dekimuhq/commander-worker"
WORKER_USER="commander"
WORKER_HOME="/home/${WORKER_USER}"
WORKER_DIR="${WORKER_HOME}/worker"
ENV_DIR="/etc/commander-worker"
ENV_FILE="${ENV_DIR}/env"
LICENSE_DIR="/etc/commander"
SYSTEMD_UNIT="/etc/systemd/system/commander-worker.service"
WORKER_PORT="7891"
PROJECTS_ROOT="/var/commander/projects"
RUNS_ROOT="/var/commander/runs"

say() { printf '[install] %s\n' "$*"; }
warn() { printf '[install] WARN: %s\n' "$*" >&2; }
die() { printf '[install] ERROR: %s\n' "$*" >&2; exit 1; }

# ---- 1. pre-flight ----------------------------------------------------------

[ "$(id -u)" -eq 0 ] || die "must run as root (try: sudo sh install.sh)"

if [ ! -r /etc/os-release ]; then
  die "cannot read /etc/os-release — unsupported host"
fi
. /etc/os-release
case "${ID:-}:${VERSION_ID:-}" in
  ubuntu:24.04) : ;;
  *) die "unsupported host: ${PRETTY_NAME:-unknown}. v1 supports Ubuntu 24.04 LTS only (Debian 12 + 22.04 in v1.1)." ;;
esac
say "host check ok: ${PRETTY_NAME}"

if [ -d "${WORKER_HOME}" ] && [ -n "$(ls -A "${WORKER_HOME}" 2>/dev/null || true)" ]; then
  warn "${WORKER_HOME} already exists with content — re-run will overwrite worker files but preserve the home dir"
fi

# port-in-use pre-flight (warn only — abort lands in W4)
if command -v ss >/dev/null 2>&1; then
  if ss -ltn "sport = :${WORKER_PORT}" 2>/dev/null | grep -q LISTEN; then
    warn "port ${WORKER_PORT} is already LISTEN-ing — installer will still place the unit, but the service will fail to bind on start"
  fi
fi

# ---- 2. node 22 -------------------------------------------------------------

NODE_OK=0
if command -v node >/dev/null 2>&1; then
  NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
  if [ "${NODE_MAJOR}" -ge 22 ] 2>/dev/null; then
    NODE_OK=1
    say "node $(node -v) already installed"
  fi
fi
if [ "${NODE_OK}" -eq 0 ]; then
  say "installing node 22 from NodeSource"
  apt-get update -qq
  apt-get install -y -qq curl ca-certificates gnupg
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
    | gpg --dearmor --yes -o /etc/apt/keyrings/nodesource.gpg
  chmod 644 /etc/apt/keyrings/nodesource.gpg
  echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main" \
    > /etc/apt/sources.list.d/nodesource.list
  apt-get update -qq
  apt-get install -y -qq nodejs
  say "node $(node -v) installed"
fi

# ---- 3. commander user ------------------------------------------------------

if id -u "${WORKER_USER}" >/dev/null 2>&1; then
  say "user ${WORKER_USER} already exists"
else
  say "creating system user ${WORKER_USER}"
  useradd --system --create-home --home-dir "${WORKER_HOME}" --shell /usr/sbin/nologin "${WORKER_USER}"
fi

# ---- 4. directories ---------------------------------------------------------

install -d -m 0755 -o "${WORKER_USER}" -g "${WORKER_USER}" "${WORKER_DIR}"
install -d -m 0755 -o "${WORKER_USER}" -g "${WORKER_USER}" "${PROJECTS_ROOT}"
install -d -m 0755 -o "${WORKER_USER}" -g "${WORKER_USER}" "${RUNS_ROOT}"
install -d -m 0750 -o "${WORKER_USER}" -g "${WORKER_USER}" "${LICENSE_DIR}"
install -d -m 0750 -o root            -g "${WORKER_USER}" "${ENV_DIR}"

# ---- 5. fetch + verify worker tarball --------------------------------------

VERSION_NUM="${WORKER_VERSION#v}"
TARBALL="commander-worker-${VERSION_NUM}.tar.gz"
BLOB_HOST="https://c9myjual9hsi50ix.public.blob.vercel-storage.com"
TARBALL_URL="${BLOB_HOST}/commander-worker/${WORKER_VERSION}/${TARBALL}"
SHA_URL="${TARBALL_URL}.sha256"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TMPDIR}"' EXIT
say "fetching ${WORKER_VERSION} from public Blob mirror"
curl -fsSL --retry 3 --retry-delay 2 -o "${TMPDIR}/${TARBALL}" "${TARBALL_URL}" \
  || die "could not download ${TARBALL_URL}"
curl -fsSL --retry 3 --retry-delay 2 -o "${TMPDIR}/${TARBALL}.sha256" "${SHA_URL}" \
  || die "could not download ${SHA_URL}"

say "verifying sha256"
( cd "${TMPDIR}" && sha256sum -c "${TARBALL}.sha256" >/dev/null ) \
  || die "sha256 mismatch on ${TARBALL} — refusing to install"

say "extracting to ${WORKER_DIR}"
STAGE="${TMPDIR}/extract"
mkdir -p "${STAGE}"
tar -C "${STAGE}" -xzf "${TMPDIR}/${TARBALL}"
SRC_DIR="${STAGE}/commander-worker-${VERSION_NUM}"
[ -d "${SRC_DIR}" ] || die "tarball layout unexpected (no commander-worker-${VERSION_NUM}/ root)"

# Replace dist + node_modules + package*.json atomically.
rm -rf "${WORKER_DIR}/dist" "${WORKER_DIR}/node_modules"
cp -r "${SRC_DIR}/dist"          "${WORKER_DIR}/dist"
cp -r "${SRC_DIR}/node_modules"  "${WORKER_DIR}/node_modules"
cp    "${SRC_DIR}/package.json"  "${WORKER_DIR}/package.json"
cp    "${SRC_DIR}/package-lock.json" "${WORKER_DIR}/package-lock.json" 2>/dev/null || true
chown -R "${WORKER_USER}:${WORKER_USER}" "${WORKER_DIR}"

echo "${WORKER_VERSION}" > "${WORKER_DIR}/.installed-version"
chown "${WORKER_USER}:${WORKER_USER}" "${WORKER_DIR}/.installed-version"

# ---- 6. env skeleton --------------------------------------------------------

if [ ! -f "${ENV_FILE}" ]; then
  say "writing ${ENV_FILE} skeleton (placeholders only — no secrets baked in)"
  cat > "${ENV_FILE}" <<'ENV_EOF'
# commander-worker — production env file
# Loaded by systemd via EnvironmentFile=. Mode 0640 root:commander.
#
# Fill these in, then: sudo systemctl restart commander-worker
# Tail logs:           journalctl -u commander-worker -f
#
# REQUIRED (every install)
COMMANDER_MODE=product
WORKER_SECRET=__FILL_WITH__openssl_rand_-base64_32
UPSTASH_REDIS_REST_URL=__FILL__
UPSTASH_REDIS_REST_TOKEN=__FILL__

# REQUIRED (product mode license client)
COMMANDER_LICENSE_PUBLIC_KEY=__FILL_with_PEM_from_runcommander.com__
LICENSE_SERVER_URL=https://runcommander.com

# REQUIRED for AI runs (at least one provider)
# ANTHROPIC_API_KEY=
# OPENAI_API_KEY=
# GOOGLE_API_KEY=

# OPTIONAL — overrides
PORT=7891
HOST=127.0.0.1
COMMANDER_PROJECTS_ROOT=/var/commander/projects
DISABLE_TELEMETRY=1
DISABLE_ERROR_REPORTING=1
DISABLE_NON_ESSENTIAL_MODEL_CALLS=1
ENV_EOF
  chmod 0640 "${ENV_FILE}"
  chown root:"${WORKER_USER}" "${ENV_FILE}"
else
  say "${ENV_FILE} already present — leaving in place"
fi

# ---- 7. systemd unit --------------------------------------------------------

NEW_UNIT="$(mktemp)"
cat > "${NEW_UNIT}" <<UNIT_EOF
[Unit]
Description=Commander worker (Hono + Claude Agent SDK)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${WORKER_USER}
Group=${WORKER_USER}
WorkingDirectory=${WORKER_DIR}
EnvironmentFile=${ENV_FILE}
ExecStart=/usr/bin/node ${WORKER_DIR}/dist/server.js
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

# Hardening
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=${WORKER_HOME} ${LICENSE_DIR} ${PROJECTS_ROOT} ${RUNS_ROOT}
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictNamespaces=true
LockPersonality=true
RestrictRealtime=true

[Install]
WantedBy=multi-user.target
UNIT_EOF

if [ -f "${SYSTEMD_UNIT}" ] && cmp -s "${NEW_UNIT}" "${SYSTEMD_UNIT}"; then
  say "systemd unit unchanged"
  rm -f "${NEW_UNIT}"
else
  say "installing systemd unit ${SYSTEMD_UNIT}"
  install -m 0644 "${NEW_UNIT}" "${SYSTEMD_UNIT}"
  rm -f "${NEW_UNIT}"
  systemctl daemon-reload
fi

systemctl enable commander-worker.service >/dev/null 2>&1 || true

# ---- 8. next steps ---------------------------------------------------------

cat <<NEXT_EOF
[install] -----------------------------------------------------------
[install] commander-worker ${WORKER_VERSION} installed.
[install]
[install] Next steps (operator):
[install]   1. Edit ${ENV_FILE} and fill the __FILL__ placeholders.
[install]      Generate a worker secret:  openssl rand -base64 32
[install]   2. Start the service:
[install]        sudo systemctl start commander-worker
[install]   3. Confirm health (loopback, requires WORKER_SECRET):
[install]        curl -sSf -H "Authorization: Bearer \$WORKER_SECRET" \\
[install]          http://127.0.0.1:${WORKER_PORT}/health
[install]      Expected: {"ok":true,...}
[install]   4. Tail logs:
[install]        journalctl -u commander-worker -f
[install]
[install] Audit this script: https://github.com/dekimuhq/commander-installer
[install] -----------------------------------------------------------
NEXT_EOF
