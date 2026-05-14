# Agent guide

This file is the contract for any AI agent (Claude Code, opencode, codex, …) working in this repo. Read it before making changes.

## What this repo does

It keeps the home internet up by power-cycling the Airtel ONT through a Tasmota-flashed Sonoff SV when the OpenWRT router (10.20.30.1) detects the WAN is unreachable. See `README.md` for architecture.

## Where things run

- Code in this repo lives on the user's machine. Nothing here runs on its own.
- `router/ont-watchdog.sh` is *deployed to* `root@10.20.30.1:/root/ont-watchdog.sh` and triggered by cron there.
- `tasmota/apply-config.sh` issues HTTP calls to `http://10.20.30.15/cm` from wherever you run it.
- `deploy.sh` orchestrates both and ends by calling `verify.sh`.

Never edit files on the router by hand. They will be overwritten on the next `./deploy.sh`. Always change `config.env` or the script in this repo and re-deploy.

## How to make a change (the loop)

Every change must complete this loop before being considered done:

1. **Edit** the relevant file in this repo (script, config, or Tasmota command).
2. **Deploy** with `./deploy.sh`. This pushes to the router, applies Tasmota settings, and runs verification.
3. **Verify** — if `./deploy.sh` exits non-zero, fix the failure before continuing. Don't skip checks.
4. **Observe** at least one cron run on the router after deploy:
   ```sh
   ssh root@10.20.30.1 'logread -e ont-watchdog -f'
   ```
   Wait for one new log line and confirm it matches the change you made.
5. **Commit** with a message that says what changed and *why* (the user cares about why).

If any step fails, fix the root cause. Do not paper over by disabling checks, raising timeouts, or removing tests.

## SSH access

`root@10.20.30.1` is reachable from the user's machine using their existing key. You can `ssh` and `scp` without a password. Run commands non-interactively (`ssh host 'cmd1; cmd2'`) — there is no human in the loop.

## What lives where (router-side)

- `/root/ont-watchdog.sh` — the script (managed; do not hand-edit)
- `/etc/ont-watchdog.conf` — rendered from `config.env` by `deploy.sh`
- `/tmp/ont-watchdog.state` — runtime state (fail count, last action, attempt window). Safe to delete.
- `crontab -l` — should contain exactly one `ont-watchdog` line at `* * * * *`

## Tasmota notes

- IP: `10.20.30.15`. No auth. HTTP API: `http://10.20.30.15/cm?cmnd=<command>`.
- Status snapshot: `curl 'http://10.20.30.15/cm?cmnd=Status%200'`
- The Sonoff SV's WiFi is weak (RSSI ~-80 dBm). Any new logic that issues HTTP calls must use `--max-time` and treat failure as "skip this iteration", never as "retry in a tight loop".

## Things to avoid

- Don't shorten `POWER_OFF_SECONDS` below 10 — capacitors in the ONT won't drain.
- Don't shorten `BASE_COOLDOWN` below 180 — the ONT can't renegotiate faster than that.
- Don't add a second cron entry that talks to Tasmota. There must be exactly one writer for the relay.
- Don't replace the consecutive-fail check with a single ping. Single-shot pings give false positives.
- Don't add features the user didn't ask for. Keep the surface area small.

## Testing without breaking the user's internet

`./deploy.sh` is safe to run live — it doesn't toggle the relay unless WAN is down. To exercise the toggle path, manually issue the curl commands documented in `README.md > Common operations`. The watchdog won't fight you because it only acts when WAN is unreachable.

To exercise the watchdog logic itself without touching the relay: SSH to the router, edit `/etc/ont-watchdog.conf` to point `TASMOTA_IP` at a non-routable address, run the script, observe it taking the "Tasmota unreachable" branch, then re-deploy to restore. Revert state with `rm /tmp/ont-watchdog.state`.

## Changelog

Every non-trivial change must be logged in `changelog/` *in the same commit* that makes the change. This includes:

- Code or config changes in this repo.
- Router-side changes (`/etc/config/*`, crontab, scripts under `/root/`).
- Tasmota setting changes that aren't already captured by `tasmota/apply-config.sh`.

A "non-trivial change" means anything someone might need to look up later — i.e. anything that would be worth grepping the changelog for. A typo fix in a comment is trivial; a knob tweak in `config.env` is not.

To add an entry:

1. Copy any file in `changelog/` whose name matches `YYYY-MM-DD-*.html` as a template.
2. Rename it to `YYYY-MM-DD-short-slug.html` (today's date in UTC, kebab-case slug).
3. Fill in: title, tag (`feat` / `fix` / `docs` / `ops`), one-paragraph *why*, *what changed* (file paths + commands), and *verification*. If the change touches live infrastructure, include a *rollback* section.
4. Prepend a new `<li>` to the list in `changelog/index.html`.
5. Stage both files alongside the change they describe; commit together.

If you can't think of what to write under *verification*, you probably didn't verify the change — fix that before committing.

## Debugging

When diagnosing user-reported issues, read `README.md > Debugging` first — it has the symptom→check table, the log line glossary, and the state file format. Two go-to commands:

```sh
ssh root@10.20.30.1 'logread -e ont-watchdog | tail -30; echo ---; cat /tmp/ont-watchdog.state'
curl -s 'http://10.20.30.15/cm?cmnd=Status%201' | python3 -m json.tool | grep -E 'Boot|Restart|Uptime'
```

If a `BootCount` is climbing, Tasmota itself is rebooting — that's a power/WiFi-signal issue, not a logic bug, and no script change in this repo will fix it.

## When in doubt

The user prefers a short proposal and a confirmation over a large autonomous change. If a change would touch more than one of: cron cadence, cooldown semantics, Tasmota settings, or the deploy contract — propose the diff in the conversation first.
