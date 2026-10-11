#!/bin/bash
# Unit tests: the pure decisions in flux-lib.sh and fluxisle.py. No Docker, no Steam, no game.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

# shellcheck source=scripts/flux-lib.sh
FLUX_LOG="" source scripts/flux-lib.sh

pass=0
fail=0
check() { # description, expected, actual
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL %s\n  expected: [%s]\n  actual:   [%s]\n' "$1" "$2" "$3"
  fi
}
status() { "$@" >/dev/null 2>&1; echo $?; }
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

check "7777 is a port" "7777" "$(flux_valid_port 7777 1)"
check "the default" "10000" "$(flux_valid_port '' 10000)"
check "80 is refused" "1" "$(status flux_valid_port 80 7777)"
check "restart time" "04:00" "$(flux_restart_time 4:00)"
check "a crash counts" "0" "$(status flux_restart_counts 'the server ended on its own (exit 1)')"
check "a game update does not" "1" "$(status flux_restart_counts 'planned: game update 1 -> 2')"
check "the evrima branch's build" "24664709" "$(printf '%s\n' '"branches"' '{' '"public"' '{' '"buildid"		"7"' '}' '"evrima"' '{' '"buildid"		"24664709"' '}' | flux_public_build evrima)"

data="${tmp}/data"
isle() {
  local vars=()
  while [[ "${1:-}" == *=* ]]; do vars+=("$1"); shift; done
  env -i PATH="${PATH}" FLUX_DATA_DIR="${data}" FLUX_SERVER_DIR="${tmp}/server" "${vars[@]}" python3 scripts/fluxisle.py "$@"
}
ini="${data}/Saved/Config/LinuxServer/Game.ini"
iniv() { sed -n "s/^$1=//p" "${ini}"; }

isle ISLE_SERVER_NAME="My Isle" ISLE_MAX_PLAYERS=75 ISLE_ADMINS="76561197960287930, bad" apply >/dev/null
check "the name" "My Isle" "$(iniv ServerName)"
check "players" "75" "$(iniv MaxPlayerCount)"
check "the only map" "Gateway" "$(iniv MapName)"
check "RCON on, with a made-up password" "true 32" "$(iniv bRconEnabled) $(iniv RconPassword | tr -d '\n' | wc -c)"
check "the RCON password is kept" "$(iniv RconPassword)" "$(isle rcon-password)"
check "no password: bServerPassword off" "false" "$(iniv bServerPassword)"
check "admins: only SteamID64s, one line each" "76561197960287930" "$(iniv AdminsSteamIDs)"
check "every playable class by default" "20" "$(grep -c '^AllowedClasses=' "${ini}")"
check "a bad env value falls back" "50" "$(isle ISLE_MAX_PLAYERS=lots apply >/dev/null; iniv MaxPlayerCount)"

check "the panel takes settings" "0" "$(status isle set-settings '{"password": "pw1", "aiDensity": "0.5", "playables": ["Triceratops", "Omniraptor"], "disallowedAI": "Compsognathus, Boar"}')"
isle apply >/dev/null
check "the password" "pw1 true" "$(iniv ServerPassword) $(iniv bServerPassword)"
check "AI density" "0.5" "$(iniv AIDensity)"
check "classes from the panel" "Triceratops Omniraptor" "$(iniv AllowedClasses | tr '\n' ' ' | sed 's/ $//')"
check "AI classes on one line" "Compsognathus,Boar" "$(iniv DisallowedAIClasses)"
check "the env wins" "secret" "$(isle ISLE_PASSWORD=secret apply >/dev/null; iniv ServerPassword)"
check "settings never show an env password" "(set in Deployment Settings)" "$(env ISLE_PASSWORD=x FLUX_DATA_DIR="${data}" python3 scripts/fluxisle.py settings | python3 -c 'import json,sys;print(json.load(sys.stdin)["values"]["password"])')"
check "nor the panel one in panel" "False" "$(isle settings | python3 -c 'import json,sys;print("password" in json.load(sys.stdin)["panel"])')"
check "a bad admin is refused" "2" "$(status isle set-settings '{"admins": ["123"]}')"
check "a bad class is refused" "2" "$(status isle set-settings '{"playables": ["T-Rex;drop"]}')"
check "an unknown setting is refused" "2" "$(status isle set-settings '{"pvp": true}')"
check "players out of range" "2" "$(status isle set-settings '{"maxPlayers": 999}')"

# What the server wrote is kept, unless it is one of our keys.
printf ';METADATA=(Diff=true, UseCommands=true)\n[/Script/TheIsle.TIGameSession]\nServerName=Old\nbEnableSpawnCodes=False\nSomethingNew=1\n[/Script/Other]\nX=1\n' >"${ini}"
isle apply >/dev/null
check "the server's metadata line is kept" "1" "$(grep -c '^;METADATA' "${ini}")"
check "an unknown key is kept" "1" "$(iniv SomethingNew)"
check "another section is kept" "1" "$(iniv X)"
check "our key replaces theirs, once" "1" "$(grep -c '^ServerName=' "${ini}")"

# RCON replies.
py() { PYTHONPATH=scripts python3 -c "import fluxisle as t; $1"; }
check "an empty player list" "[]" "$(py 'print(t.parse_players("PlayerList\n\n"))')"
check "players" "76561197960287930:Rex 76561197960287931:Bob the Raptor" "$(py 'print(" ".join(p["id"]+":"+p["name"] for p in t.parse_players("PlayerList\n76561197960287930,\nRex,\n76561197960287931,\nBob the Raptor,\n\n")))')"
check "the queue" "True 3 1" "$(py 'q=t.parse_queue("[2026.10.11-13.38.51] QueueEnabled: true, QueueLength: 3, PendingConnections: 1"); print(q["enabled"], q["length"], q["pending"])')"
check "the timestamp is taken off" "Game saved" "$(py 'print(t.strip_stamp("[2026.10.11-13.38.51] Game saved"))')"

# Bans.
mkdir -p "${data}/Saved/PlayerData"
printf '[{"SteamId": "76561197960287930", "Reason": "x"}, {"SteamId": "76561197960287931"}]' >"${data}/Saved/PlayerData/PlayerBans.json"
check "unban needs a SteamID64" "2" "$(status isle unban 123)"
isle unban 76561197960287930 >/dev/null
check "is pending" "True" "$(isle status | python3 -c 'import json,sys;print(json.load(sys.stdin)["pending"])')"
isle apply >/dev/null
check "and lifted on the next start" "76561197960287931" "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))[0]["SteamId"])' "${data}/Saved/PlayerData/PlayerBans.json")"

printf '\n%d passed, %d failed\n' "${pass}" "${fail}"
[ "${fail}" = "0" ]
