# Bringing an existing campaign across

You have a campaign on a Windows machine, or on another server, and you
want this installation to host it.

## What a campaign consists of

| File | Needed |
|---|---|
| `<name>.sav` | Yes. The world itself. |
| `<name>.json` | Yes in practice. Metadata; without it the server may not list the save. |
| `mod-config.json` | Optional. Gameplay settings such as difficulty and world ageing. |

The `.sav` and `.json` are a pair. Copy both.

## From a Windows machine

### 1. Make sure nothing is running

```powershell
Get-Process -Name "BannerlordCoopServer","Bannerlord" -ErrorAction SilentlyContinue
```

Copying a save out from under a running server gets you a torn file.

### 2. Back up locally first

```powershell
Compress-Archive -Path "$env:USERPROFILE\Documents\Mount and Blade II Bannerlord\CoopData" -DestinationPath "$env:USERPROFILE\Desktop\CoopData-Backup.zip"
```

### 3. Copy the saves to the server

```powershell
scp -r "$env:USERPROFILE\Documents\Mount and Blade II Bannerlord\CoopData\DedicatedServer\Game Saves" user@server:/tmp/incoming
```

If you also want your gameplay settings:

```powershell
scp "$env:USERPROFILE\Documents\Mount and Blade II Bannerlord\CoopData\mod-config.json" user@server:/tmp/incoming/
```

### 4. Verify the transfer

Worth two minutes. On Windows:

```powershell
Get-FileHash -Algorithm MD5 "$env:USERPROFILE\Documents\Mount and Blade II Bannerlord\CoopData\DedicatedServer\Game Saves\MyCampaign.sav"
```

On the server:

```bash
md5sum "/tmp/incoming/MyCampaign.sav"
```

The two must match.

### 5. Import

```bash
sudo coop import-save /tmp/incoming
```

The import:

- checks that each `.sav` has a matching `.json` and warns where one is
  missing
- shows you what it found and asks before doing anything
- stops the server cleanly
- **creates a backup first**
- copies the saves in and fixes ownership

```
Import campaign saves

  Source: /tmp/incoming

  + MyCampaign                   save and metadata present
  ! OldRun                       no matching OldRun.json, so the server may not list it

  Existing saves in /srv/bannerlordcoop/saves will be overwritten where names match.

Import these saves? [y/N]
```

### 6. Point the server at the campaign

The import does not guess which campaign you want to host:

```bash
sudo coop config --set SAVE_NAME="MyCampaign"
sudo coop start
```

### 7. Check that it is the right world

```bash
coop status
```

`Campaign` must show your campaign's date, not `Summer 1, 1084`. That is
the date of a freshly created world, so seeing it means the server started
a new game instead of loading yours. If that happens, the name in
`SAVE_NAME` does not match a file in `saves/`.

```bash
ls /srv/bannerlordcoop/saves/
```

### 8. Gameplay settings

If you brought `mod-config.json`:

```bash
sudo coop stop
sudo cp /tmp/incoming/mod-config.json /srv/bannerlordcoop/coopdata/mod-config.json
sudo chown "$(stat -c %u /srv/bannerlordcoop/saves):$(stat -c %g /srv/bannerlordcoop/saves)" /srv/bannerlordcoop/coopdata/mod-config.json
sudo coop start
```

That file belongs to the mod, so the manager backs it up and protects it
during updates, but never writes it.

### 9. Clean up

```bash
rm -rf /tmp/incoming
```

## From another Bannerlord Coop server

If the other machine runs this manager, use a backup. It carries the
saves, the server configuration and the gameplay settings together, which
is exactly the set you need:

```bash
ssh old-server "sudo coop backup --note 'migration'"
scp old-server:/srv/bannerlordcoop/backups/manual-*.tar.gz /tmp/
```

```bash
scp /tmp/manual-20260911-120000.tar.gz new-server:/srv/bannerlordcoop/backups/
ssh new-server "sudo coop backup restore 20260911-120000"
```

The restore sets file ownership from the **new** host, so a different
service user ID on the two machines is not a problem.

Note that the backup contains the old server's password in `server.env`.
Change it afterwards if that is not what you want:

```bash
sudo coop config --set SERVER_PASSWORD="new-password"
```

## Moving a save between installations on one host

```bash
sudo coop stop --instance second
sudo cp /srv/bannerlordcoop/saves/MyCampaign.* /srv/bannerlordcoop-2/saves/
sudo coop --instance second config --set SAVE_NAME="MyCampaign"
sudo coop --instance second start
```

Fix ownership if the two installations use different service users.

## If something goes wrong

The import took a backup before touching anything:

```bash
coop backup list
coop backup restore <id>
```
