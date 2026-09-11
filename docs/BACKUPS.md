# Backups

## What is in a backup

Three directories, always together, because only together do they make a
playable state:

| | |
|---|---|
| `saves/` | The campaign: a `.sav` file with its matching `.json` |
| `config/` | `server.env` and the generated `server-config.json` |
| `coopdata/` | `mod-config.json`, the gameplay settings owned by the mod |

Plus two descriptions of the archive itself: `manifest.json` for machines
and `BACKUP-INFO.txt` for people.

Everything else - the server files, the Workshop download, the rollback
copy, the container image - can be produced again from Steam and this
repository. These three cannot.

> **A backup archive contains `server.env`, and therefore your server
> password.** Archives are written with mode `0600`. Treat them as secrets.

## Creating one

```bash
coop backup
```

```bash
coop backup --note "before the siege of Rhesos"
```

The note is stored in the manifest and shown in the listing, which is what
makes a backup findable three weeks later.

If the server is running and serving, a save is **forced first** and the
manager waits for the file on disk to actually change - not for a fixed
number of seconds. Without that the backup would capture the last autosave
rather than the current state.

## Automatic backups

Enabled by default, hourly, through a systemd timer.

```bash
coop config --set BACKUP_SCHEDULE="hourly"
coop config --set BACKUP_ENABLED=false
```

The schedule is any systemd `OnCalendar` expression. It is written into a
drop-in file, so upgrading the manager does not discard your choice.

The timer uses `Persistent=true`, so a run missed while the machine was off
is caught up, and a randomised delay of up to five minutes, so it does not
collide with the server's own autosave.

### Why hourly is cheap

With nobody connected, the campaign pauses on its own and the save file is
byte-identical from one hour to the next. The automatic run checks both
conditions - no players, unchanged save - and skips entirely:

```
Automatic backup skipped: the campaign is unchanged and nobody is connected.
```

So an idle server costs one checksum per hour rather than 33 MB.

## Backup types

The reason a backup exists determines how long it is kept.

| Type | Created by |
|---|---|
| `auto` | The scheduled timer |
| `manual` | `coop backup` |
| `pre-update` | Automatically, before `coop update` |
| `pre-restore` | Automatically, before `coop backup restore` |

## Retention

Three limits, applied in that order:

1. **Count, per type.** `BACKUP_KEEP_AUTO` (48), `BACKUP_KEEP_MANUAL` (20),
   `BACKUP_KEEP_PREUPDATE` (10), `BACKUP_KEEP_PRERESTORE` (10).
2. **Age.** `BACKUP_MAX_AGE_DAYS` (30). Automatic backups only.
3. **Total size.** `BACKUP_MAX_TOTAL_GB` (20). Automatic backups only,
   oldest first.

Manual and pre-restore backups are only ever removed by their own count
limit. An aggressive size cap must not be able to delete the safety copy
you took deliberately before a restore.

At roughly 33 MB per archive, the defaults keep two days of hourly history
plus everything you asked for by hand.

## Listing

```bash
$ coop backup list

Backups

#  ID               CREATED           TYPE        SIZE   NOTE
1  20260911-004626  2026-09-11 00:46  auto        33 MB
2  20260910-180000  2026-09-10 18:00  pre-update  32 MB  before Workshop update
3  20260910-124100  2026-09-10 12:41  manual      31 MB  before the siege

  Restore with: coop backup restore <ID>
```

For scripts:

```bash
coop backup list --json | jq -r '.backups[] | select(.type=="manual") | .id'
```

## Inspecting one

```bash
coop backup info 20260911-004626
```

Shows the manifest - campaign name, campaign date, Coop build, manager
version - and every save inside the archive, without unpacking anything.

## Restoring

```bash
coop backup restore 20260911-004626
```

```bash
coop backup restore 20260911-004626 --non-interactive --yes
```

### Restore is a transaction

Unpacking an archive over a live installation would leave a mixture of old
and new campaign files if anything went wrong halfway through. So:

1. The archive is resolved **within the backup directory only** - never
   from an arbitrary path.
2. It is validated: a readable gzip tar, no absolute or traversing paths,
   no entries outside `saves/`, `config/` and `coopdata/`, and a `saves/`
   directory that actually exists.
3. It is unpacked into a staging directory **on the same filesystem**, so
   the step below is a rename rather than a copy.
4. The contents are checked against the manifest.
5. The server is stopped cleanly.
6. A `pre-restore` safety backup of the current state is created.
7. The directories are **swapped by renaming**. Instant, and reversible.
8. Ownership is set from this host.
9. The configuration is reloaded and the generated files rewritten.
10. The server is started and has to reach "serving".

If a rename fails partway through, the ones already done are undone and the
previous state is put back. There is no half-restored outcome.

### Ownership

Step 8 matters more than it looks. A tar archive carries the numeric user
and group IDs of the machine it was made on. Restoring onto a host where
the service user has a different ID would leave the campaign unreadable to
the container. The manager therefore sets ownership from the current
installation and ignores what the archive says.

## Copying backups off the machine

A backup that only exists on the server you are protecting is not a backup.

```bash
scp your-server:/srv/bannerlordcoop/backups/auto-*.tar.gz ~/backups/
```

Do this regularly. Everything else in a Bannerlord Coop installation can be
rebuilt from Steam and this repository; the campaign cannot.

## Emergency recovery by hand

The archive is an ordinary `tar.gz`. If the manager is unavailable, with
the server stopped:

```bash
tar -xzf backup-20260911-004626.tar.gz -C /srv/bannerlordcoop saves config coopdata
```

```bash
chown -R bannerlordcoop:bannerlordcoop /srv/bannerlordcoop/saves /srv/bannerlordcoop/config /srv/bannerlordcoop/coopdata
```

Then start the server. Being able to do this without the tool is a design
goal, not an accident.

## Picking one interactively

Without an ID, the list is shown and you choose:

```
$ sudo coop backup restore

Backups

#  ID               CREATED           TYPE        SIZE   NOTE
1  20260911-004626  2026-09-11 00:46  auto        33 MB
2  20260910-180000  2026-09-10 18:00  pre-update  32 MB  before Workshop update

Select a backup by number or ID: 2
```

In `--non-interactive` mode this is an error rather than a guess: which
campaign to overwrite is not a decision a default should make.
