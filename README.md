# tasmota-bridge

Internet watchdog for an Airtel ONT that drops its session and needs a power-cycle to recover. The OpenWRT router checks reachability every minute, and when the WAN is genuinely down it tells a Sonoff SV running Tasmota to cut and restore mains power to the ONT.

```
   ┌────────┐    pppoe    ┌──────────────┐   LAN    ┌─────────────┐
   │ Airtel │ ──────────► │ TP-Link      │ ───────► │ Tasmota     │
   │  ONT   │             │ OpenWRT      │   HTTP   │ Sonoff SV   │
   │ (mains)│ ◄─────┐     │ 10.20.30.1   │          │ 10.20.30.15 │
   └────────┘       │     │              │          └──────┬──────┘
       ▲            │     │ ont-watchdog │                 │ relay
       │            └─────┤   cron       │                 │
       └─── mains ────────┴──────────────┴─────────────────┘
```

The watchdog only acts after several consecutive failures, won't toggle again until a cooldown elapses, doubles that cooldown per attempt within the hour, caps attempts per hour, and refuses to toggle when Tasmota itself is unreachable.

## Quick start

```sh
# 1. Adjust config.env if anything moved
$EDITOR config.env

# 2. Deploy: pushes scripts, applies Tasmota settings, installs cron, verifies
./deploy.sh
```

`deploy.sh` is idempotent — run it any time `config.env` or any script changes.

## Files

| Path                         | Purpose                                                       |
| ---------------------------- | ------------------------------------------------------------- |
| `config.env`                 | Single source of truth: hosts, timings, thresholds.           |
| `deploy.sh`                  | Push everything to router + Tasmota, then run `verify.sh`.    |
| `verify.sh`                  | End-to-end health check. Run standalone any time.             |
| `router/ont-watchdog.sh`     | The cron script that lives at `/root/` on the OpenWRT box.    |
| `tasmota/apply-config.sh`    | One-shot HTTP calls to harden Tasmota settings.               |
| `AGENTS.md` / `CLAUDE.md`    | Contract for AI agents working in this repo.                  |

## Common operations

```sh
# Tail watchdog activity on the router
ssh root@10.20.30.1 'logread -e ont-watchdog -f'

# See current watchdog state
ssh root@10.20.30.1 'cat /tmp/ont-watchdog.state'

# Force a power cycle right now (bypasses cooldown — for testing)
curl 'http://10.20.30.15/cm?cmnd=Power%20Off' && sleep 15 \
  && curl 'http://10.20.30.15/cm?cmnd=Power%20On'

# Reset state (clears fail count, cooldown, attempt counter)
ssh root@10.20.30.1 'rm -f /tmp/ont-watchdog.state'
```

## Why each knob exists

- `CONSECUTIVE_FAILS_REQUIRED=3` — a single ping failure shouldn't trigger a power cycle. Three minutes of sustained failure should.
- `POWER_OFF_SECONDS=15` — long enough for ONT capacitors to drain; short enough that you notice if you're watching.
- `BASE_COOLDOWN=300`, doubling per attempt up to `MAX_COOLDOWN=1800` — ONT GPON/DSL sync can take 2–5 min. If the first cycle didn't fix it, the second probably won't fix it faster, so wait longer.
- `ATTEMPTS_PER_HOUR_CAP=4` — past four power cycles in an hour, the problem is upstream. Stop poking the box.

## The Tasmota hardening

`tasmota/apply-config.sh` sets:

- `SetOption65 1` — disable Tasmota's "rapid power-cycle = factory reset" feature. The relay clicking can self-trigger this and wipe the WiFi credentials.
- `PowerOnState 1` — on Tasmota reboot, relay goes ON. Prevents the deadlock where a mid-cycle Tasmota crash leaves the ONT powered off forever.
- `Sleep 0` — keep WiFi awake; the unit is at ~-80 dBm. (`SleepMode` doesn't exist in this firmware build.)
- `WifiConfig 4` — smart reconnect.

## Debugging

### Where to look first

```sh
# Recent watchdog decisions (last 30 lines) — start here for any "did it act?" question
ssh root@10.20.30.1 'logread -e ont-watchdog | tail -30'

# Live tail (Ctrl-C to exit)
ssh root@10.20.30.1 'logread -e ont-watchdog -f'

# Was cron even firing? Should show one line per minute.
ssh root@10.20.30.1 'logread | grep "ont-watchdog.sh" | tail -10'

# Current runtime state on the router
ssh root@10.20.30.1 'cat /tmp/ont-watchdog.state'

# Active config the router is using (rendered by last deploy)
ssh root@10.20.30.1 'cat /etc/ont-watchdog.conf'
```

### Tasmota inspection

```sh
# Full status snapshot (all the JSON you'll ever want)
curl -s 'http://10.20.30.15/cm?cmnd=Status%200' | python3 -m json.tool

# Did Tasmota recently reboot? (BootCount climbing = a problem)
curl -s 'http://10.20.30.15/cm?cmnd=Status%201' | python3 -m json.tool \
  | grep -E 'Boot|Restart|Uptime|Save'

# WiFi signal & link state
curl -s 'http://10.20.30.15/cm?cmnd=Status%205' | python3 -m json.tool

# Current relay state
curl -s 'http://10.20.30.15/cm?cmnd=Power'

# Web UI: http://10.20.30.15  (Console tab shows live serial-style log)
# Direct log endpoint: http://10.20.30.15/lg
```

### Reading the watchdog log

Each cron run produces zero or more `ont-watchdog:` lines tagged via `logger`. Patterns to recognise:

| Log line                                              | Meaning                                                                  |
| ----------------------------------------------------- | ------------------------------------------------------------------------ |
| *(no line at all)*                                    | WAN was UP and `fail_count` was already 0 — nothing to log.              |
| `WAN recovered after N fail(s)`                       | Was failing, just came back. Counter cleared.                            |
| `WAN DOWN (fail=N/3)`                                 | Failure detected; not yet at the action threshold.                       |
| `cooldown active, Xs remaining (attempt #N this hour)`| Action threshold met but we already cycled recently. Working as intended.|
| `rate-limit reached (N/h); standing down`             | Four cycles already in this hour. Likely an ISP outage; we stop poking.  |
| `Tasmota at IP unreachable; skipping toggle`          | Watchdog refused to toggle because Tasmota wouldn't respond. No deadlock.|
| `power-cycling ONT via Tasmota ...`                   | About to flip the relay.                                                 |
| `power cycle complete; next attempt allowed in Xs`    | Done. State updated, cooldown armed.                                     |

### State file format

`/tmp/ont-watchdog.state` is a shell-sourced file:

```sh
fail_count=2            # consecutive minute-runs that have failed since last success
last_action=1715690000  # unix ts of last power-cycle (0 = never)
attempt_count=1         # power-cycles inside the current 1-hour window
attempt_window_start=...# unix ts when this rolling-hour window opened
```

Safe to delete at any time (`rm /tmp/ont-watchdog.state`) — it'll be recreated on the next cron run with a clean slate.

### Symptom → check

| Symptom                                              | First check                                                                     |
| ---------------------------------------------------- | ------------------------------------------------------------------------------- |
| Internet is down, watchdog never acted               | `logread -e ont-watchdog` — is it logging `WAN DOWN`? If not, the ping targets are reachable somehow (DNS-only failure?). |
| Watchdog acted but ONT didn't come back              | `Status 1` on Tasmota — did the relay actually flip? Check ONT mains LED.       |
| ONT got toggled multiple times in quick succession   | Should not happen with this script. Check `/tmp/ont-watchdog.state` and the log — if you see it, file it as a bug. |
| Tasmota offline / unpingable                         | `ping 10.20.30.15`. If down, check the AP. RSSI -83 dBm is borderline — relocating helps more than software. |
| Tasmota `BootCount` climbing                         | The Tasmota itself is rebooting (power glitch from relay or weak WiFi). `SetOption65 1` already protects WiFi creds, but the reboots themselves want a closer AP. |
| Cron not firing at all                               | `ps | grep crond` should show one. `crontab -l` must contain the `ont-watchdog.sh` line. |
| `./deploy.sh` fails on `scp`                         | macOS scp needs `-O` against OpenWRT/dropbear (already set in `deploy.sh`).     |
| `./deploy.sh` fails on Tasmota apply with timeout    | Expected on first deploy if `Sleep`/`WifiConfig` need changing — the device drops WiFi for ~30s. The script waits and verifies. Re-runs are idempotent and silent. |

### Forcing scenarios for testing

```sh
# Manually power-cycle the ONT right now (bypasses all watchdog logic)
curl 'http://10.20.30.15/cm?cmnd=Power%20Off' && sleep 15 \
  && curl 'http://10.20.30.15/cm?cmnd=Power%20On'

# Reset watchdog state — clears fail count, cooldown, hourly attempt count
ssh root@10.20.30.1 'rm -f /tmp/ont-watchdog.state'

# Dry-run the watchdog once (without waiting for cron)
ssh root@10.20.30.1 '/root/ont-watchdog.sh'

# Simulate WAN-down + Tasmota-unreachable safely (no real toggle).
# Repeats `CONSECUTIVE_FAILS_REQUIRED` runs against blackholed targets, then
# restores real config. See deploy.sh history / commit log for the exact form.
ssh root@10.20.30.1 '
  cp /etc/ont-watchdog.conf /tmp/conf.bak
  printf "PING_TARGETS=\"192.0.2.1\"\nTASMOTA_IP=\"192.0.2.42\"\n" >> /etc/ont-watchdog.conf
  rm -f /tmp/ont-watchdog.state
  for i in 1 2 3; do /root/ont-watchdog.sh; done
  logread -e ont-watchdog | tail -5
  mv /tmp/conf.bak /etc/ont-watchdog.conf
  rm -f /tmp/ont-watchdog.state
'
```

### Log retention

OpenWRT's `logread` is a ring buffer in RAM (default 64 KiB). Reboots wipe it, and busy periods evict old entries. If you need durable history, configure `system.@system[0].log_file` to point at `/root/syslog.log` (survives reboot, eats flash) — but the watchdog is chatty enough that grepping `logread` in the moment is usually sufficient.
