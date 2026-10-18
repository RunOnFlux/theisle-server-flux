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
check "AI classes one per line (the AMP template's format)" "Compsognathus Boar" "$(iniv DisallowedAIClasses | tr '\n' ' ' | sed 's/ $//')"
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


# --- 1.0.2 ---------------------------------------------------------------------------------------
check "the engine's player cap follows MaxPlayerCount" "75" "$(isle ISLE_MAX_PLAYERS=75 apply >/dev/null; sed -n '/^\[\/Script\/Engine.GameSession\]/,/^\[/p' "${ini}" | sed -n 's/^MaxPlayers=//p')"
isle set-settings '{"discord": "https://discord.gg/panel"}' >/dev/null
check "an EMPTY env value is unset: the panel decides" "https://discord.gg/panel" "$(isle ISLE_DISCORD= apply >/dev/null; iniv Discord)"
check "a real env value still wins" "https://discord.gg/env" "$(isle ISLE_DISCORD=https://discord.gg/env apply >/dev/null; iniv Discord)"

# Players: both layouts the protocol notes allow.
check "players, pairs" "76561197960287930:Rex 76561197960287931:Bob" "$(py 'print(" ".join(p["id"]+":"+p["name"] for p in t.parse_players("PlayerList\n76561197960287930,\nRex,\n76561197960287931,\nBob,\n\n")))')"
check "players, columns" "76561197960287930:Rex 76561197960287931:Bob" "$(py 'print(" ".join(p["id"]+":"+p["name"] for p in t.parse_players("PlayerList\n76561197960287930,76561197960287931,\nRex,Bob,\n\n")))')"
check "one player" "76561197960287930:Rex" "$(py 'print(" ".join(p["id"]+":"+p["name"] for p in t.parse_players("PlayerList\n76561197960287930,\nRex,\n\n")))')"

# Unban: exactly the banned player, never every ban an admin made.
printf '{"bannedPlayerData": [{"steamId": "76561197960287930", "playerName": "Rex", "bannerSteamId": "76561197960287999"}, {"steamId": "76561197960287999", "playerName": "Admin", "bannerSteamId": "76561197960287930"}]}' >"${data}/Saved/PlayerData/PlayerBans.json"
isle unban 76561197960287930 >/dev/null
isle apply >/dev/null
check "unban lifts only that player's ban" "76561197960287999" "$(python3 -c 'import json,sys;print(",".join(b["steamId"] for b in json.load(open(sys.argv[1]))["bannedPlayerData"]))' "${data}/Saved/PlayerData/PlayerBans.json")"

# Backups: the newest N, the newest older than a day and than a week, the legacy safety backup.
check "pruning keeps the newest 2, the newest older than a day and a week, and the legacy one" \
  "20260901-000000-theisle-legacy.tar.gz 20261004-000000-theisle.tar.gz 20261010-000000-theisle.tar.gz 20261011-000000-theisle.tar.gz" \
  "$(py '
now = 1791720000
bs = [{"name": f"202610{d:02d}-000000-theisle.tar.gz", "at": now - (11 - d) * 86400} for d in range(1, 12)]
bs.append({"name": "20260901-000000-theisle-legacy.tar.gz", "at": now - 40 * 86400})
print(" ".join(sorted(set(b["name"] for b in bs) - set(t.backups_to_prune(bs, 2, now)))))')"
check "restore refuses a path" "2" "$(status isle restore ../x.tar.gz)"
check "restore refuses a missing backup" "2" "$(status isle restore 20261011-000000-theisle.tar.gz)"
mkdir -p "${data}/flux/backups" && echo x >"${data}/flux/backups/20261011-000000-theisle.tar.gz"
check "restore of an existing backup is queued (no server running)" "next start" "$(env -i PATH="${PATH}" FLUX_DATA_DIR="${data}" FLUX_RESTORE_MARKER="${tmp}/restore" python3 scripts/fluxisle.py restore 20261011-000000-theisle.tar.gz | python3 -c 'import json,sys;print(json.load(sys.stdin)["appliesOn"])')"
check "the marker names it" "20261011-000000-theisle.tar.gz" "$(cat "${tmp}/restore")"
check "backups are listed" "20261011-000000-theisle.tar.gz" "$(isle backups | python3 -c 'import json,sys;print(json.load(sys.stdin)["backups"][0]["name"])')"

# The previous image's layout (ghcr.io/auhrus/theisleevrima synced the whole install).
old="${tmp}/old"
mkdir -p "${old}/TheIsle/Saved/PlayerData" "${old}/TheIsle/Saved/Config/LinuxServer" "${old}/TheIsle/Binaries" "${old}/Engine/x" "${old}/steamapps"
echo db >"${old}/TheIsle/Saved/PlayerData/TheIslePersistence.db"
echo wal >"${old}/TheIsle/Saved/PlayerData/TheIslePersistence.db-wal"
printf '[/Script/TheIsle.TIGameSession]\nServerName=Old Isle\nbEnableHumans=true\nAIDensity=0.4\n[/Script/TheIsle.TIGameStateBase]\nAdminsSteamIDs=76561197960287930\nAllowedClasses=Triceratops\nAllowedClasses=Omniraptor\n' >"${old}/TheIsle/Saved/Config/LinuxServer/Game.ini"
echo x >"${old}/TheIsleServer.sh"; echo x >"${old}/Manifest_UFSFiles_Linux.txt"; echo x >"${old}/TheIsle/Binaries/game"
mig() { env -i PATH="${PATH}" FLUX_DATA_DIR="${old}" "$@" python3 scripts/fluxisle.py migrate-legacy; }
check "status sees the old layout" "True" "$(env -i PATH="${PATH}" FLUX_DATA_DIR="${old}" python3 scripts/fluxisle.py status | python3 -c 'import json,sys;print(json.load(sys.stdin)["legacyData"])')"
mig 'additionalcommands=-ini:Game:[/Script/TheIsle.TIGameSession]:MaxPlayerCount=50 -ini:Game:[/Script/TheIsle.TIGameSession]:bQueueEnabled=true' >"${tmp}/mig"
check "the player database moved" "db" "$(cat "${old}/Saved/PlayerData/TheIslePersistence.db")"
check "with its write-ahead log" "wal" "$(cat "${old}/Saved/PlayerData/TheIslePersistence.db-wal")"
check "a safety backup first" "1" "$(find "${old}/flux/backups" -name "*-theisle-legacy.tar.gz" | wc -l)"
check "the old settings are the panel's now" "Old Isle True 0.4 50 Triceratops,Omniraptor" "$(python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(d["serverName"], d["humans"], d["aiDensity"], d["maxPlayers"], ",".join(d["playables"]))' "${old}/flux/settings.json")"
check "the admins too" "76561197960287930" "$(python3 -c 'import json,sys;print(",".join(json.load(open(sys.argv[1]))["admins"]))' "${old}/flux/settings.json")"
check "the old install is gone from the synced volume" "Saved flux" "$(find "${old}" -mindepth 1 -maxdepth 1 -printf "%f\n" | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')"
check "status: no legacy data left" "False" "$(env -i PATH="${PATH}" FLUX_DATA_DIR="${old}" python3 scripts/fluxisle.py status | python3 -c 'import json,sys;print(json.load(sys.stdin)["legacyData"])')"
check "a second run changes nothing" "" "$(mig)"
# A server that already has a database: the old saves are kept aside, never merged.
mkdir -p "${old}/TheIsle/Saved/PlayerData" && echo old2 >"${old}/TheIsle/Saved/PlayerData/TheIslePersistence.db"
mig >/dev/null
check "an existing database is never overwritten" "db" "$(cat "${old}/Saved/PlayerData/TheIslePersistence.db")"
check "the old one is kept aside" "old2" "$(cat "${old}"/flux/legacy-saved-*/PlayerData/TheIslePersistence.db)"

# --- 1.0.3 ---------------------------------------------------------------------------------------
# Players: one line per field, the EOS line is not a name, and a name with a comma never shifts one.
pl() { py "print(' '.join(p['id']+':'+p['name'] for p in t.parse_players($1)))"; }
check "columns, with the EOS line" "76561197960287930:Rex 76561197960287931:Bob" "$(pl '"PlayerList\n76561197960287930,76561197960287931,\nRex,Bob,\n0002a1b2c3d4e5f60718293a4b5c6d7e,0002a1b2c3d4e5f60718293a4b5c6d7f,\n"')"
check "one player with the EOS line" "76561197960287930:Rex" "$(pl '"PlayerList\n76561197960287930,\nRex,\n0002a1b2c3d4e5f60718293a4b5c6d7e,\n"')"
check "a comma in a name: no names rather than wrong ones" "76561197960287930: 76561197960287931:" "$(pl '"PlayerList\n76561197960287930,76561197960287931,\nRe,x,Bob,\nabc,def,\n"')"
check "an empty name keeps its place" "76561197960287930: 76561197960287931:Bob" "$(pl '"PlayerList\n76561197960287930,76561197960287931,\n,Bob,\n"')"
check "per-player lines: a whole line is one name" "76561197960287930:Rex, the T 76561197960287931:Bob" "$(pl '"PlayerList\n76561197960287930,\nRex, the T,\n76561197960287931,\nBob,\n"')"

# Mutations: the struct the game reads (the "Name, value" form is refused: ImportText, measured).
check "mutations are written as the struct" '(MutationName="Hemomania",EffectValue=0.05) (MutationName="Pit Organ",EffectValue=1)' \
  "$(isle set-settings '{"enabledMutations": ["Hemomania, 0.05", {"name": "Pit Organ", "value": 1}]}' >/dev/null; isle apply >/dev/null; iniv EnabledMutations | tr '\n' ' ' | sed 's/ $//')"
check "in the game state section" "[/Script/TheIsle.TIGameStateBase]" "$(awk '/^\[/{s=$0} /^EnabledMutations=/{print s; exit}' "${ini}")"
check "a struct comes back the same" '["(MutationName=\"Hematophagy\",EffectValue=0.25)"]' "$(py 'import json; print(json.dumps(t.coerce("enabledMutations", ["(MutationName=\"Hematophagy\",EffectValue=0.25)"])))')"
check "a list saved in the old form is read as the struct" '(MutationName="Wader",EffectValue=0.25)' \
  "$(python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));d["enabledMutations"]=["Wader, 0.25"];json.dump(d,open(sys.argv[1],"w"))' "${data}/flux/settings.json"; isle apply >/dev/null; iniv EnabledMutations)"
check "a mutation that cannot be read is refused" "2" "$(status isle set-settings '{"enabledMutations": ["Hemomania"]}')"

# Commas inside kick and ban texts become semicolons; the SteamID and the hours are found by shape.
check "kick reason commas" "76561197960287930,spam; spam" "$(PYTHONPATH=scripts python3 - <<'EOF'
import fluxisle as t
sent = []
t.rcon = lambda cmds: sent.extend(cmds) or [""]
t.out = lambda d: None
t.cmd_rcon("kick", "76561197960287930,spam, spam")
print(sent[0][1])
EOF
)"
check "ban fields" "Rex;Jr,76561197960287930,grief;spam,24" "$(PYTHONPATH=scripts python3 - <<'EOF'
import fluxisle as t
sent = []
t.rcon = lambda cmds: sent.extend(cmds) or [""]
t.out = lambda d: None
t.cmd_rcon("ban", "Rex,Jr,76561197960287930,grief, spam,24")
print(sent[0][1])
EOF
)"
check "a ban without hours is refused" "64" "$(status isle rcon ban Rex,76561197960287930,reason)"

# Unban by the id in either of the player's own fields, never the banner's.
printf '{"bannedPlayerData": [{"steamId": "Rex", "playerName": "76561197960287930", "bannerSteamId": "76561197960287999"}, {"steamId": "76561197960287999", "playerName": "Admin"}]}' >"${data}/Saved/PlayerData/PlayerBans.json"
isle unban 76561197960287930 >/dev/null
isle apply >/dev/null
check "unban when the id is in playerName" "76561197960287999" "$(python3 -c 'import json,sys;print(",".join(b["steamId"] for b in json.load(open(sys.argv[1]))["bannedPlayerData"]))' "${data}/Saved/PlayerData/PlayerBans.json")"

# The join password only when asked for.
isle set-settings '{"password": "pw9"}' >/dev/null
check "settings leave the password out" "" "$(isle settings | python3 -c 'import json,sys;print(json.load(sys.stdin)["values"]["password"])')"
check "but say one is set" "True" "$(isle settings | python3 -c 'import json,sys;print(json.load(sys.stdin)["passwordSet"])')"
check "settings password includes it" "pw9" "$(isle settings password | python3 -c 'import json,sys;print(json.load(sys.stdin)["values"]["password"])')"

# IslePilot: off by default, a switch the panel flips, and its own log read for the panel.
ipj() { isle islepilot | python3 -c "import json,sys;d=json.load(sys.stdin);print($1)"; }
check "IslePilot is off by default" "1" "$(status isle islepilot-enabled)"
check "off: stage off, no key" "off None" "$(ipj 'd["stage"], d["apiKey"]')"
check "turned on" "True restart" "$(isle islepilot on | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d["enabled"], d["appliesOn"])')"
check "and the entrypoint sees it" "0" "$(status isle islepilot-enabled)"
check "status says so" "True" "$(isle status | python3 -c 'import json,sys;print(json.load(sys.stdin)["islepilot"]["enabled"])')"
check "no server running: stopped" "stopped" "$(ipj 'd["stage"]')"
check "a bad action is refused" "2" "$(status isle islepilot sideways)"
mkdir -p "${data}/flux/islepilot"
key="ipk_0123456789abcdef0123456789abcdef"
printf '{\n  "apiKey": "%s",\n  "backendUrl": "https://islepilot.eu"\n}\n' "${key}" >"${data}/flux/islepilot/islepilot-config.json"
printf '%s\n' "[1] IslePilot plugin attached (linux .so)" "[1] [build] plugin build old" "[1] [ws] connected to https://islepilot.eu/ws" \
  "[2] IslePilot plugin attached (linux .so)" "[2] [build] plugin build 4bc2a86c" "[2]   ${key}" "[2] [ws] connect failed: ws handshake (no/bad response)" \
  >"${data}/flux/islepilot/islepilot-plugin.log"
check "the key, the newest start's build and connection" "${key} 4bc2a86c refused" "$(ipj 'd["apiKey"], d["pluginBuild"], d["connection"]')"
check "the log starts at the newest start" "4" "$(ipj 'len(d["log"])')"
check "and never shows the key" "0" "$(ipj 'sum("'"${key}"'" in l for l in d["log"])')"
check "a malformed key is not passed on" "None" "$(printf '{"apiKey": "ipk_x; rm -rf /"}' >"${data}/flux/islepilot/islepilot-config.json"; ipj 'd["apiKey"]')"
check "reset-key removes the config" "1" "$(isle islepilot reset-key >/dev/null; status test -f "${data}/flux/islepilot/islepilot-config.json")"
check "turned off" "1" "$(isle islepilot off >/dev/null; status isle islepilot-enabled)"

check "IslePilot's panel restart is requested, not a crash" "requested: from IslePilot (panel)" \
  "$(printf '%s\n' '[shutdown] graceful stop requested by panel' '[shutdown] saved 3 players' | flux_islepilot_reason 0)"
check "our own SIGTERM is not IslePilot's" "" "$(printf '%s\n' '[shutdown] graceful stop requested by launcher/signal' | flux_islepilot_reason 0)"
check "its anti-crash counts as a crash" "IslePilot restarted the server after a crash it caught (exit 90)" \
  "$(printf '%s\n' '[IslePilot] ANTI-CRASH: fault -> heap likely corrupt, clean restart (exit 90)' | flux_islepilot_reason 90)"
check "exit 90 alone too" "IslePilot restarted the server after a crash it caught (exit 90)" "$(printf '' | flux_islepilot_reason 90)"
check "a plain crash is left to the caller" "" "$(printf '%s\n' '[heartbeat] sent=1' | flux_islepilot_reason 139)"
check "the anti-crash wins over our SIGTERM" "IslePilot restarted the server after a crash it caught (exit 90)" \
  "$(printf '%s\n' '[shutdown] graceful stop requested by launcher/signal' '[IslePilot] ANTI-CRASH: x' | flux_islepilot_reason 90)"
printf 'plugin' >"${tmp}/lib.so"
sha256sum "${tmp}/lib.so" >"${tmp}/lib.so.sha256"
check "a matching checksum" "0" "$(status flux_sha256_matches "${tmp}/lib.so.sha256" "${tmp}/lib.so")"
check "a bare hash too" "0" "$(sha256sum "${tmp}/lib.so" | cut -d' ' -f1 >"${tmp}/bare"; status flux_sha256_matches "${tmp}/bare" "${tmp}/lib.so")"
check "a different file" "1" "$(printf 'other' >"${tmp}/other.so"; status flux_sha256_matches "${tmp}/lib.so.sha256" "${tmp}/other.so")"
check "an HTML error page is no checksum" "1" "$(printf '<html>' >"${tmp}/bad"; status flux_sha256_matches "${tmp}/bad" "${tmp}/lib.so")"

printf '\n%d passed, %d failed\n' "${pass}" "${fail}"
[ "${fail}" = "0" ]
