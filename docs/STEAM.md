# Steam

## Why an account is needed

The Bannerlord Coop dedicated server is distributed as a Steam Workshop
item. Workshop downloads are **not available anonymously**: SteamCMD has to
be logged in as an account that owns Mount & Blade II: Bannerlord.

There is no way around that, and this project does not try to find one.

## Your password never reaches this software

The obvious implementation would prompt for the password and pass it to
`steamcmd +login user password`. That would put the password in the
container's command line, where `ps` and `docker inspect` can read it.

So the terminal is handed to SteamCMD instead. It asks for the password and
the Steam Guard code itself, and the manager never sees either:

```
$ sudo coop steam login

Steam authentication

  Downloading the Bannerlord Coop Workshop item requires a Steam account
  that owns Mount & Blade II: Bannerlord. Anonymous access does not work.

  SteamCMD will now ask for the password and, if the account has Steam
  Guard enabled, for a code. It asks directly - the password is not
  handled by this installer and is never written anywhere.
```

What is stored afterwards is Steam's own session:

```
/srv/bannerlordcoop/state/steam/
```

No password, and no token invented by this project - just the files Steam
writes for itself. Only the account **name** is saved, in `server.env`, so
later downloads know which session to use.

## Steam Guard

Steam Guard is respected exactly as it is. Codes are not stored, cached or
worked around. That has one practical consequence:

**The first authentication needs a terminal.** After that the session is
reused and nothing prompts, which is what lets updates and unattended
installs run on their own.

## Checking the session

```bash
coop steam status
```

```bash
coop steam status --probe
```

| Result | Meaning |
|---|---|
| `absent` | No session at all. Run `coop steam login`. |
| `present` | Session files exist but were not verified |
| `valid` | Steam accepted the session (`--probe` only) |
| `expired` | Steam rejected it. Run `coop steam login`. |

The offline check is instant and good enough for `coop doctor`. `--probe`
runs a login-and-quit against Steam - a few seconds, no download - which is
the only way to tell `present` from `expired` for certain.

## When a session expires

Downloads fail with a clear message and exit code 30:

```
  x The Steam session has expired.
    Re-authenticate once, then retry: coop steam login
```

Log in again and repeat what you were doing.

## Automation

The download step never prompts. If there is no usable session it fails
with exit 30 and says what to run. That is deliberate: a scheduled update
must not sit waiting for input that will never come.

The session being a plain directory is what makes unattended provisioning
possible. A prepared `state/steam` is all an automated install needs:

```bash
sudo coop steam login
```

```bash
sudo coop install --default --non-interactive --yes --save-name "Campaign"
```

## Signing out

```bash
sudo coop steam logout
```

Removes the stored session. The next download will ask you to log in again.

## Workshop identifiers

| | |
|---|---|
| Bannerlord app ID | `261550` |
| Bannerlord Coop Workshop item | `3770450698` |
| Download size | about 6 GB |

Both are settings (`WORKSHOP_APP_ID`, `WORKSHOP_ITEM_ID`) rather than
constants in the code, so a different item can be installed without
changing anything.

## SteamCMD runs in a container

SteamCMD is not installed on your host. It runs as a throwaway container
from the image named by `STEAMCMD_IMAGE`, with two volumes: the session and
the download directory. Nothing else on the host is touched.

That container runs as root, which is how the SteamCMD image is built, so
the manager hands ownership of both directories back to the service user
after every run.

For reproducible installs, pin the image to a digest:

```bash
coop config --set STEAMCMD_IMAGE="steamcmd/steamcmd@sha256:..."
```
