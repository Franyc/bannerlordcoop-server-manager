# Bannerlord Coop Server

Install and run a **Mount & Blade II: Bannerlord** co-op dedicated server on
your own Linux machine, and manage it afterwards with a single command.

```
sudo ./install.sh
coop status
```

> **Unofficial.** This is a third-party installer and manager. It is not made
> by, endorsed by, or affiliated with TaleWorlds Entertainment or the
> Bannerlord Coop team. The server software it installs comes from the
> [Bannerlord Coop Steam Workshop item](https://steamcommunity.com/sharedfiles/filedetails/?id=3770450698);
> all credit for the mod belongs to its authors.

---

## What it does

- **Guided install.** A read-only compatibility check first, a report, and
  nothing touched until you agree. Then three questions and a Steam login.
- **Runs the server in Docker.** The dedicated server is a Windows binary;
  it runs under Wine inside a container so nothing lands on your host.
- **Shuts down properly.** Stopping sends `stop` to the server console and
  waits for the closing save, rather than killing the process mid-write.
- **Backs up on a schedule.** Saves, server settings and gameplay settings
  as one archive - and skips the run entirely when nothing has changed.
- **Updates with a way back.** Pre-update backup, a kept copy of the
  previous build, and an automatic rollback if the new one will not start.
- **Restores as a transaction.** A restore is validated, staged, and swapped
  in - never unpacked over your campaign and left half-finished.
- **Scriptable.** Every command that reports something supports `--json`,
  exit codes distinguish failure classes, and `--non-interactive` never
  hides a prompt.

## Requirements

| | |
|---|---|
| Architecture | **x86_64 only.** The server is a Windows x64 binary run under Wine; arm64 would need an emulation layer this installer will not set up. |
| Operating system | A Linux distribution with a current Docker Engine and systemd - see below |
| CPU | **2 cores minimum, 4 recommended.** The server uses about 1.2 cores even with nobody connected - it does not idle down. |
| Memory | 4 GB minimum, 8 GB recommended (the server uses 0.9-1.6 GB) |
| Disk | 25 GB minimum, 40 GB recommended. The game files occupy about 18 GB across three directories, plus backups. |
| Network | UDP 4200 reachable from the internet |
| Steam | An account that **owns Mount & Blade II: Bannerlord**. The Workshop download is not available anonymously. |

Docker Engine, the Compose plugin and a handful of standard tools are
installed for you if they are missing.

### Supported Linux versions

| Distribution | Status |
|---|---|
| Ubuntu 26.04 LTS | Supported, tested |
| Debian 13 | Supported, tested |
| Ubuntu 22.04 / 24.04 LTS | Supported |
| Debian 12 | Supported |
| Rocky, AlmaLinux, RHEL 9+ | Experimental |
| Fedora | Experimental |
| Anything older than the above | Unsupported |

Two of those have actually been installed on; the rest share their package
sources. [INSTALLATION.md](docs/INSTALLATION.md) says which is which.

The host distribution matters less than it might seem: Wine, the .NET
runtime and the game all live inside the container. What the host has to
provide is x86_64, Docker and systemd. `coop install` checks your system
and tells you where you stand before changing anything.

## Quick start

```bash
git clone https://github.com/PlodyIce/bannerlordcoop-server-manager
cd bannerlordcoop-server-manager
sudo ./install.sh
```

The installer walks through eight steps, asks for a campaign name, a server
password and your Steam login, and downloads about 6 GB. When it finishes:

```bash
coop status
```

Players connect with **Direct Connect** to `<your-server-ip>:4200`.

### Default setup

The recommended path. Two questions and a Steam login; everything else uses
values chosen from a server that has been running in production.

```
[3/8] Campaign

  Campaign name: My Campaign
  Server password (empty for none): ********
```

The campaign name is the one answer that changes the outcome: if a save of
that name exists it is loaded, otherwise a new world is created under it.

> There is no "server name" and no "maximum players" setting, because the
> dedicated server does not have either. `server-config.json` has nine
> fields and neither is among them. `SERVER_LABEL` names the server in
> `coop status` and in backups, but players never see it.

### Advanced setup

```bash
sudo ./install.sh --advanced
```

Adds the installation directory, instance id, ports, install channel,
autosave interval, time zone, memory limit, backup schedule and retention,
and the update policy.

### Unattended install

Both modes feed the same engine, so automation uses the same code path a
person does:

```bash
sudo coop install --default --non-interactive --yes \
     --save-name "Customer Campaign" \
     --server-password "s3cret" \
     --game-port 4210
```

Steam Guard cannot be answered without a terminal, so authenticate once
first - after that the session is reused and nothing prompts:

```bash
sudo coop steam login
```

## Steam authentication

Downloading the Workshop item requires a Steam account that owns Bannerlord.
The password is **never handled by this installer**: the terminal is handed
to SteamCMD, which asks for the password and the Steam Guard code itself.
What persists afterwards is Steam's own session under `state/steam`.

```bash
coop steam status     # is the session still good?
coop steam login      # authenticate (once)
coop steam logout     # discard the session
```

More in [docs/STEAM.md](docs/STEAM.md).

## Commands

| Command | Description |
|---|---|
| `coop install` | Install a server on this host |
| `coop status` | Show what the server is doing |
| `coop start` / `stop` / `restart` | Start or stop, with a closing save |
| `coop save` | Force a save and wait for it |
| `coop console <command>` | Send a command to the server console |
| `coop logs [--follow]` | Show the server log |
| `coop config` | Edit common settings |
| `coop config --list` | Show every setting and its value |
| `coop config --set KEY=VALUE` | Change one setting |
| `coop update [--check]` | Install, or check for, a newer Coop build |
| `coop rollback` | Go back to the previous Coop build |
| `coop backup [--note "..."]` | Create a backup now |
| `coop backup list` | List backups |
| `coop backup info <id>` | Show what is in one |
| `coop backup restore [<id>]` | Restore saves and configuration |
| `coop import-save <dir>` | Import campaign saves from a directory |
| `coop steam status\|login\|logout` | Manage the Steam session |
| `coop doctor` | Check the installation and say what is wrong |
| `coop version` | Manager and Coop versions, reported separately |

Full reference: [docs/CLI.md](docs/CLI.md).

## Configuration

Everything lives in one file, and it is meant to be edited by hand:

```
/srv/bannerlordcoop/config/server.env
```

```bash
coop config --list             # every setting, value and type
coop config --set GAME_PORT=4210
coop config --apply            # regenerate and restart if needed
```

Any setting is also a command-line flag, derived from its name:
`--save-name`, `--game-port`, `--backup-keep-auto`.

The file is **parsed, never executed**. A value is a value, even if it looks
like a shell command - which is what makes it safe for a provisioning system
to write.

Every setting, its default and whether it needs a restart:
[docs/CONFIGURATION.md](docs/CONFIGURATION.md).

## Important files and directories

Everything below sits under the installation directory, `/srv/bannerlordcoop`
by default.

| Path | Purpose | In a backup? |
|---|---|---|
| `config/server.env` | Your settings. **Contains the server password.** | Yes |
| `config/server-config.json` | Generated for the server. Do not edit. | Yes |
| `config/compose.env` | Generated for Docker Compose. Do not edit. | No |
| `saves/` | Campaign saves (`.sav` with a matching `.json`) | Yes |
| `coopdata/mod-config.json` | Gameplay settings, owned by the mod | Yes |
| `backups/` | Backup archives and their manifests | — |
| `logs/` | Server logs and the manager's own log | No |
| `state/` | Installation metadata, Steam session | No |
| `server/` | The active server files, mounted read-only | No |
| `workshop/` | Raw Steam Workshop download | No |
| `rollback/` | The previous build, kept for `coop rollback` | No |

The split between `workshop/`, `server/` and `rollback/` is deliberate: a
download can never quietly change the running installation, and a rollback
is a directory swap instead of a 6 GB download.

## Updates

```bash
coop update --check     # is there a new build?
coop update             # install it
coop rollback           # go back
```

An update stops the server cleanly, backs up, keeps a copy of the current
build, downloads, starts, and **rolls back by itself if the new build will
not serve**.

A scheduled check runs nightly and only reports. Automatic installation is
off by default on purpose: the server verifies its Coop assemblies and every
player has to run the same build, so an unattended update would lock out
anyone who has not updated their client. Turn it on with
`coop config --set AUTO_UPDATE=true` if that trade suits your group.

Details: [docs/UPDATES.md](docs/UPDATES.md).

## Backups

Automatic, hourly, and free when nothing happened - with no players
connected the campaign is paused and the save is unchanged, so the run is
skipped.

```bash
coop backup --note "before the siege"
coop backup list
coop backup restore 20260911-004626
```

Each archive holds the campaign, the server configuration and the gameplay
configuration together, because only all three make a playable state.

**Copy backups off this machine.** A backup that only exists on the server
you are protecting is not a backup:

```bash
scp your-server:/srv/bannerlordcoop/backups/auto-*.tar.gz ~/backups/
```

Details: [docs/BACKUPS.md](docs/BACKUPS.md).

## Firewall

Only **UDP 4200** has to be reachable. Two things catch people out:

- **Docker publishes ports past `ufw`.** A `ufw deny` rule does not close a
  published container port. Do not rely on it.
- **Your provider probably has its own firewall** in front of the machine.
  That one does work, and it is where to allow UDP 4200.

## Troubleshooting

Start here:

```bash
coop doctor
```

It checks the system, Docker, the configuration, the data directories, the
Steam session, the server process and the backups, and each failing line
says what to do. [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) covers
the specific symptoms.

## Documentation

| | |
|---|---|
| [INSTALLATION.md](docs/INSTALLATION.md) | Requirements, preflight, both setup modes, first start |
| [CONFIGURATION.md](docs/CONFIGURATION.md) | Every setting, default and restart requirement |
| [CLI.md](docs/CLI.md) | Every command, flag and exit code |
| [STEAM.md](docs/STEAM.md) | Why an account is needed, Steam Guard, sessions |
| [UPDATES.md](docs/UPDATES.md) | Update flow, rollback, why updates are manual |
| [BACKUPS.md](docs/BACKUPS.md) | Contents, types, retention, restore |
| [SAVE-MIGRATION.md](docs/SAVE-MIGRATION.md) | Bringing a campaign from Windows or another host |
| [TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) | Symptom, cause, check, solution |
| [ARCHITECTURE.md](docs/ARCHITECTURE.md) | How it works, and why it works that way |
| [DISASTER-RECOVERY.md](docs/DISASTER-RECOVERY.md) | Rebuilding from nothing |

## Versioning

The manager has its own version, separate from the Coop mod:

```
$ coop version
Bannerlord Coop Server Manager v0.1.0
Installed Coop build:       build 2026-09-06 / Mount & Blade II: Bannerlord v1.4.8
```

## Status

**v0.1.0 - early.** The design is derived from a server that has been
running in production, and the risky paths - clean shutdown, save-and-wait,
backup, restore, rollback - are ported from there rather than reinvented.
The update path itself has not yet been exercised against a real Workshop
release. Watch the output the first time you run `coop update`.

## Licence

MIT. See [LICENSE](LICENSE).
