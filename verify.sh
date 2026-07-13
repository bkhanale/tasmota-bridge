#!/usr/bin/env bash
# End-to-end verification: confirms every link in the chain is healthy.
# Exits non-zero on first failure so deploy.sh halts loudly.

set -euo pipefail

cd "$(dirname "$0")"
# shellcheck disable=SC1091
. ./config.env

pass() { printf '  \033[32mok\033[0m  %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; exit 1; }
note() { printf '  --   %s\n' "$1"; }

echo "==> Verify Tasmota (${TASMOTA_IP})"
status=$(curl -sS --max-time 5 "http://${TASMOTA_IP}/cm?cmnd=Status%200" || true)
[ -n "$status" ] || fail "Tasmota HTTP API unreachable"
pass "Tasmota reachable"

power=$(printf '%s' "$status" | sed -n 's/.*"Power":"\([^"]*\)".*/\1/p')
[ -n "$power" ] && pass "Tasmota power state: $power" || fail "Could not parse power state"

pos=$(printf '%s' "$status" | sed -n 's/.*"PowerOnState":\([0-9]*\).*/\1/p')
[ "$pos" = "1" ] && pass "PowerOnState=1 (boot ON, no deadlock)" \
                 || fail "PowerOnState=$pos (expected 1) — re-run tasmota/apply-config.sh"

# SetOption65 lives inside the SetOption hex array (slot 0, bit 26 on most builds).
# Easier to verify via the dedicated query.
so65=$(curl -sS --max-time 5 "http://${TASMOTA_IP}/cm?cmnd=SetOption65" | sed -n 's/.*"SetOption65":"\([^"]*\)".*/\1/p')
[ "$so65" = "ON" ] && pass "SetOption65=ON (fast-cycle factory reset disabled)" \
                   || fail "SetOption65=$so65 (expected ON)"

sleep_val=$(printf '%s' "$status" | sed -n 's/.*"Sleep":\([0-9]*\).*/\1/p')
[ "$sleep_val" = "0" ] && pass "Sleep=0 (WiFi stays awake)" \
                       || note "Sleep=$sleep_val (0 is preferred for weak WiFi)"

rssi=$(printf '%s' "$status" | sed -n 's/.*"RSSI":\([0-9]*\).*/\1/p')
sig=$(printf '%s'  "$status" | sed -n 's/.*"Signal":\(-\{0,1\}[0-9]*\).*/\1/p')
note "WiFi: RSSI=${rssi:-?} Signal=${sig:-?} dBm"
if [ -n "$sig" ] && [ "$sig" -lt -78 ]; then
  note "WiFi signal is weak; consider relocating Tasmota or adding a closer AP"
fi

echo "==> Verify OpenWRT router (${ROUTER_SSH})"
ssh "$ROUTER_SSH" '
  set -e
  [ -x /root/ont-watchdog.sh ]           || { echo "watchdog missing or not executable"; exit 1; }
  [ -x /root/ont-watchdog-status.sh ]    || { echo "status helper missing or not executable"; exit 1; }
  [ -f /etc/ont-watchdog.conf ]          || { echo "config missing"; exit 1; }
  crontab -l | grep -q "/root/ont-watchdog.sh" || { echo "cron entry missing"; exit 1; }
  # Old artifacts must be gone
  [ ! -e /root/ont-watchdog-simple.sh ]  || { echo "stale ont-watchdog-simple.sh still present"; exit 1; }
  [ ! -e /root/ont-autoreboot.sh ]       || { echo "stale ont-autoreboot.sh still present"; exit 1; }
' && pass "router has script, config, cron entry; old artifacts cleaned" \
  || fail "router-side check failed"

ssh "$ROUTER_SSH" '/root/ont-watchdog-status.sh >/dev/null' \
  && pass "router status helper runs" \
  || fail "router status helper failed"

echo "==> Dry-run watchdog on router (current internet state)"
ssh "$ROUTER_SSH" 'sh /root/ont-watchdog.sh' || fail "watchdog script errored"
last=$(ssh "$ROUTER_SSH" 'logread -e ont-watchdog | tail -3')
[ -n "$last" ] && printf '%s\n' "$last" | sed 's/^/  | /' || note "no logs yet — first run is fresh"

echo "==> All checks passed."
