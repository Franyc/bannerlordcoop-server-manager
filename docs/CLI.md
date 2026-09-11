# Command reference

One entry point: `coop`. Everything a person or a script does goes through
it.

## Global options

These work with any command and may appear before or after it.

| Option | Effect |
|---|---|
| `--install-dir <path>` | Operate on the installation in `<path>` |
| `--instance <id>` | Operate on a named instance |
| `--config <file>` | Read settings from `<file>` |
| `--json` | Machine-readable output, where the command supports it |
| `--non-interactive` | Never prompt; a missing required value is an error |
| `--yes`, `-y` | Answer confirmations with yes |
| `--quiet`, `-q` | Only warnings and errors |
| `--verbose`, `-v` | Extra detail |
| `-h`, `--help` | Usage |

Every configuration setting is also a flag, derived from its name:
`--save-name`, `--game-port`, `--backup-keep-auto`. Aliases: `--password`,
`--channel`, `--backup-retention`. See [CONFIGURATION.md](CONFIGURATION.md).

## Setup

### `coop install`

Installs a server on this host. Needs root.

| Option | Effect |
|---|---|
| `--default` | Recommended mode: campaign name, password, Steam |
| `--advanced` | Also ports, paths, backups, updates, limits |
| `--non-interactive` | Take every value from flags or a config file |

Runs in eight steps: compatibility check, setup mode, configuration, Steam
authentication, summary, installation, start, validation. Nothing is
changed until after the summary is confirmed.

Running it again on an existing installation offers update, repair,
reconfigure or exit - it never silently overwrites a campaign.

```bash
sudo coop install --advanced
```

```bash
sudo coop install --default --non-interactive --save-name "Customer Campaign" --server-password "s3cret" --game-port 4210
```

## Running the server

| Command | Root | Notes |
|---|---|---|
| `coop status` | no | What the server is doing. Supports `--json`. |
| `coop start` | yes | Starts and waits for the server to serve clients |
| `coop stop` | yes | Console shutdown with a closing save |
| `coop restart` | yes | Stop, then start |
| `coop save` | yes | Force a save and wait for the file |
| `coop console <cmd>` | no | Send a command to the server console |
| `coop logs [--follow] [-n N]` | no | Show the server log |

`coop start` returns only once the server reports that it is serving, which
on a grown campaign takes about two minutes. It exits 50 if that never
happens.

Console commands the server accepts: `status`, `players`, `save`, `say`,
`kick`, `help`.

```bash
coop console players
```

## Configuration

| Command | Root | Notes |
|---|---|---|
| `coop config` | yes | Walk through the common settings |
| `coop config --advanced` | yes | Include the rest |
| `coop config --list` | no | Every setting, value and type. `--json`. |
| `coop config --get KEY` | no | Print one value |
| `coop config --set KEY=VALUE` | yes | Change one value |
| `coop config --apply` | yes | Regenerate generated files, restart if needed |

A change to a setting marked "restart required" offers a restart; in
`--non-interactive` mode it does not, and you restart when it suits you.

## Software

| Command | Root | Notes |
|---|---|---|
| `coop update` | yes | Install a newer Coop build |
| `coop update --check` | no | Only report. `--json`. |
| `coop update --force` | yes | Install even when the check disagrees |
| `coop rollback` | yes | Return to the previous Coop build |
| `coop steam status [--probe]` | no | Is the session usable? `--json`. |
| `coop steam login` | yes | Authenticate with Steam |
| `coop steam logout` | yes | Discard the stored session |

`coop update --check` exits **0 when the check succeeded**, and says in its
output whether an update exists - the same convention every other tool
follows. Scripts that prefer it as an exit code add `--exit-status` and get
100 when one is available.

`coop steam status` is instant and offline; `--probe` contacts Steam, which
is the only way to tell an expired session from a valid one.

## Data

| Command | Root | Notes |
|---|---|---|
| `coop backup [--note "..."]` | yes | Create a backup now. `--json`. |
| `coop backup list` | no | List backups with their IDs. `--json`. |
| `coop backup info <id>` | no | What is in one. `--json`. |
| `coop backup restore <id>` | yes | Restore saves and configuration |
| `coop import-save <dir>` | yes | Import campaign saves from a directory |

A backup is identified by its ID (`20260911-004626`), by its file name, or
by its position in the last listing. It is never taken from an arbitrary
path.

```bash
coop backup list
```

```bash
coop backup restore 20260911-004626
```

## Diagnostics

| Command | Root | Notes |
|---|---|---|
| `coop doctor` | no | Check everything and say what is wrong. `--json`. |
| `coop version` | no | Manager and Coop versions. `--json`. |

`coop doctor` exits 50 if anything failed, 0 otherwise - warnings alone do
not make it fail.

## Exit codes

Automation can tell failure classes apart:

| Code | Meaning |
|---|---|
| 0 | Success |
| 2 | Wrong invocation: unknown command, missing argument |
| 10 | Invalid configuration, or a required value is missing |
| 20 | Unsupported system, or a dependency is unavailable |
| 30 | Steam authentication or download failed |
| 40 | Container or server process failure |
| 50 | Health check failed |
| 60 | Backup or restore failed |
| 70 | Another operation holds the lock |
| 100 | `update --check --exit-status` only: an update is available |

## Non-interactive behaviour

`--non-interactive` is a promise, not a hint:

| Situation | Interactive | `--non-interactive` |
|---|---|---|
| A required value is missing | asks | exit 10, naming the flag |
| A destructive step needs confirmation | asks | exit 10 unless `--yes` |
| The Steam session is missing | offers to log in | exit 30 with instructions |
| Output | colour when on a terminal | plain; `--json` for machines |

There are no hidden confirmations. A destructive operation without `--yes`
fails rather than proceeding.

## JSON output

Supported by `status`, `doctor`, `config --list`, `backup list`,
`backup info`, `backup`, `update --check`, `steam status` and `version`.

Logs and progress always go to stderr, so stdout carries nothing but the
JSON document:

```bash
coop status --json | jq -r .status
```

```bash
coop doctor --json | jq -r '.checks[] | select(.status=="fail")'
```
