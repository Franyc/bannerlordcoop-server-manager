# About this fork

This is a fork of
[PlodyIce/bannerlordcoop-server-manager](https://github.com/PlodyIce/bannerlordcoop-server-manager).
Everything upstream does still works the same way. The fork adds one thing:
**loading other Bannerlord mods on a coop dedicated server**, so a group can
play a modded campaign together.

## What may and may not be changed

Two projects are involved, under very different licenses.

| | License | In this fork |
|---|---|---|
| This manager (upstream) | MIT | Changed freely, with the original copyright kept in `LICENSE` |
| The Bannerlord Coop mod and its dedicated server | Source-available, no modification or redistribution without written permission | **Never modified, copied or shipped.** It is downloaded from the Steam Workshop on each server, exactly as upstream does |

That rule holds every change in this fork to the manager side. It is also
enough: the Coop mod already admits community modules, as long as the
server and every player run exactly the same set at exactly the same
versions. Its validator exempts only official non-DLC modules and the
dedicated server's own `DedicatedServer.*` modules. Getting the server to
load the mods, and telling players which set to run, is the manager's job.

Mods placed under `Modules/Coop` would break the server's SHA-256 check
(exit 4), so mods always go in their own module folders.

## Branches

| Branch | Purpose |
|---|---|
| `main` | Always installable. Only changed through pull requests with green CI |
| `feature/<name>` | One piece of work each, e.g. `feature/mod-loading` |
| `sync/upstream-<date>` | A merge of upstream into `main`, reviewed as a pull request |

## Keeping up with upstream

The **upstream watch** workflow runs every Monday. When upstream has commits
this fork does not, it opens an issue labelled `upstream-sync` with the
commits and the files changed on both sides. To merge:

```bash
git remote add upstream https://github.com/PlodyIce/bannerlordcoop-server-manager.git  # once
git checkout main && git pull
git fetch upstream
git checkout -b sync/upstream-$(date +%Y%m%d)
git merge upstream/main
git push -u origin HEAD
```

Then open a pull request into `main`. The issue closes itself on the next
run after the merge. Merge rather than rebase, so upstream's commits keep
their identity and the next merge stays small.

## Versions and releases

Versions are upstream's version plus a fork counter: `0.2.2-mods.1` is the
first release of this fork built on upstream 0.2.2. The counter restarts at
1 after each upstream merge that changes `VERSION`. `coop version` shows it.

To release, bump `VERSION`, commit, and push a tag with the same value:

```bash
echo 0.2.2-mods.1 > VERSION
git commit -am "Release 0.2.2-mods.1"
git tag v0.2.2-mods.1
git push origin main v0.2.2-mods.1
```

The release workflow runs the full CI suite, checks that the tag matches
`VERSION`, and publishes a GitHub release with generated notes. A version
containing `-alpha`, `-beta` or `-rc` is published as a pre-release.

## CI

Every pull request runs upstream's checks (ShellCheck, the configuration
self-checks, the unit checks, the documentation checks, the compose file)
plus actionlint on the workflow files. New scripts under `lib/` are picked
up automatically.

## Credits

The manager is the work of PlodyIce. Bannerlord Coop is the work of the
Bannerlord Coop team. Neither has endorsed this fork.
