#!/usr/bin/env bash
# Read-only health snapshot for the complete ONT watchdog chain.

set -euo pipefail

cd "$(dirname "$0")"
# shellcheck disable=SC1091
. ./config.env

echo "==> Tasmota (${TASMOTA_IP})"
if status=$(curl -sS --max-time 5 "http://${TASMOTA_IP}/cm?cmnd=Status%201"); then
  uptime=$(printf '%s' "$status" | sed -n 's/.*"Uptime":"\([^"]*\)".*/\1/p')
  boots=$(printf '%s' "$status" | sed -n 's/.*"BootCount":\([0-9]*\).*/\1/p')
  if power_json=$(curl -sS --max-time 5 "http://${TASMOTA_IP}/cm?cmnd=Power"); then
    power=$(printf '%s' "$power_json" | sed -n 's/.*"POWER":"\([^"]*\)".*/\1/p')
  else
    power='unreachable'
  fi
  printf '  relay: %s\n  uptime: %s\n  boot count: %s\n' "${power:-?}" "${uptime:-?}" "${boots:-?}"
else
  echo "  unreachable"
fi

echo "==> OpenWrt router (${ROUTER_SSH})"
ssh -o BatchMode=yes -o ConnectTimeout=5 "$ROUTER_SSH" /root/ont-watchdog-status.sh
