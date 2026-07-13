#!/bin/sh
# Read-only router-side status for the ONT watchdog.

set -u

CONF="/etc/ont-watchdog.conf"
[ -f "$CONF" ] && . "$CONF"

: "${TASMOTA_IP:=10.20.30.15}"
STATE_FILE="/tmp/ont-watchdog.state"
ACTION_STATE_FILE="/root/ont-watchdog.action-state"
EVENT_LOG_FILE="/root/ont-watchdog-events.log"

show_file() {
  label=$1
  file=$2
  echo "--- ${label} ---"
  if [ -f "$file" ]; then
    cat "$file"
  else
    echo "(missing)"
  fi
}

echo "==> OpenWrt watchdog status"
date '+router time: %Y-%m-%d %H:%M:%S %z'
uptime

echo "--- cron ---"
crontab -l 2>/dev/null | grep '/root/ont-watchdog.sh' || echo "(watchdog cron entry missing)"

show_file "runtime state (tmpfs)" "$STATE_FILE"
show_file "persistent action backup" "$ACTION_STATE_FILE"

echo "--- recent durable events ---"
if [ -f "$EVENT_LOG_FILE" ]; then
  tail -20 "$EVENT_LOG_FILE"
else
  echo "(no events recorded yet)"
fi

echo "--- Tasmota relay ---"
if power=$(curl -sS --max-time 5 "http://${TASMOTA_IP}/cm?cmnd=Power" 2>/dev/null); then
  printf '%s\n' "$power"
else
  echo "unreachable"
fi
