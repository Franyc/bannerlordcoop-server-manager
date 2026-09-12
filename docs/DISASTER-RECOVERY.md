# Disaster recovery

Rebuilding from nothing: a new machine, and a backup.

## What you need

1. This repository
2. **A backup archive** - without one, the campaign is gone
3. Steam credentials for an account that owns Bannerlord

> Everything except the backup can be produced again from Steam and this
> repository. The campaign cannot. A backup that only existed on the
> server you just lost was never a backup.
>
> ```bash
> scp your-server:/srv/bannerlordcoop/backups/auto-*.tar.gz ~/backups/
> ```
>
> Do that regularly, before you need it.

## The short version

```
fresh Linux host
      |
sudo ./install.sh          preflight, Steam, download, start
      |
copy the backup across
      |
coop backup restore <id>
      |
coop doctor
```

## 1. A new host

Any supported system from [INSTALLATION.md](INSTALLATION.md): x86_64,
Ubuntu 22.04+ or Debian 12+, 4 GB of memory, 25 GB of disk.

You do **not** need to recreate the old user accounts, match user IDs, or
reproduce the old directory layout. The installer creates its own service
user, and a restore sets file ownership from the new host.

## 2. Install the manager

```bash
git clone https://github.com/PlodyIce/bannerlordcoop-server-manager
cd bannerlordcoop-server-manager
sudo ./install.sh
```

Answer the questions with whatever you like for now - the restore will
replace the campaign name, the password and every other setting with the
ones from the backup. If you want to skip straight past them:

```bash
sudo coop steam login
sudo coop install --default --non-interactive --yes --save-name placeholder
```

This downloads about 6 GB from Steam and leaves you with a running server
hosting an empty world.

## 3. Bring the backup across

```bash
scp ~/backups/auto-20260911-004626.tar.gz your-new-server:/srv/bannerlordcoop/backups/
```

```bash
coop backup list
```

The archive appears in the listing as soon as it is in that directory -
the manager reads it, it does not have to have created it.

## 4. Restore

```bash
sudo coop backup restore 20260911-004626
```

This validates the archive, stages it, stops the server, takes a safety
backup of the empty world it is about to replace, swaps the directories in,
fixes ownership for this host, reloads the configuration, regenerates the
files the server reads, and starts again.

Your old settings - campaign name, password, port, backup policy - come
back with it, because `server.env` is part of the archive.

## 5. Verify

```bash
coop status
```

```
  Status             ONLINE
  Uptime             1m 8s
  Campaign           My Campaign  (Summer 11, 1084)
  Players            0  (1161 parties)
  Connection         UDP 4200  (password set)
  Install channel    Steam Workshop
  Coop build         build 2026-09-06 / Mount & Blade II: Bannerlord v1.4.8
```

The campaign date is the proof. `Summer 1, 1084` is the date of a freshly
created world: if you see exactly that, the server started a new game
instead of loading yours. Check that `SAVE_NAME` matches a file in
`saves/`.

```bash
coop doctor
```

## 6. Firewall and DNS

The new machine has a new address. Allow **UDP 4200** at your provider, and
tell your players the new address.

Remember that `ufw` does not govern published container ports - your
provider's firewall is the one that counts.

## If the password should change

The archive carries the old one.

```bash
sudo coop config --set SERVER_PASSWORD="new password"
```

That is a restart-required setting; the command offers one.

## No backup, but the old disk is readable

Everything that matters is three directories. Copy them off the old disk:

```
/srv/bannerlordcoop/saves/
/srv/bannerlordcoop/config/
/srv/bannerlordcoop/coopdata/
```

Then, on the new host with the server stopped:

```bash
sudo coop stop
sudo cp -a saves/. /srv/bannerlordcoop/saves/
sudo cp -a coopdata/. /srv/bannerlordcoop/coopdata/
sudo chown -R "$(coop config --get PUID):$(coop config --get PGID)" /srv/bannerlordcoop/saves /srv/bannerlordcoop/coopdata
sudo coop config --set SAVE_NAME="MyCampaign"
sudo coop start
```

Do not copy the old `config/` wholesale onto a new installation - it
contains paths and user IDs from the old host. Set the settings you care
about with `coop config --set` instead.

For saves coming from a Windows machine, see
[SAVE-MIGRATION.md](SAVE-MIGRATION.md).

## No backup, no disk

The campaign is gone. The server itself can be rebuilt in half an hour.

This is the paragraph that should send you to set up an off-host copy
now, while nothing is wrong.

## What is not worth backing up

`server/`, `workshop/`, `rollback/` and the container image all come back
from Steam and this repository. `logs/` is history, not state. `state/`
holds installation metadata and the Steam session, both of which are
recreated by an install and a login.

Only `saves/`, `config/` and `coopdata/` are irreplaceable - which is
exactly what a backup archive contains.

## Testing your recovery

An untested backup is a hope. Once, on a spare machine or a cheap VPS by
the hour:

```bash
sudo ./install.sh --default --non-interactive --yes --save-name placeholder
scp your-backup.tar.gz test-host:/srv/bannerlordcoop/backups/
sudo coop backup restore <id>
coop status
```

If the campaign date matches, your recovery works. If it does not, you have
found that out on a day when it costs you nothing.
