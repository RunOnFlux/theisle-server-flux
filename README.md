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
- makes a backup of `Saved/` (player database, config, bans) every 6 hours and on a start when the
  newest is over an hour old, from a copy taken right after a save (the database is SQLite with a
  write-ahead log); keeps the newest 10, the newest over a day old and the newest over a week old
- restores a backup on request (`flux-isle restore`): a safety backup of the current state first
- moves a server from the previous image (ghcr.io/auhrus/theisleevrima) on its first start
- gives the hub JSON status and RCON commands (`flux-isle`)
- loads **IslePilot** (islepilot.eu, a third party's admin panel and plugin) into the server when the
  owner turns it on in the hub; off by default (see below)

## Why the RCON is never published

The Isle's RCON authorises an IP ADDRESS once a password was right, not a connection: afterwards,
anyone behind that address connects with no password at all (measured). On a public port that is
an open door for anyone sharing an admin's NAT. The image never exposes it; the hub runs
`flux-isle rcon ...` inside the container, which connects to 127.0.0.1. `ServerDetails` (0x12)
prints the join password in plain text, so it is not one of the commands `flux-isle` offers.

## Volumes

| Path | Flux mount | What |
|---|---|---|
| `/mnt/isle/data` | `g:` (synced) | `Saved/` (the install's `TheIsle/Saved` links here: `PlayerData/` with the encrypted player database and `PlayerBans.json`, `Config/LinuxServer/Game.ini`, logs) and `flux/` (state, settings, the RCON password, backups) |
| `/mnt/isle/server` | `ml:server` (local) | the game, ~1.5 GB, and our `flux-logs/flux.log` (5 MB, one `.1`). Downloaded again on a new node |

Spec: `g:/mnt/isle/data|ml:server:/mnt/isle/server`.

## Ports

| Variable | Default | |
|---|---|---|
| `ISLE_PORT` | 7777/udp | the game |
| `ISLE_QUEUE_PORT` | 10000/tcp | the join queue (players wait for a slot on a full server) |

No Steam query port: the server lists itself through Epic Online Services. RCON 8888/tcp stays
inside.

## Environment

A variable that is **set to a value** is applied on every start; one that is not set, or set
**empty**, leaves the panel's value (`flux/settings.json`), and then the default. The marketplace
writes every declared parameter, blank or not: a blank one is the panel's to decide.

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
| `flux-isle settings [password]` / `set-settings '<json>'` | every Game.ini setting with where its value comes from (the join password only with `password`); AI density and AI classes also reach the running server |
| `flux-isle bans` / `unban <steamid>` | `PlayerBans.json`; an unban is applied on the next start (the server owns the file) |
| `flux-isle restart` | save, stop and start again |
| `flux-isle backups` / `restore <name>` | the backups; a restore stops the server, keeps a `-pre-restore` backup of the current state, puts the archive in place and starts |
| `flux-isle islepilot` / `islepilot on\|off\|reset-key` | IslePilot's switch, whether the running server has it loaded, its key, build, last connection and the newest start of its log (key masked); on, off and a new key apply on the next start |

## IslePilot

[IslePilot](https://islepilot.eu) (Folgmann Studios) is a web panel, player website and Discord bot
for The Isle, driven by a plugin that runs INSIDE the game process. Off unless the owner turns it
on (`flux-isle islepilot on`, the hub's IslePilot tab). Then, on every start:

1. the newest Linux plugin is downloaded from `ISLEPILOT_URL`
   (`https://islepilot.eu/cdn/plugin/libisleplugin.so`, the URL IslePilot's own self-hosted panel
   uses) into the install, `/mnt/isle/server/islepilot/`, and checked against the `.sha256` beside
   it; IslePilot rebuilds it for every Evrima build, so it is fetched every time. A failed
   download or a wrong checksum starts the copy already on the node, or none
   (`flux/islepilot-download.json` says which)
2. `flux/islepilot/libisleplugin.so` on the data volume links to it, and the game is started with
   `LD_PRELOAD` on that link, by `env` on the game's exec only: the plugin's constructor starts a
   thread in any process that loads it. It keeps its key (`islepilot-config.json`) and log beside
   the path it was loaded from, so they are synced and the key survives a move to another node
3. the plugin prints a key (`ipk_` + 32 hex); the owner pastes it on islepilot.eu ("Add server") to
   pair. Until then IslePilot refuses its WebSocket ("Invalid key", measured)

It ends the server itself in two ways, told apart by its log: a stop asked from its panel is
"requested: from IslePilot (...)" and restarts in place uncounted; its anti-crash's exit 90 counts
towards the restart budget like any crash. It saves the players on our SIGTERM before handing it on
(the server then exits 143). Measured on build 24664709 with plugin build 4bc2a86c: loaded, hooks
resolved, key printed, the server up in the usual time. Pairing and IslePilot's features were not
tested here.

## Moving from the previous image

ghcr.io/auhrus/theisleevrima synced the whole install (`g:/home/steam/Steam/steamapps/common/The
Isle Dedicated Server`), so on a volume it leaves, the saves are at `TheIsle/Saved` and the game
(~1.5 GB) beside them. When this image's spec takes the same volume as `/mnt/isle/data`, the first
start (`fluxisle.py migrate-legacy`, idempotent):

1. backs up the old saves (`flux/backups/<date>-theisle-legacy.tar.gz`, never pruned)
2. imports the old Game.ini (and the old `additionalcommands` -ini overrides) into the panel's
   settings, for every setting the panel does not already have
3. moves `TheIsle/Saved` (player database with its WAL, Game.ini, bans) to `Saved/`; a volume that
   already holds a player database keeps it, and the old saves go to `flux/legacy-saved-<date>`
4. removes the old install (`TheIsle/`, `Engine/`, `steamapps/`, `TheIsleServer.sh`,
   `Manifest_*_Linux.txt`) from the synced volume

`flux-isle status` says `legacyData: true` while any of it is still there. The previous image never
enabled RCON (its launch line sets no `bRconEnabled`), so its published 8888 had nothing behind it.

Bans are in hours: 0 expires at once, so there is no permanent ban; use a large number.

## Measured (build 24664709)

- 1.5 GB install; Gateway loaded ~6 s after the process starts; RCON answers ~11 s in.
- 1.2-1.3 GB RAM and 5-10% of a core idle with AI on. Hosts size 8-16 GB for 25-100 players: the
  30-player plan's 6 GB fits 30 with the default AI density; a high AI density on it is the first
  thing to lower if memory runs short.
- The default branch (2022 Legacy) has no Linux server: `-beta evrima` always.
- The server rewrites Game.ini (adds `;METADATA=...`, drops quotes, writes RCON changes back).
- The player database (`TheIslePersistence.db`) is encrypted SQLite with a write-ahead log.

## Versions

- **1.1.1** (2026-10-20): flux.log moved off the synced data volume to `flux-logs/flux.log` on the local install volume (5 MB, one `.1` rotated copy; an old one on the data volume is appended there once and deleted); the FluxCloud start-up banner at container start and on every server generation; the scheduled build runs on Mondays and publishes only for an urgent security update or commits the published image does not have.
- **1.1.0** (2026-10-18): IslePilot, off by default: `flux-isle islepilot on|off|reset-key`,
  the plugin downloaded and checksummed on every start, preloaded into the game only, its key
  kept on the synced volume; IslePilot's own restarts told apart from crashes; `status` has
  `islepilot` (`enabled`, `loaded`).
- **1.0.4** (2026-10-16): the image applies Ubuntu's pending updates when it is built (`apt-get
  upgrade`), so a rebuild clears what the published image was missing; the base is pinned to the
  digest the build resolved and recorded in `org.opencontainers.image.base.digest`. The scheduled
  CI run publishes only when something is waiting (an urgent security update now, anything else
  on the first Monday of the month), since every new `:latest` restarts every server.
- **1.0.3** (2026-10-16): EnabledMutations written as the struct the game reads,
  `(MutationName="Hemomania",EffectValue=0.05)`; the "Hemomania, 0.05" form 1.0.2 wrote is refused
  by the engine ("ImportText (EnabledMutations): Missing opening parenthesis", measured on build
  24664709), and a list saved in it is read as the struct; the player list read line by line, one
  line per field with the EOS ids last, and no names at all rather than shifted ones when a name
  holds a comma; commas inside kick and ban texts become semicolons; an unban finds the id in
  either of the player's own fields; `flux-isle settings` leaves the join password out unless
  asked for (`settings password`).
- **1.0.2** (2026-10-11): the previous image's servers are moved on their first start (saves,
  settings, the old install off the synced volume); backups taken from a copy after a save, skipped
  when one is under an hour old, older generations kept; `flux-isle backups` / `restore`; an update
  that did not install is not retried for 6 hours; steamcmd waited for in the background (a stop
  during an update is clean); an empty env value leaves the panel's setting; DisallowedAIClasses
  one line per class; `[/Script/Engine.GameSession] MaxPlayers` follows the player count; an unban
  lifts exactly that player's ban; the player list reads both layouts the protocol notes allow; a
  DM's commas no longer split it; `legacyData` in status.

- **1.0.0** (2026-10-11): first release.
