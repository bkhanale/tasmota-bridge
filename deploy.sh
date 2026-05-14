#!/usr/bin/env bash
# End-to-end deploy: push watchdog + config to the OpenWRT router, install
# cron, apply Tasmota settings, and run verification.
#
# Re-run any time config.env or scripts change. Idempotent.

set -euo pipefail

cd "$(dirname "$0")"
# shellcheck disable=SC1091
. ./config.env

echo "==> Applying Tasmota settings (${TASMOTA_IP})"
./tasmota/apply-config.sh

echo "==> Rendering /etc/ont-watchdog.conf"
TMPCONF=$(mktemp)
trap 'rm -f "$TMPCONF"' EXIT
cat > "$TMPCONF" <<EOF
# Rendered by deploy.sh — do not edit on the router. Edit config.env in the
# tasmota-bridge repo and re-run ./deploy.sh.
TASMOTA_IP="${TASMOTA_IP}"
PING_TARGETS="${PING_TARGETS}"
PING_TIMEOUT=${PING_TIMEOUT}
CONSECUTIVE_FAILS_REQUIRED=${CONSECUTIVE_FAILS_REQUIRED}
POWER_OFF_SECONDS=${POWER_OFF_SECONDS}
BASE_COOLDOWN=${BASE_COOLDOWN}
MAX_COOLDOWN=${MAX_COOLDOWN}
ATTEMPTS_PER_HOUR_CAP=${ATTEMPTS_PER_HOUR_CAP}
EOF

echo "==> Copying files to ${ROUTER_SSH}"
# -O = legacy SCP protocol. OpenWRT's dropbear lacks sftp-server, which is
# what modern OpenSSH scp negotiates by default.
scp -O -q router/ont-watchdog.sh "${ROUTER_SSH}:/root/ont-watchdog.sh"
scp -O -q "$TMPCONF"             "${ROUTER_SSH}:/etc/ont-watchdog.conf"

echo "==> Installing cron + cleaning old artifacts"
ssh "$ROUTER_SSH" '
  set -eu
  chmod +x /root/ont-watchdog.sh

  # Remove any previous-generation scripts and state
  rm -f /root/ont-watchdog-simple.sh /root/ont-autoreboot.sh
  rm -f /tmp/ont_fail_count /tmp/ont_cooldown

  # Rewrite crontab: preserve unrelated entries, install ours at every minute.
  # Build via temp file to avoid pipe-and-set-e edge cases on busybox.
  tmp=$(mktemp)
  crontab -l 2>/dev/null | grep -v -E "ont-watchdog|ont-autoreboot" > "$tmp" || true
  echo "* * * * * /root/ont-watchdog.sh" >> "$tmp"
  crontab "$tmp"
  rm -f "$tmp"

  # Busybox crond picks up crontab changes automatically; no restart needed.
'

echo "==> Running verification"
./verify.sh
