# Gameplay configuration merge fixtures

`previous.json` is what a player had; `new.json` is what a newer Coop build
writes. Merging the first into the second must produce:

| Setting | Expected | Why |
|---|---|---|
| `playerReceivedDamage` | `"Realistic"` | the player changed it |
| `battleSize` | `500` | the player changed it |
| `enableHeroExecutions` | `false` | the player changed it |
| `addedInNewBuild` | `"Balanced"` | new in this build, keeps its default |
| `goneInNewBuild` | absent | the setting no longer exists |

The report must name `addedInNewBuild` as added and `goneInNewBuild` as
removed, and every comment from `new.json` must survive - they are the
documentation for the settings.

Exercised by the `lint` workflow. See `docs/UPDATES.md`.
