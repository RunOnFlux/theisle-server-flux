# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A **Docker image repo**, not an application: The Isle (Evrima) dedicated server for Flux,
`runonflux/theisle-server-flux`. steamcmd/steamcmd:ubuntu-24, the game's Linux server, and a
supervisor in bash. Same family as `~/work/corekeeper-server-flux`; read it for the patterns.

PID 1 is `flux-entrypoint.sh`, never the game.

## Commands

```bash
./tests/test-flux.sh
docker build -t theisle-server-flux:local .
./tests/test-image.sh
docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:stable -x scripts/*.sh tests/*.sh tests/image/*.sh
```

A change to what the image does bumps `VERSION` and gets a line under "Versions" in the README.

## Things that will bite you

- **Never publish the RCON port.** It authorises an IP address after one right password, not a
  connection. The hub's exec reaches it on 127.0.0.1.
- **`ServerDetails` (0x12) prints the join password.** Not offered by `flux-isle rcon`.
- **`-beta evrima` always**: the default branch is the 2022 Legacy game, with no Linux server.
- **The EOS dedicated-server client id/secret are required**, or the server never finishes
  starting ("Unable to initialize EOS platform").
- **Not as root.** The server runs as uid 1000 through `setpriv`; Saved/ is chowned every start.
- **The server rewrites Game.ini.** `apply` writes only our keys and keeps every other line.
- **Bans are in hours; 0 expires at once.** `PlayerBans.json` is the server's while it runs:
  unbans are applied before the next start.
- **Readiness = the RCON answering**, not a log line.
