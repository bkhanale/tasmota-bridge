#!/bin/sh
# ONT watchdog — runs from cron on OpenWRT every minute.
# Decides whether to power-cycle the ONT via Tasmota (Sonoff SV) based on
# internet reachability, with cooldown, escalating backoff, and a Tasmota
# liveness check to avoid toggling a device that won't toggle back.
#
# Config: /etc/ont-watchdog.conf (rendered by deploy.sh)
# State:  /tmp/ont-watchdog.state (sourced and rewritten each run)
# Logs:   `logread -e ont-watchdog`

set -u

CONF="/etc/ont-watchdog.conf"
[ -f "$CONF" ] && . "$CONF"

: "${TASMOTA_IP:=10.20.30.15}"
: "${PING_TARGETS:=1.1.1.1 8.8.8.8 9.9.9.9}"
: "${PING_TIMEOUT:=3}"
: "${CONSECUTIVE_FAILS_REQUIRED:=3}"
: "${POWER_OFF_SECONDS:=15}"
: "${BASE_COOLDOWN:=300}"
: "${MAX_COOLDOWN:=1800}"
: "${ATTEMPTS_PER_HOUR_CAP:=4}"
: "${STATE_FILE:=/tmp/ont-watchdog.state}"
: "${ACTION_STATE_FILE:=/root/ont-watchdog.action-state}"
: "${EVENT_LOG_FILE:=/root/ont-watchdog-events.log}"

# The runtime state belongs in tmpfs so normal minute-by-minute bookkeeping
# never writes flash. Only completed power-cycle state is backed up, since that
# is the information needed to preserve cooldown/backoff if tmpfs is cleared.
EVENT_LOG_MAX_BYTES=32768
EVENT_LOG_GENERATIONS=3

log() { logger -t ont-watchdog "$*"; }

# Keep a small, durable record of meaningful lifecycle events. This is
# deliberately not called for every failed minute: active logread remains the
# detailed live stream, while this survives reboots without wearing flash.
audit() {
  if [ -f "$EVENT_LOG_FILE" ]; then
    log_size=$(wc -c < "$EVENT_LOG_FILE" 2>/dev/null || printf '0')
    if [ "$log_size" -ge "$EVENT_LOG_MAX_BYTES" ]; then
      i=$EVENT_LOG_GENERATIONS
      while [ "$i" -gt 1 ]; do
        previous=$((i - 1))
        [ -f "${EVENT_LOG_FILE}.${previous}" ] && mv "${EVENT_LOG_FILE}.${previous}" "${EVENT_LOG_FILE}.${i}"
        i=$previous
      done
      mv "$EVENT_LOG_FILE" "${EVENT_LOG_FILE}.1"
    fi
  fi

  printf '%s ont-watchdog: %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >> "$EVENT_LOG_FILE"
}

fail_count=0
last_action=0
attempt_count=0
attempt_window_start=0
state_notice=
backup_notice=
if [ -f "$STATE_FILE" ]; then
  . "$STATE_FILE"
  if [ "$last_action" -gt 0 ] && [ ! -f "$ACTION_STATE_FILE" ]; then
    backup_notice="persistent action backup missing; restored it from runtime state"
  fi
elif [ -f "$ACTION_STATE_FILE" ]; then
  . "$ACTION_STATE_FILE"
  state_notice="runtime state missing; restored cooldown/rate-limit state from persistent backup"
else
  state_notice="runtime state missing; initializing without prior action state"
fi

NOW=$(date +%s)

if [ -n "$state_notice" ]; then
  log "$state_notice"
  audit "$state_notice"
fi

save_state() {
  cat > "${STATE_FILE}.tmp" <<EOF
fail_count=$fail_count
last_action=$last_action
attempt_count=$attempt_count
attempt_window_start=$attempt_window_start
EOF
  mv "${STATE_FILE}.tmp" "$STATE_FILE"
}

save_action_state() {
  cat > "${ACTION_STATE_FILE}.tmp" <<EOF
last_action=$last_action
attempt_count=$attempt_count
attempt_window_start=$attempt_window_start
EOF
  mv "${ACTION_STATE_FILE}.tmp" "$ACTION_STATE_FILE"
}

if [ -n "$backup_notice" ]; then
  save_action_state
  log "$backup_notice"
  audit "$backup_notice"
fi

# Roll the rate-limit window forward once per hour
if [ "$attempt_window_start" -eq 0 ] || [ $((NOW - attempt_window_start)) -gt 3600 ]; then
  attempt_count=0
  attempt_window_start=$NOW
fi

# Internet reachability — UP if any target responds
internet_up=0
for t in $PING_TARGETS; do
  if ping -c1 -W"$PING_TIMEOUT" "$t" >/dev/null 2>&1; then
    internet_up=1
    break
  fi
done

if [ "$internet_up" -eq 1 ]; then
  if [ "$fail_count" -gt 0 ]; then
    log "WAN recovered after $fail_count fail(s)"
    audit "WAN recovered after $fail_count fail(s)"
  fi
  fail_count=0
  save_state
  exit 0
fi

fail_count=$((fail_count + 1))
log "WAN DOWN (fail=$fail_count/$CONSECUTIVE_FAILS_REQUIRED)"
if [ "$fail_count" -eq 1 ]; then
  audit "WAN DOWN episode started"
fi

if [ "$fail_count" -lt "$CONSECUTIVE_FAILS_REQUIRED" ]; then
  save_state
  exit 0
fi

# Escalating cooldown: doubles per attempt within the hour, capped
cooldown=$BASE_COOLDOWN
i=0
while [ "$i" -lt "$attempt_count" ]; do
  cooldown=$((cooldown * 2))
  i=$((i + 1))
done
[ "$cooldown" -gt "$MAX_COOLDOWN" ] && cooldown=$MAX_COOLDOWN

if [ "$last_action" -gt 0 ] && [ $((NOW - last_action)) -lt "$cooldown" ]; then
  remaining=$((cooldown - (NOW - last_action)))
  log "cooldown active, ${remaining}s remaining (attempt #$attempt_count this hour)"
  save_state
  exit 0
fi

if [ "$attempt_count" -ge "$ATTEMPTS_PER_HOUR_CAP" ]; then
  log "rate-limit reached ($attempt_count/h); standing down — likely ISP outage"
  save_state
  exit 0
fi

# Confirm Tasmota is alive before we ask it to toggle. If we toggle a dead
# Tasmota, we never see the relay open AND we never see it close — deadlock.
if ! curl -sS --max-time 5 "http://${TASMOTA_IP}/cm?cmnd=Power" 2>/dev/null | grep -q '"POWER"'; then
  log "Tasmota at ${TASMOTA_IP} unreachable; skipping toggle"
  save_state
  exit 0
fi

log "power-cycling ONT via Tasmota (cooldown=${cooldown}s, attempt=$((attempt_count + 1))/h)"
audit "power-cycling ONT via Tasmota (cooldown=${cooldown}s, attempt=$((attempt_count + 1))/h)"
curl -sS --max-time 5 "http://${TASMOTA_IP}/cm?cmnd=Power%20Off" >/dev/null || log "Power Off request failed mid-flight"
sleep "$POWER_OFF_SECONDS"
curl -sS --max-time 5 "http://${TASMOTA_IP}/cm?cmnd=Power%20On"  >/dev/null || log "Power On request failed mid-flight"

last_action=$NOW
fail_count=0
attempt_count=$((attempt_count + 1))
save_state
save_action_state

log "power cycle complete; next attempt allowed in ${cooldown}s"
audit "power cycle complete; next attempt allowed in ${cooldown}s"
