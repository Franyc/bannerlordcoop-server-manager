# Architecture

How this works, and why it works that way. The figures below come from
running servers on Ubuntu 26.04 and Debian 13, not from documentation.
They are recorded so that anyone tempted to simplify something can see
what it was protecting against.

## The layers

```
Host: Linux, x86_64, headless
 |
 +-- systemd            two timers: backup, update check
 +-- /usr/local/bin/coop -> bin/coop in the checkout
 +-- Docker Engine
     |
     +-- container "bannerlordcoop-<instance>"   long-running
     |   +-- Debian + WineHQ (amd64 + i386)
     |       +-- wine BannerlordCoopServer.exe --data-dir Z:\data
     |
     +-- steamcmd container                       throwaway, on demand

/srv/bannerlordcoop: persistent, outside the container
    server/     -> /server  (read-only)
    config/     -> /data
    saves/      -> /data/Game Saves
    logs/       -> /data/logs
    coopdata/   -> the Bannerlord user folder inside the Wine prefix
    workshop/  state/  rollback/  backups/
```

The container is disposable. Every piece of state lives on the host and is
bind-mounted in, so the image can be rebuilt at any time without risking a
campaign.

## Wine is required

The dedicated server ships as a **Windows x64** build. `release-info.txt`
in the Workshop item says so, and `engine/bin/` contains only
`Win64_Shipping_Server`. There is no Linux build.

The case is friendlier than it sounds. The server is a pure console process
with no graphics, and it brings its own self-contained .NET 6 runtime. No
Steam client is needed at runtime. So the image needs a slim Wine with no
Mono, no Gecko and no X server.

**i386 is not optional.** WineHQ packages `winehq-stable` with a hard
dependency on `wine-stable-i386`, even for a pure win64 application.

This is also why arm64 is unsupported: running a Windows x64 binary there
would need box64 or FEX on top of Wine. That is exactly the kind of
dependency layering this project refuses to perform, so the architecture
check rejects it up front rather than half-working.

## The container must not be stopped by signal

Stopping the container with a signal does not work. `docker compose stop`
runs into its 120 second timeout and ends in exit 137, a SIGKILL, possibly
in the middle of writing a save.

PID 1 ignores signals without a handler of its own, and Wine does not
forward them to the Windows process.

The server does have a console:

```
status  players  save  say  kick  stop  help
```

So `docker/entrypoint.sh` attaches a FIFO to the server's stdin, traps
SIGTERM, and writes `stop`. Measured result: **2 seconds, exit 0, closing
save written**.

The same channel carries commands from outside:

```bash
docker exec bannerlordcoop-default coop-cmd save
```

```bash
coop console players
```

`stop_grace_period` in `compose.yaml` is 180s, deliberately longer than the
entrypoint's own 150s timeout, so Docker never loses patience first.

## Knowing what the server is doing

Two things the server publishes, both discovered by reading its output.

**Structured events**, one JSON object per line behind an `@DS@` prefix:

```
@DS@{"ev":"state","phase":"serving","save":"Campaign","pw":true}
@DS@{"ev":"players","list":[]}
```

`phase` is `boot`, `loading` or `serving`. `wait_serving()` is built on it.

**A pulse line**, refreshed on every campaign tick:

```
pulse: time=Spring 1, 1095 timeMode=Stop players=0 parties=1954
```

Both are read from the logs of the **current container start only**. A
`serving` line left over from a previous run would make a failed start look
successful. That is a failure mode worth preventing once rather than
debugging twice.

## Server exit codes

| Code | Meaning |
|---|---|
| 0 | Clean shutdown |
| 2 | Load error or timeout |
| 3 | Runtime failure |
| 4 | Module verification failed: files under `Modules/Coop` were modified |

Exit 4 is why `/server` is mounted **read-only**: the server checks its
Coop assemblies with SHA-256 and refuses to start if they differ. What
cannot be written cannot drift.

## Waiting properly

Two places where a fixed `sleep` would be the weakest link in the chain:

- **`server_save()`** triggers a save and then watches the modification
  time of the `.sav` file until it actually changes. The whole backup
  guarantee rests on this.
- **`server_start()`** waits for `phase=serving`, not for the container to
  be up. Loading a grown campaign takes about two minutes.

## Three copies of the game files

```
Steam Workshop --steamcmd--> workshop/ --rsync--> server/ --ro-mount--> container
                                                     |
                                    before an update: rsync --> rollback/
```

This costs about 18 GB, and buys two things: a download can never quietly
change the running installation, and a rollback is a directory swap rather
than a six-gigabyte download at the worst possible moment.

## mod-config.json does not follow `--data-dir`

Configuration, saves and logs land in the mounted volumes because of
`--data-dir Z:\data`. **`mod-config.json` does not.** It follows
Bannerlord's own user folder inside the Wine prefix:

```
C:\users\coop\Documents\Mount and Blade II Bannerlord\CoopData\mod-config.json
```

Without its own bind mount it would be lost on every container rebuild.
That is what the `coopdata/` mount is for, and why an update compares its
checksum before and after.

## Configuration is data

`config/server.env` is parsed line by line and never sourced. Keys are
whitelisted, values are validated by type, and nothing is executed.

The reason is not tidiness. The interactive installer and a provisioning
backend write the same file through the same code, and the backend writes
values it did not author. `SAVE_NAME=$(rm -rf /)` has to be a campaign with
an unfortunate name, not a command.

`server-config.json` is **generated** from a template rather than edited in
place. It is JSONC, with comments and trailing commas, so `jq` cannot read
it, and patching it with a regular expression is how a campaign gets
lost. Substitution is literal, because `awk`'s `gsub()` treats `&` in a
replacement as a backreference and a password containing `&` would
otherwise be mangled.

## One engine, two front ends

```
collect  ->  validate  ->  summarise  ->  provision
```

The collectors (default mode, advanced mode, command-line flags, a config
file) do nothing but gather values. `provision_run()` does nothing but
apply them, and never asks a question.

```
human      -> coop install                       -> provision_run()
automation -> coop install --non-interactive ... -> provision_run()
```

Below the collection layer there is no `read`, no confirmation and no
colour. That single rule is what stops the interactive installer and a
future hosting backend from becoming two implementations that drift apart.

The Steam session is a directory, which is the other half of the same idea:
a prepared `state/steam` lets provisioning run without a terminal, because
no code path asks for a password when a session is present.

## Instances

Container name, Compose project, lock file and systemd units are all
derived from `INSTANCE_ID` and the installation path. Nothing is hardcoded
to one server, so a host can run several. That costs nothing to allow for
now and would be expensive to retrofit.

The systemd units are templates instantiated with the escaped installation
path, so `%f` gives the directory back and no separate registry of
instances is needed.

## Locking

One lock per installation, not one per operation. Start, stop, update,
backup and restore all touch the same files, and an hourly backup timer
must never be able to fire in the middle of an update. A second operation
exits 70 rather than waiting.

## Measured behaviour

| | |
|---|---|
| Memory | 0.9 to 1.6 GB: about 890 MB on a fresh world, 1.2 to 1.6 GB on a grown campaign |
| CPU | about 1.2 cores, with or without players (120 to 122% on Ubuntu 26.04, 121% on Debian 13) |
| Bandwidth | about 58 KB/s per player |
| Campaign load time | about 50 seconds for a fresh world, about 2 minutes for a grown save |
| Workshop item | about 6.1 GB |
| Backup archive | 12-25 MB, depending on how grown the campaign is |
| Clean shutdown | 2 seconds |

With no players connected the campaign pauses on its own, so the server can
be left running around the clock. An hourly backup of an idle server is
skipped, but the test for "idle" has to be the campaign date rather than
the save file: the server autosaves every few minutes regardless, so the
file changes even while the world stands still.

**The process does not idle down, though.** Measured over five samples on a
four-core machine with nobody connected and the campaign paused: 120-122%
CPU, steady. That is the server's own loop, not the campaign, and it is why
the requirements ask for two cores rather than one. A single-core host is
saturated before the first player joins.

## Harmless log messages

- `Cannot load: GameInterface.dll` and similar right at startup. The server
  looks in the default location first; `coop assembly resolver installed`
  follows immediately.
- `Could not find the event index for: event:/...` is a sound definition,
  meaningless on a headless server.
- `The 'coop_*' attribute is not declared` refers to the mod's own XML
  attributes, which are not in the TaleWorlds schema.
- `[Coop] ["ObjectManager"] Failed to get id ...` is a mod-internal warning
  during normal play.

## Networking

| Port | Purpose |
|---|---|
| **UDP 4200** | Direct connect. The only port that must be reachable. |
| UDP 27315/27316 | Steam game-server session, local only |

Port 7210, which appears in some guides, belongs to the standard TaleWorlds
multiplayer and is irrelevant here.

**Docker publishes ports past `ufw`.** Docker inserts its own chains ahead
of ufw's in `FORWARD`, so `ufw deny <port>` has no effect on a published
container port. Only a firewall in front of the machine, such as your
provider's, reliably closes one. If you ever need to restrict a container
port by source address, the `DOCKER-USER` chain is the right place.
