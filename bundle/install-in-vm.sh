#!/usr/bin/env bash
set -Eeuo pipefail

# OpenCast/RelayWave single-node test installer.
# Intended for a fresh Debian 13/Ubuntu VM created by the PVE1 launcher.

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "Run as root (or with sudo)." >&2
  exit 1
fi

BUNDLE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -f "$BUNDLE_ROOT/app/server.mjs" ]]; then
  echo "Could not find bundled application next to this installer." >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

need_pkg=()
for spec in \
  "podman:podman" \
  "git:git" \
  "curl:curl" \
  "jq:jq" \
  "age:age" \
  "rsync:rsync" \
  "unzip:unzip" \
  "python3:python3" \
  "openssl:openssl" \
  "node:nodejs"; do
  cmd=${spec%%:*}; pkg=${spec##*:}
  command -v "$cmd" >/dev/null 2>&1 || need_pkg+=("$pkg")
done

# Always make sure these base packages are present. qemu-guest-agent is used by
# the PVE host installer to discover the final LAN IP and installation status.
need_pkg+=(ca-certificates qemu-guest-agent sudo openssh-server)

# De-duplicate package names.
mapfile -t need_pkg < <(printf '%s\n' "${need_pkg[@]}" | awk '!seen[$0]++')
if ((${#need_pkg[@]})); then
  echo "Installing required packages: ${need_pkg[*]}"
  apt-get update
  apt-get install -y --no-install-recommends "${need_pkg[@]}"
fi

if ! command -v podman >/dev/null 2>&1; then
  echo "Podman installation failed or Podman is unavailable." >&2
  exit 1
fi

echo "Podman: $(podman --version)"
systemctl enable --now qemu-guest-agent >/dev/null 2>&1 || true

INSTALL_ROOT=/opt/opencast-test
mkdir -p "$INSTALL_ROOT"/{app,config,scripts,data/app,data/blossom,data/relay,data/cache,vendor}
chown 101:101 "$INSTALL_ROOT/data/cache" 2>/dev/null || chmod 0777 "$INSTALL_ROOT/data/cache"
rsync -a --delete "$BUNDLE_ROOT/app/" "$INSTALL_ROOT/app/"
rsync -a "$BUNDLE_ROOT/stack/config/" "$INSTALL_ROOT/config/"
rsync -a "$BUNDLE_ROOT/stack/scripts/" "$INSTALL_ROOT/scripts/"
chmod +x "$INSTALL_ROOT/scripts/"*.sh
# Render the upload allowlist (kept in config/uploaders.txt) into blossom.yml.
RELAYWAVE_ROOT="$INSTALL_ROOT" "$INSTALL_ROOT/scripts/uploaders.sh" sync

# Build Blossom from one reviewed commit, not whatever the default branch holds
# today. Bump this deliberately after reading the upstream changes.
BLOSSOM_COMMIT=2b096da56e9ee5bf3d19c586e9d60b475c38fd11
BLOSSOM_DIR="$INSTALL_ROOT/vendor/blossom-server"
if [[ ! -d "$BLOSSOM_DIR/.git" ]]; then
  echo "Fetching Blossom test origin at $BLOSSOM_COMMIT..."
  git init -q "$BLOSSOM_DIR"
  git -C "$BLOSSOM_DIR" remote add origin https://github.com/hzrd149/blossom-server.git
fi
if [[ "$(git -C "$BLOSSOM_DIR" rev-parse HEAD 2>/dev/null || true)" != "$BLOSSOM_COMMIT" ]]; then
  git -C "$BLOSSOM_DIR" fetch -q --depth 1 origin "$BLOSSOM_COMMIT"
  git -C "$BLOSSOM_DIR" -c advice.detachedHead=false checkout -q FETCH_HEAD
  [[ "$(git -C "$BLOSSOM_DIR" rev-parse HEAD)" == "$BLOSSOM_COMMIT" ]] || { echo "Blossom checkout does not match the pinned commit." >&2; exit 1; }
fi

AUTO_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')"
if [[ -z "$AUTO_IP" ]]; then
  AUTO_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
fi

LAN_IP="${OPENCAST_LAN_IP:-$AUTO_IP}"
if [[ "${OPENCAST_NONINTERACTIVE:-0}" != "1" ]]; then
  read -r -p "LAN IP clients should use [$LAN_IP]: " ANSWER
  LAN_IP=${ANSWER:-$LAN_IP}
fi
if [[ -z "$LAN_IP" ]]; then
  echo "Could not determine a LAN IP." >&2
  exit 1
fi

# The test signer's key is generated here, per install. It used to be derived
# from a fixed string in the source, so anyone could compute it.
DEMO_SECRET="$(sed -n 's/^DEMO_SECRET=//p' /etc/opencast-test.env 2>/dev/null | head -n 1 || true)"
[[ "$DEMO_SECRET" =~ ^[0-9a-f]{64}$ ]] || DEMO_SECRET="$(openssl rand -hex 32)"
umask 077
cat > /etc/opencast-test.env <<ENV
LAN_IP=$LAN_IP
DEMO_SECRET=$DEMO_SECRET
PUBLIC_BASE_URL=http://$LAN_IP:8080
DEFAULT_BLOSSOM=http://$LAN_IP:8081
DEFAULT_RELAYS=ws://$LAN_IP:7447
TEST_MODE=1
ANALYTICS_TRUST_PROXY=0
ANALYTICS_K=5
ENV
chmod 0600 /etc/opencast-test.env
umask 022

# Diagnostic logs stay in volatile /run storage. The nginx edge separately has
# access_log off, so listener/request history is not written to disk.
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/opencast-volatile.conf <<'JOURNAL'
[Journal]
Storage=volatile
RuntimeMaxUse=64M
RuntimeMaxFileSize=8M
MaxRetentionSec=6h
ForwardToSyslog=no
JOURNAL
systemctl restart systemd-journald || true

install -m 0644 "$BUNDLE_ROOT/stack/systemd/opencast-test.service" /etc/systemd/system/opencast-test.service
systemctl daemon-reload
systemctl enable opencast-test.service >/dev/null
systemctl restart opencast-test.service

# Save the migration-audit utilities in a predictable location too.
mkdir -p "$INSTALL_ROOT/tools"
rsync -a "$BUNDLE_ROOT/tools/" "$INSTALL_ROOT/tools/"
chmod +x "$INSTALL_ROOT/tools/"*.sh 2>/dev/null || true

sleep 4
"$INSTALL_ROOT/scripts/status.sh" || true

touch /var/lib/opencast-pve1-install.complete
cat > /etc/motd <<MOTD

OpenCast / decentralized podcast test node
------------------------------------------
Dashboard:    http://$LAN_IP:8080
Blossom edge: http://$LAN_IP:8081
Nostr relay:  ws://$LAN_IP:7447

Status: sudo /opt/opencast-test/scripts/status.sh
TEST_MODE=1 — keep this VM on a trusted LAN only.

MOTD

echo
echo "Single-node podcast test stack installed."
echo "Dashboard:    http://$LAN_IP:8080"
echo "Blossom edge: http://$LAN_IP:8081"
echo "Nostr relay:  ws://$LAN_IP:7447"
echo
echo "TEST_MODE is ON. Do not port-forward these ports to the Internet."
echo "Media uploads are closed until you allow an identity:"
echo "  sudo $INSTALL_ROOT/scripts/uploaders.sh add <npub>      (or: add-test-identity)"
