# Troubleshooting

Start here:

```bash
coop doctor
```

It checks the system, Docker, the configuration, the data directories, the
Steam session, the server process and the backups. Every failing line says
what to do. If that is not enough, find your symptom below.

Each entry follows the same shape: **symptom, cause, check, solution.**

---

## The installer refuses to start

### "This operating system does not provide all dependencies"

**Cause.** Your distribution is too old to supply a current Docker Engine,
or the packages the manager needs are no longer in its repositories.

**Check.**
```bash
cat /etc/os-release
```

**Solution.** Upgrade the operating system. The installer will not add
third-party repositories, download loose `.deb` files, or borrow libraries
from another release to work around it. Those are exactly the things that
turn into an unexplainable failure six months later. Nothing on your system
was changed.

### "x86_64 is required" / arm64 detected

**Cause.** The dedicated server is a Windows x64 binary run under Wine. On
arm64 that needs an x86 emulation layer as well.

**Check.**
```bash
uname -m
```

**Solution.** Use an x86_64 machine. Many inexpensive VPS offers are arm64
now; check before you buy.

### "Docker is installed but the daemon is not reachable"

**Check.**
```bash
systemctl status docker
```

**Solution.**
```bash
sudo systemctl enable --now docker
```

---

## Steam

### "Steam authentication did not complete"

**Cause.** Wrong password, a Steam Guard code that was not entered or had
expired, or an account without Bannerlord.

**Check.** Can you sign in to the same account in the Steam client?

**Solution.**
```bash
sudo coop steam login
```

Steam Guard codes are short-lived. If you were slow, ask for a new one.

### "The Steam session has expired"

**Cause.** Steam sessions do not last forever, particularly after a
password change or a sign-out-everywhere.

**Check.**
```bash
coop steam status --probe
```

**Solution.** Log in once more, then repeat what you were doing. Exit code
30 always means Steam.

### "The Workshop download failed"

**Cause.** Steam unreachable, the item unavailable, or the account does not
own Bannerlord.

**Check.**
```bash
curl -sS -o /dev/null -w '%{http_code}\n' https://api.steampowered.com/
```

**Solution.** Retry, because Steam has bad days. If it persists, verify
the account owns the game and check the manager log for SteamCMD's own
output:

```bash
tail -50 /srv/bannerlordcoop/logs/manager.log
```

### Steam Guard on an automated host

**Cause.** Steam Guard needs a human. There is no way around it, and none
is attempted.

**Solution.** Authenticate once interactively. The session is then reused,
and everything else runs unattended:

```bash
sudo coop steam login
```

---

## The server will not start

### It stops immediately, exit 4

**Cause.** The Coop assemblies do not match the release. The server
verifies them with SHA-256 and refuses to run if files under
`Modules/Coop` were modified.

**Check.**
```bash
coop logs | tail -50
```

**Solution.**
```bash
sudo coop update --force
```

or, if that build was working before:

```bash
sudo coop rollback
```

`server/` is mounted read-only precisely to prevent this, so if it happens,
something wrote to it from outside the container.

### Exit 2, the save will not load

**Cause.** A damaged or incomplete save, a missing `.json` beside the
`.sav`, or a save written by a different Coop build.

**Check.**
```bash
ls -la /srv/bannerlordcoop/saves/
```

**Solution.** Restore the last known-good backup:

```bash
coop backup list
sudo coop backup restore <id>
```

### "The server did not reach 'serving' within 600s"

**Cause.** A large campaign genuinely takes a while, but ten minutes is
beyond that.

**Check.**
```bash
coop logs --follow
```

Look for `CAMPAIGN LOADED`. If lines are still appearing, it is loading;
if the log is silent, it is stuck.

**Solution.** Restart. If it repeats, restore a backup, and check free
disk space, because a full disk produces exactly this symptom.

### "No server files found"

**Cause.** The Workshop download never completed.

**Check.**
```bash
ls /srv/bannerlordcoop/server/
```

**Solution.**
```bash
sudo coop update --force
```

---

## Players cannot connect

### Connection times out

**Cause.** Almost always the port, in one of three places.

**Check.**
```bash
coop status
```
```bash
sudo ss -lunp | grep 4200
```
From another machine:
```bash
nc -zvu your-server-ip 4200
```

**Solution.** Work through them in order:

1. **The server is running and bound.** `coop status` says ONLINE.
2. **Your provider's firewall allows UDP 4200.** This is the usual
   culprit. Note that `ufw` does *not* cover it: Docker publishes ports
   ahead of ufw's rules, so a ufw rule neither opens nor closes a
   container port.
3. **Players typed the right address.** In the co-op menu, Direct
   Connection takes one field: `ip:4200`. Port 7210 appears in some
   guides; it belongs to the standard TaleWorlds multiplayer and has
   nothing to do with this server.

### "Wrong password"

**Check.**
```bash
coop config --get SERVER_PASSWORD
```

**Solution.** Set it and restart:

```bash
sudo coop config --set SERVER_PASSWORD="the password"
```

A password change needs a restart to take effect; `coop config --set`
offers one.

### A player joins and is immediately dropped

**Cause.** Their Coop build differs from the server's.

**Check.**
```bash
coop version
```

**Solution.** Everyone must run the same build. This is also why automatic
updates are off by default. See [UPDATES.md](UPDATES.md).

---

## The campaign does not advance

### Time is frozen, `timeMode=Stop`

**Cause.** Nothing is wrong. With no players connected the campaign pauses
itself.

**Check.**
```bash
coop status
```
`Players 0`.

**Solution.** None needed. This is why an idle server is cheap to leave
running, and why an hourly backup of one costs nothing.

---

## Backups and restores

### "The archive contains unexpected entries and will not be restored"

**Cause.** The archive is not one of ours, or was modified. A restore only
accepts entries under `saves/`, `config/` and `coopdata/`, with no absolute
or traversing paths.

**Check.**
```bash
tar -tzf /srv/bannerlordcoop/backups/<file>.tar.gz | head
```

**Solution.** Use an archive made by `coop backup`. If you trust this one
and want it anyway, unpack the three directories by hand with the server
stopped. See [BACKUPS.md](BACKUPS.md).

### The server will not start after a restore

**Cause.** The restored campaign does not match the installed Coop build,
or the save itself is damaged.

**Check.**
```bash
coop logs | tail -50
```

**Solution.** The pre-restore safety backup is still there:

```bash
coop backup list
sudo coop backup restore <the pre-restore id>
```

Nothing is lost: the restore swapped directories rather than overwriting
files, and took a safety copy first.

### Backups have stopped appearing

**Check.**
```bash
systemctl list-timers 'bannerlordcoop-*'
```
```bash
journalctl -u "bannerlordcoop-backup@$(systemd-escape --path /srv/bannerlordcoop).service" -n 50
```

**Solution.** If the log says `skipped: the campaign is unchanged and
nobody is connected`, that is the design working. Otherwise:

```bash
sudo coop config --set BACKUP_ENABLED=true
sudo coop config --apply
```

### The disk is full

**Check.**
```bash
df -h /srv
du -sh /srv/bannerlordcoop/*
```

**Solution.** The game files take about 18 GB across `workshop/`,
`server/` and `rollback/`; that is the design and not waste. Tighten
backup retention instead:

```bash
sudo coop config --set BACKUP_KEEP_AUTO=24
sudo coop config --set BACKUP_MAX_TOTAL_GB=10
sudo coop backup
```

The new limits are applied on the next backup.

---

## Updates

### The update failed and rolled itself back

**Cause.** The new build did not reach "serving".

**Check.**
```bash
coop logs | tail -80
```

**Solution.** You are already back on the previous build with the server
running. Report the failure to the Coop project, and wait for the next
release. `coop update` will offer it again.

### "Could not determine whether an update exists"

**Cause.** The Steam Web API was unreachable. Exit code 30.

**Solution.** Retry later, or force it if you know an update is out:

```bash
sudo coop update --force
```

The scheduled check treats this as a normal outcome and does not mark
itself failed.

---

## Permissions

### "saves/ is owned by 0:0, expected 998:998"

**Cause.** Something wrote into the data directories as root, often an
unpacked archive or a manual copy.

**Check.**
```bash
ls -ln /srv/bannerlordcoop/
```

**Solution.**
```bash
sudo chown -R "$(coop config --get PUID):$(coop config --get PGID)" /srv/bannerlordcoop
```

`coop backup restore` sets ownership itself, which is why a backup from a
machine with different user IDs restores cleanly.

---

## Getting more detail

```bash
coop --verbose <command>
coop doctor --json | jq .
tail -100 /srv/bannerlordcoop/logs/manager.log
coop logs -n 200
journalctl -u docker -n 50
```

When reporting a problem, include `coop doctor --json` and the last 100
lines of `coop logs`. Neither contains your password, because the manager
does not log secrets.
