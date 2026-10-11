# theisle-server-flux

The Isle (Evrima) dedicated server for [Flux](https://runonflux.io), as
`runonflux/theisle-server-flux`. The game's Linux server (Steam app 412680, branch `evrima`),
installed and updated with SteamCMD on every start, run as an unprivileged user, under a
supervisor that:

- writes `Game.ini` from the environment and the hub's panel: name, players, password, queue,
  admins, whitelist, VIPs, playable classes, AI (density, classes), growth, migrations, weather,
  day length, diets, mutations, spawning... (keys the server writes itself are kept)
- keeps the **RCON private**: it is on, with a password made once and kept on the data volume,
  and reached only from inside the container (see below)
- shuts the server down cleanly on stop (SIGTERM: the player database is written; `docker stop`
  5.9 s measured)
- follows Evrima updates: warns the players over RCON for 5 minutes, then restarts onto the new
  build (an out-of-date server refuses the new client); `ISLE_RESTART_TIME` = a daily restart
- makes a backup of `Saved/` (player database, config, bans) on every start and every 6 hours
- gives the hub JSON status and RCON commands (`flux-isle`)

## Why the RCON is never published

The Isle's RCON authorises an IP ADDRESS once a password was right, not a connection: afterwards,
anyone behind that address connects with no password at all (measured). On a public port that is
an open door for anyone sharing an admin's NAT. The image never exposes it; the hub runs
`flux-isle rcon ...` inside the container, which connects to 127.0.0.1. `ServerDetails` (0x12)
prints the join password in plain text, so it is not one of the commands `flux-isle` offers.

## Volumes

| Path | Flux mount | What |
|---|---|---|
| `/mnt/isle/data` | `g:` (synced) | `Saved/` (the install's `TheIsle/Saved` links here: `PlayerData/` with the encrypted player database and `PlayerBans.json`, `Config/LinuxServer/Game.ini`, logs) and `flux/` (log, state, settings, the RCON password, backups) |
| `/mnt/isle/server` | `ml:server` (local) | the game, ~1.5 GB. Downloaded again on a new node |

Spec: `g:/mnt/isle/data|ml:server:/mnt/isle/server`.

## Ports

| Variable | Default | |
|---|---|---|
| `ISLE_PORT` | 7777/udp | the game |
| `ISLE_QUEUE_PORT` | 10000/tcp | the join queue (players wait for a slot on a full server) |

No Steam query port: the server lists itself through Epic Online Services. RCON 8888/tcp stays
inside.

## Environment

A variable that is **set** is applied on every start; one that is not set leaves the panel's
value (`flux/settings.json`), and then the default.

| Variable | Game.ini | |
|---|---|---|
| `ISLE_SERVER_NAME` | `ServerName` | |
| `ISLE_MAX_PLAYERS` | `MaxPlayerCount` | 1-300 |
| `ISLE_PASSWORD` | `ServerPassword` (+ `bServerPassword`) | empty = public |
| `ISLE_QUEUE` | `bQueueEnabled` | |
| `ISLE_DISCORD` | `Discord` | the invite players are offered |
| `ISLE_ADMINS` | `AdminsSteamIDs` | SteamID64s, comma separated |
| `ISLE_HUMANS`, `ISLE_GLOBAL_CHAT`, `ISLE_MUTATIONS`, `ISLE_WHITELIST` | `bEnableHumans`, `bEnableGlobalChat`, `bEnableMutations`, `bServerWhitelist` | |
| `ISLE_GROWTH_MULTIPLIER`, `ISLE_AI_DENSITY` | `GrowthMultiplier`, `AIDensity` | |
| `ISLE_RESTART_TIME` | | `HH:MM` (container time zone, `TZ`), a daily restart |
| `ISLE_EOS_CLIENT_ID`, `ISLE_EOS_CLIENT_SECRET` | `-ini:Engine:[EpicOnlineServices]` | the dedicated-server client every host uses (built in); without it the server never finishes starting |

The panel has every other setting: see `SETTINGS` in `scripts/fluxisle.py`.

## For the hub

| Command | |
|---|---|
| `flux-isle status` | `state`, `players` (`id`, `name`), `max_players`, `queue`, `build`, `rcon` (answering), `pending` |
| `flux-isle rcon <command> [args]` | `announce <text>`, `dm <steamid>,<text>`, `kick <steamid>`, `ban <name>,<steamid>,<reason>,<hours>`, `players`, `playerdata`, `save`, `wipecorpses`, `playables`, `addplayable`/`removeplayable <class>`, `addwhitelist`/`removewhitelist <ids>`, `togglewhitelist`, `toggleglobalchat`, `togglehumans`, `toggleai`, `togglemigrations`, `togglegrowth`, `growth <x>`, `aidensity <x>`, `disableai <classes>`, `queue` |
| `flux-isle settings` / `set-settings '<json>'` | every Game.ini setting with where its value comes from; AI density and AI classes also reach the running server |
| `flux-isle bans` / `unban <steamid>` | `PlayerBans.json`; an unban is applied on the next start (the server owns the file) |
| `flux-isle restart` | save, stop and start again |

Bans are in hours: 0 expires at once, so there is no permanent ban; use a large number.

## Measured (build 24664709)

- 1.5 GB install; Gateway loaded ~6 s after the process starts; RCON answers ~11 s in.
- 1.2-1.3 GB RAM and 5-10% of a core idle with AI on. Hosts size 8-16 GB for 25-100 players.
- The default branch (2022 Legacy) has no Linux server: `-beta evrima` always.
- The server rewrites Game.ini (adds `;METADATA=...`, drops quotes, writes RCON changes back).
- The player database (`TheIslePersistence.db`) is encrypted SQLite with a write-ahead log.

## Versions

- **1.0.0** (2026-10-11): first release.
