#!/usr/bin/env bash
# Apply persistent Tasmota settings that harden the device against the
# rapid-toggle / weak-WiFi failure modes documented in README.md.
#
# Idempotent: snapshots current state via "Status 0" + SetOption65, and only
# writes the settings that actually need to change. WiFi-affecting commands
# (Sleep, WifiConfig) cause the device to briefly drop off the network — so
# avoiding redundant writes is important, not just nice-to-have.

set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
. ./config.env

URL="http://${TASMOTA_IP}/cm"

# Fetch a single command. Returns "" on timeout/error.
fetch() { curl -sS --max-time 5 --get --data-urlencode "cmnd=$1" "$URL" 2>/dev/null || true; }

# Wait for Tasmota to be reachable again after a WiFi-affecting write.
wait_back() {
  local i
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    if [ -n "$(fetch 'Power')" ]; then return 0; fi
    sleep 5
  done
  echo "Tasmota did not come back after a setting change — aborting." >&2
  exit 1
}

# write LABEL COMMAND  → issue COMMAND, tolerate transient HTTP error,
# wait for the device to be reachable again.
write() {
  local label="$1" cmnd="$2"
  printf '  set  %-14s → %s\n' "$label" "$cmnd"
  curl -sS --max-time 10 --get --data-urlencode "cmnd=$cmnd" "$URL" >/dev/null 2>&1 || true
  wait_back
}

echo "==> Tasmota at ${TASMOTA_IP}: snapshotting state"
status=$(fetch 'Status 0')
[ -n "$status" ] || { echo "Tasmota unreachable at ${TASMOTA_IP}" >&2; exit 1; }
so65=$(fetch 'SetOption65')

# Extract current values from the snapshot
cur_pos=$(printf '%s' "$status"   | sed -n 's/.*"PowerOnState":\([0-9]*\).*/\1/p')
cur_sleep=$(printf '%s' "$status" | sed -n 's/.*"Sleep":\([0-9]*\).*/\1/p' | head -n1)
cur_wcfg=$(printf '%s' "$status"  | sed -n 's/.*"WifiConfig":\([0-9]*\).*/\1/p')
cur_so65=$(printf '%s' "$so65"    | sed -n 's/.*"SetOption65":"\([^"]*\)".*/\1/p')

printf '       current: SetOption65=%s PowerOnState=%s Sleep=%s WifiConfig=%s\n' \
  "${cur_so65:-?}" "${cur_pos:-?}" "${cur_sleep:-?}" "${cur_wcfg:-?}"

# Safe (no WiFi disruption) writes first.
# SetOption65=1 → disable fast-power-cycle factory reset (protects WiFi creds)
[ "$cur_so65" = "ON" ] || write "SetOption65"  "SetOption65 1"
# PowerOnState=1 → relay defaults ON when Tasmota boots (avoids deadlock)
[ "$cur_pos"  = "1"  ] || write "PowerOnState" "PowerOnState 1"

# WiFi-affecting writes only if needed.
# Sleep 0 → disable WiFi-tied dynamic sleep (helps with weak signal)
[ "$cur_sleep" = "0" ] || write "Sleep" "Sleep 0"
# WifiConfig 4 → smart reconnect across saved APs
[ "$cur_wcfg" = "4" ]  || write "WifiConfig" "WifiConfig 4"

# Always persist — cheap, doesn't disturb WiFi.
curl -sS --max-time 5 --get --data-urlencode "cmnd=SaveData 1" "$URL" >/dev/null || true

echo "==> Tasmota config applied (all settings idempotent)."
