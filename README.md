# connexion-daemon-watcher

A monitor for the Koha Connexion import daemon. Probes the daemon over
TCP, optionally restarts it on failure, and posts state-aware alerts to
Slack (one alert when a server fails, one when it recovers, with
throttling so the same ongoing outage doesn't spam the channel).

Designed to be run from cron: silent on success, output (and non-zero
exit) on failure so cron mails the operator.

## Requirements

- Perl 5 with the standard distribution
  (`File::Basename`, `File::Path`, `Getopt::Long`, `HTTP::Tiny`,
  `IO::Select`, `IO::Socket::INET`, `JSON::PP`, `Pod::Usage`,
  `Sys::Hostname` — all core).
- Read access to a Koha `connexion.cnf` file.
- For `--restart`: permission to execute `/etc/init.d/connexion-daemon`
  (typically root, or sudo configured for the cron user).
- For `--slack`: outbound HTTPS to `hooks.slack.com` and a Slack
  [incoming-webhook URL](https://api.slack.com/messaging/webhooks).
- For `--state-file` (default `/var/lib/connexion-daemon-watcher/state.json`):
  write access. The script creates the parent dir if missing.

## Usage

```
connexion-daemon-watcher.pl [options]
```

| Option                    | Default                                              | Description                                                                                          |
| ------------------------- | ---------------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| `--config`, `-c PATH`     | `/etc/koha/sites/*/connexion.cnf` (globbed)          | Specific `connexion.cnf` to read.                                                                    |
| `--timeout`, `-t SECS`    | `5`                                                  | Per-phase timeout (TCP connect, deep-probe read).                                                    |
| `--verbose`, `-v`         | off                                                  | Print `OK: …` on success and on Slack post success.                                                  |
| `--deep`                  | off                                                  | Use the protocol-level probe (see below).                                                            |
| `--restart`, `-r`         | off                                                  | On failure, run `/etc/init.d/connexion-daemon stop` then `start`.                                    |
| `--restart-min-interval N`| `10`                                                 | Minutes that must pass between restart attempts.                                                     |
| `--restart-grace SECS`    | `5`                                                  | Sleep before re-probing after a restart.                                                             |
| `--slack URL`             | unset                                                | Slack incoming-webhook URL. Failure + recovery alerts are posted here.                               |
| `--alert-interval N`      | `30`                                                 | Minutes between failure alerts for the same ongoing incident.                                        |
| `--state-file PATH`       | `/var/lib/connexion-daemon-watcher/state.json`       | Where to persist incident + restart state. Use one path per Koha instance.                           |
| `--help`, `-?`            |                                                      | Show usage.                                                                                          |

Exit code: `0` if the daemon is reachable (including after a successful
restart-recover cycle), `1` otherwise.

## Probe modes

### Default — TCP connect

Open a TCP socket to the configured port. Listener up = pass. Cheap,
silent in the daemon log, but doesn't catch the failure mode where the
listener accepts connections but the worker loop is wedged.

### `--deep` — protocol probe

After connecting, send a single null byte and wait for any response. The
daemon parses the null as an empty request, logs `Invalid request`, and
writes back `Bad request\0`. Receiving any bytes proves accept → read →
log → respond all work, not just the listener.

Trade-offs:

- Adds an `Invalid request` line to the daemon log on every probe.
- Doesn't exercise the upstream Koha HTTP backend (the auth check only
  fires after a valid MARC parse, which we deliberately don't send).
- Recommended where you've actually seen wedge-style failures; the cheap
  probe is fine elsewhere.

## Restart behavior

With `--restart`:

1. On failure, check `last_restart_at` in the state file.
   - If less than `--restart-min-interval` minutes ago: **skip the
     restart** and report it in the Slack alert. Prevents tight
     restart loops from masking a real outage.
   - Otherwise: run `/etc/init.d/connexion-daemon stop` then `start`
     (the init script has no `restart` subcommand). The `start` exit code
     decides success; `stop` failures are logged but don't fail the
     restart, since they often just mean the daemon was already down.
2. Sleep `--restart-grace` seconds.
3. Re-probe with the same probe mode.
4. If the re-probe succeeds, the script exits `0`. Slack gets a recovery
   alert only if a failure had already been alerted for this incident;
   single-run blips that self-heal stay silent.

## Alert behavior

Slack alerts are sent only when `--slack URL` is supplied. Behavior:

- **Failure alert** — sent when the probe fails. Throttled by
  `--alert-interval`: while an incident is ongoing, no more than one
  failure alert per N minutes (default 30). Includes restart status and
  post-restart re-probe result when applicable.
- **Recovery alert** — sent when the probe succeeds *and* the prior
  state was "down" *and* a failure alert had been sent for that
  incident. Never throttled. Silent recoveries from un-alerted blips
  do not spam the channel.

State transitions across runs:

```
            probe ok       probe fails
                │              │
   state=up    ──── stay up    ──── alert (1st failure, sets last_alert_at)
                                   state→down
   state=down  ──── recovery alert  ──── alert again iff last_alert_at
              ──── (if last_alert_at)        is older than --alert-interval
                   state→up
```

## State file

JSON document at `--state-file`. Fields:

| Field                   | Type      | Notes                                              |
| ----------------------- | --------- | -------------------------------------------------- |
| `status`                | `up`/`down` | Last observed state.                              |
| `down_since`            | epoch s   | When the current outage started; `null` when up.   |
| `last_failure_alert_at` | epoch s   | For failure-alert throttle; cleared on recovery.   |
| `last_restart_at`       | epoch s   | For the restart guard; preserved across recovery.  |

If the file is missing, unreadable, or malformed, the script behaves as
if the prior state was "up" and continues.

When monitoring multiple Koha instances on one host, give each its own
`--state-file` path so their state doesn't collide.

## Examples

Plain check, suitable for cron:

```sh
*/5 * * * * /usr/local/bin/connexion-daemon-watcher.pl
```

Deep probe + auto-restart + Slack alerts, default throttling and guard:

```sh
*/5 * * * * /usr/local/bin/connexion-daemon-watcher.pl \
    --deep --restart \
    --slack https://hooks.slack.com/services/T000/B000/XXXX
```

Multiple instances on one host, with per-instance state files:

```sh
*/5 * * * * /usr/local/bin/connexion-daemon-watcher.pl \
    -c /etc/koha/sites/lib1/connexion.cnf \
    --state-file /var/lib/connexion-daemon-watcher/lib1.json \
    --restart --slack $SLACK_URL

*/5 * * * * /usr/local/bin/connexion-daemon-watcher.pl \
    -c /etc/koha/sites/lib2/connexion.cnf \
    --state-file /var/lib/connexion-daemon-watcher/lib2.json \
    --restart --slack $SLACK_URL
```

Tighten the failure-alert throttle to 10 minutes:

```sh
connexion-daemon-watcher.pl --slack $SLACK_URL --alert-interval 10
```

## Slack message examples

Failure with restart attempt + post-restart probe still down:

```
:rotating_light: *Connexion daemon down* on `koha-prod-01`
Cannot connect to `127.0.0.1:8000`: connect: Connection refused
:white_check_mark: Restart: Restart command exited 0
:warning: Post-restart probe: still down (connect: Connection refused)
```

Failure where the restart guard skipped the restart:

```
:rotating_light: *Connexion daemon down* on `koha-prod-01`
Cannot connect to `127.0.0.1:8000`: connect: Connection refused
:no_entry_sign: Restart skipped: Skipped: last restart 240s ago, min interval is 600s
```

Recovery (after the daemon comes back, having alerted earlier):

```
:white_check_mark: *Connexion daemon recovered* on `koha-prod-01`
`127.0.0.1:8000` is reachable again after 12m
```

## License

GPLv3+, the same as Koha. See the license header in
`connexion-daemon-watcher.pl`.
