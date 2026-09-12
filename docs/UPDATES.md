# Updates

## Two kinds of update, kept apart

| What | Source | Command |
|---|---|---|
| The Coop server build | Steam Workshop | `coop update` |
| This manager | git | `git pull`, then `coop config --apply` |

And a distinction that matters more:

| Command | Moves |
|---|---|
| `coop update` / `coop rollback` | the **software** forward or back |
| `coop backup restore` | the **saves and configuration** back |

They never touch each other's territory. An update carries your campaign
across untouched; a restore leaves the installed build alone.

## Checking

```bash
coop update --check
```

The check compares the `timeupdated` timestamp in Steam's local manifest
against the public Steam Web API. It needs no API key and no login, which
is why the scheduled check can run unattended.

```
A Workshop update is available.
  installed: 2026-09-06 14:22
  available: 2026-09-19 09:10

  Install it with: coop update
  Remember that every player needs the same Coop build.
```

### Exit codes

`coop update --check` exits **0 when the check succeeded**. Whether an
update exists is in the output, or in `.update_available` with `--json`.
That is the convention every other tool follows.

Scripts that would rather have it as an exit code:

```bash
coop update --check --exit-status
```

100 means an update is available, 0 means up to date, 30 means Steam could
not be reached.

## Installing

```bash
coop update
```

1. Check the version, and stop here if there is nothing new, unless `--force`
2. Stop the server cleanly, which writes a closing save
3. Create a `pre-update` backup
4. Copy the current build to `rollback/`
5. Download from Steam
6. Synchronise the new files into `server/`
7. Start, and wait until the server is serving clients
8. Verify that the gameplay configuration survived
9. Record the new version

**If step 7 fails, the manager rolls back by itself** and tells you so. You
are left on the previous build with the server running, not on a broken
one.

If the download in step 5 fails, the current build is simply started again
- nothing has been replaced at that point.

## Rolling back

```bash
coop rollback
```

Restores `server/` from `rollback/` and puts back the gameplay
configuration that went with that build. Campaign saves are not touched.

The rollback copy is a full directory rather than a re-download. It costs
about 6 GB of disk and turns a rollback into a rename instead of a
twenty-minute download at the worst possible moment.

A rollback copy exists from the first `coop update` onwards. Before that
there is nothing to go back to, and the command says so.

## The scheduled check

Runs nightly at 04:00 by default and **reports only**.

```bash
coop config --set UPDATE_CHECK_SCHEDULE="*-*-* 04:00:00"
coop config --set UPDATE_CHECK_ENABLED=false
```

When an update is found, a marker is written and `coop status` shows it.

If Steam cannot be reached the service exits 30, which its unit file
declares a success. An unreachable Steam API is weather, not a failure of
the timer.

## Why automatic updates are off

The server verifies its own Coop assemblies with SHA-256, and **clients
must run the same build**. An update installed overnight would lock out
every player who has not yet updated their own client. The server would be
running, and nobody could join.

So the default is to check and report, and let you install when your group
can update together.

If that trade suits you:

```bash
coop config --set AUTO_UPDATE=true
```

The scheduled check will then install updates as it finds them, with the
same pre-update backup and automatic rollback as a manual run.

## Gameplay configuration during an update

`mod-config.json` holds the gameplay settings such as difficulty, world
ageing and battle size. It belongs to the Coop mod, not to this manager.
A new build rewrites it with that build's defaults on first boot.

Neither obvious answer is right:

| | |
|---|---|
| Keep the new file | Every setting you chose is silently reset |
| Put your old file back | Settings the new build introduced are missing, and the mod re-adds them on the next boot, so the same fight happens every launch |

So the manager **merges**. The new file is the template: it brings the new
keys and the comments that document them. Every value you had set is
transplanted into it.

| Setting | What happens |
|---|---|
| In both files | Your value is kept |
| New in this build | Left at the build's default, and reported by name |
| Gone from this build | Dropped, and reported by name |

```
The new build rewrote the gameplay configuration; merging your settings back in
  + Gameplay settings carried over
    new setting, left at the new default: newSetting
    setting no longer exists in this build: wandererLimitScalesWithPlayers
    The build's own version is kept beside it:
      diff .../mod-config.json .../mod-config.json.new-from-update
```

The server is restarted afterwards, because the merged values only take
effect on the next boot.

Two safeguards. The build's own version is always kept beside yours as
`mod-config.json.new-from-update`, so nothing is lost either way. And if
the merged file does not account for every setting the new file had, it is
discarded and the build's defaults are left in place with a pointer to your
previous copy. A merge that quietly loses settings would be worse than no
merge at all.

### How the merge works

The file is JSONC, so `jq` cannot read it. It is also strictly one setting
per line, which makes a line-oriented merge both possible and safe: values
are substituted in place and every comment survives untouched. All setting
names in the file are unique, so a value is matched by name regardless of
which section it lives in.

A rollback is different: `coop rollback` puts the whole previous
`mod-config.json` back, because the older build expects exactly the keys it
shipped with.

## After updating

```bash
coop status
coop doctor
```

And tell your players to update their client. `coop version` prints the
build both sides need to match.

## Updating the manager itself

```bash
cd /path/to/bannerlordcoop-server-manager
git pull
sudo coop config --apply
```

`--apply` regenerates the files the server reads and reinstalls the systemd
units. Your `server.env` is not touched: new settings fall back to their
defaults, and settings you have changed keep your values.
