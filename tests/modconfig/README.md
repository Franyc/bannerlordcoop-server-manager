# Gameplay configuration merge fixtures

`previous.json` is what a player had, `old-template.json` is what the
older Coop build shipped, and `new.json` is what the newer build ships.
Merging the player's file into the new template must produce:

| Setting | Expected | Why |
|---|---|---|
| `playerReceivedDamage` | `"Realistic"` | the player changed it |
| `battleSize` | `500` | the player changed it |
| `enableHeroExecutions` | `false` | the player changed it |
| `playerBattleAiJoinWindowHours` | `12` | the player changed it; the new default does not override that |
| `birthAndDeath` | `false` | kept, although the default changed: values are never replaced |
| `addedInNewBuild` | `"Balanced"` | new in this build, keeps its default |
| `goneInNewBuild` | absent | the setting no longer exists |

The report must name `addedInNewBuild` as added and `goneInNewBuild` as
removed, and every comment from `new.json` must survive - they are the
documentation for the settings.

The changed-defaults report must name `birthAndDeath` (false, now true)
and nothing else: `playerBattleAiJoinWindowHours` changed its default too,
but the player had already chosen a value of their own.

The real files use CRLF line endings, and a line that receives a value
must keep them.

Exercised by the `lint` workflow and by `tests/unit.sh`. See
`docs/UPDATES.md`.
