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
