#!/bin/bash
# shellcheck disable=SC2016  # wait_for conditions are single-quoted and eval-ed later, on purpose
# Runs INSIDE the image (tests/test-image.sh). The repository's tests/ folder is mounted at /t
# and scripts/ at /s.
set -uo pipefail
export LC_ALL=C

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
wait_for() {
  local _
  for _ in $(seq 1 $(($2 * 5))); do
    eval "$1" && return 0
    sleep 0.2
  done
  return 1
}

for tool in steamcmd python3 setpriv pgrep pkill tar getent; do
  check "${tool} is installed" "0" "$(status command -v "${tool}")"
done
check "uid 1000 exists" "0" "$(status getent passwd 1000)"
check "flux-isle is on the PATH" "0" "$(status command -v flux-isle)"
check "flux-isle starts (usage)" "64" "$(status flux-isle)"
check "the image's scripts are the repository's" "0" "$(status diff -r --exclude=__pycache__ /s /opt/flux)"
check "the unit tests pass with the image's Python" "0" "$(status bash -c 'cd /tmp && rm -rf repo && mkdir repo && cp -r /s repo/scripts && cp -r /t repo/tests && cd repo && ./tests/test-flux.sh')"

# A stand-in server: the RCON protocol on 127.0.0.1:RconPort with Game.ini's password (auth,
# players, save, announce), and a clean exit on SIGTERM that writes the "database".
cat >/usr/local/bin/steamcmd <<'STUB'
#!/bin/bash
dir=""
while [ $# -gt 0 ]; do [ "$1" = "+force_install_dir" ] && dir="$2"; shift; done
[ -n "${dir}" ] || exit 0
mkdir -p "${dir}/TheIsle/Binaries/Linux" "${dir}/steamapps"
printf '"AppState"\n{\n\t"buildid"\t\t"100"\n}\n' >"${dir}/steamapps/appmanifest_412680.acf"
cat >"${dir}/TheIsle/Binaries/Linux/TheIsleServer-Linux-Shipping" <<'GAME'
#!/usr/bin/python3
import os, re, signal, socket, sys, threading
assert os.getuid() == 1000, "must not run as root"
ini = open("TheIsle/Saved/Config/LinuxServer/Game.ini").read()
password = re.search(r"^RconPassword=(.*)$", ini, re.M).group(1)
port = int(re.search(r"^RconPort=(\d+)$", ini, re.M).group(1))
def bye(*_):
    os.makedirs("TheIsle/Saved/PlayerData", exist_ok=True)
    open("TheIsle/Saved/PlayerData/TheIslePersistence.db", "a").write("saved\n")
    os._exit(0)
signal.signal(signal.SIGTERM, bye)
srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", port)); srv.listen(5)
def client(c):
    authed = False
    while True:
        data = c.recv(4096)
        if not data: return
        if data[0] == 1:
            authed = data[1:].rstrip(b"\0").decode() == password
            c.sendall(b"Password Accepted" if authed else b"Incorrect Password")
        elif authed and data[0] == 2:
            op = data[1]
            c.sendall({0x40: b"PlayerList\n\n", 0x50: b"Game saved", 0x10: b"Announcement Sent: x",
                       0x93: b"QueueEnabled: true, QueueLength: 0, PendingConnections: 0"}.get(op, b"ok"))
while True:
    c, _ = srv.accept()
    threading.Thread(target=client, args=(c,), daemon=True).start()
GAME
chmod +x "${dir}/TheIsle/Binaries/Linux/TheIsleServer-Linux-Shipping"
STUB
chmod +x /usr/local/bin/steamcmd

data=/mnt/isle/data
# A volume from the previous image (ghcr.io/auhrus/theisleevrima): the whole install, saves inside.
mkdir -p "${data}/TheIsle/Saved/PlayerData" "${data}/TheIsle/Saved/Config/LinuxServer" "${data}/Engine/Binaries" "${data}/steamapps"
echo legacy >"${data}/TheIsle/Saved/PlayerData/TheIslePersistence.db"
printf '[/Script/TheIsle.TIGameSession]\nbEnableHumans=true\n' >"${data}/TheIsle/Saved/Config/LinuxServer/Game.ini"
export FLUX_RESTART_BACKOFF=1 FLUX_UPDATE_CHECK_MINUTES=0 ISLE_SERVER_NAME="Image Test"
/opt/flux/flux-entrypoint.sh >/tmp/entry.log 2>&1 &
entry=$!
check "the server comes up (its RCON answers)" "0" "$(status wait_for 'grep -q "\"running\"" ${data}/flux/state.json 2>/dev/null' 40)"
check "as uid 1000" "1000" "$(ps -o uid= -p "$(pgrep -f 'TheIsleServer-Linux-Shipping TheIsle ')" | tr -d ' ')"
check "with the EOS client" "1" "$(pgrep -af 'TheIsleServer-Linux-Shipping TheIsle ' | grep -c 'DedicatedServerClientId=xyza7891')"
check "Saved/ is the data volume" "${data}/Saved" "$(readlink /mnt/isle/server/TheIsle/Saved)"
check "the previous image's player database was moved in" "legacy" "$(head -1 "${data}/Saved/PlayerData/TheIslePersistence.db")"
check "and its settings kept" "true" "$(sed -n 's/^bEnableHumans=//p' "${data}/Saved/Config/LinuxServer/Game.ini")"
check "and its install removed from the data volume" "1" "$(status test -e "${data}/Engine")"
check "with a safety backup" "0" "$(status bash -c "ls ${data}/flux/backups/*-theisle-legacy.tar.gz")"
check "status over RCON" "True []" "$(flux-isle status | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d["rcon"], d["players"])')"
check "an RCON command" "Game saved" "$(flux-isle rcon save | python3 -c 'import json,sys;print(json.load(sys.stdin)["reply"])')"

flux-isle set-settings '{"discord": "https://discord.gg/flux"}' >/dev/null
flux-isle restart >/dev/null
check "a panel restart writes the database" "0" "$(status wait_for 'test -s ${data}/Saved/PlayerData/TheIslePersistence.db' 20)"
check "and comes back with the new setting" "0" "$(status wait_for 'grep -q "^Discord=https://discord.gg/flux" ${data}/Saved/Config/LinuxServer/Game.ini && grep -q "\"running\"" ${data}/flux/state.json' 40)"
check "not counted as a crash" "0" "$(grep -c 'restarts within' /tmp/entry.log)"
check "a start backup is skipped when a recent one exists" "0" "$(status grep -q 'backup (start): skipped' /tmp/entry.log)"

# Restore: the newest backup, while the server runs.
backup="$(flux-isle backups | python3 -c 'import json,sys;print(json.load(sys.stdin)["backups"][0]["name"])')"
export saved_lines
saved_lines="$(tar -xzOf "${data}/flux/backups/${backup}" Saved/PlayerData/TheIslePersistence.db | wc -l)"
echo "after the backup" >>"${data}/Saved/PlayerData/TheIslePersistence.db"
flux-isle restore "${backup}" >/dev/null
check "a restore puts the backup in place" "0" "$(status wait_for '[ "$(wc -l <${data}/Saved/PlayerData/TheIslePersistence.db)" = "${saved_lines}" ] && grep -q "\"running\"" ${data}/flux/state.json' 40)"
check "after a safety backup of what was there" "0" "$(status bash -c "ls ${data}/flux/backups/*-theisle-pre-restore.tar.gz")"
check "the restore was not counted as a crash" "0" "$(grep -c 'restarts within' /tmp/entry.log)"

# IslePilot: a stand-in plugin (any real library loads into the stand-in server) served from a
# file:// URL with its .sha256, switched on from the panel, preloaded into the game only.
mkdir -p /tmp/ip
cp "$(python3 -c 'import zlib,re;print(re.search(r"\S*libz\.so\S*",open("/proc/self/maps").read()).group(0))')" /tmp/ip/libisleplugin.so
sha256sum /tmp/ip/libisleplugin.so | cut -d' ' -f1 >/tmp/ip/libisleplugin.so.sha256
export ISLEPILOT_URL=file:///tmp/ip/libisleplugin.so
kill -TERM "${entry}"; wait_for '! kill -0 ${entry} 2>/dev/null' 20
flux-isle islepilot on >/dev/null
/opt/flux/flux-entrypoint.sh >/tmp/entry.log 2>&1 &
entry=$!
game_maps() { setpriv --reuid=1000 --regid=1000 --clear-groups cat "/proc/$(pgrep -f 'TheIsleServer-Linux-Shipping TheIsle ')/maps" 2>/dev/null; }
check "IslePilot on: the server comes up" "0" "$(status wait_for 'grep -q "\"running\"" ${data}/flux/state.json 2>/dev/null' 40)"
check "with the plugin preloaded" "1" "$(game_maps | grep -c -m1 'islepilot/libisleplugin.so')"
check "into the game only, not the supervisor" "0" "$(grep -c libisleplugin /proc/${entry}/maps)"
check "the link on the data volume points into the install" "/mnt/isle/server/islepilot/libisleplugin.so" "$(readlink "${data}/flux/islepilot/libisleplugin.so")"
check "the plugin's folder is the server user's" "1000" "$(stat -c %u "${data}/flux/islepilot")"
check "flux-isle sees it loaded" "True True" "$(flux-isle islepilot | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d["loaded"], d["download"]["ok"])')"
check "status too" "True" "$(flux-isle status | python3 -c 'import json,sys;print(json.load(sys.stdin)["islepilot"]["loaded"])')"
check "said in the log" "0" "$(status grep -q 'IslePilot: plugin .* loaded into the server' /tmp/entry.log)"

# A checksum that does not match: the copy already on the node is used, and the panel is told.
echo 0000000000000000000000000000000000000000000000000000000000000000 >/tmp/ip/libisleplugin.so.sha256
flux-isle restart >/dev/null
check "a bad checksum keeps the copy already here" "0" "$(status wait_for 'grep -q "did not match IslePilot.s checksum; starting the copy" /tmp/entry.log && grep -q "\"running\"" ${data}/flux/state.json' 40)"
check "still loaded, the panel told" "True False True" "$(flux-isle islepilot | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d["loaded"], d["download"]["ok"], d["download"]["fallback"])')"

# Off: the next start loads nothing.
flux-isle islepilot off >/dev/null
check "turned off: restart needed" "restart" "$(flux-isle islepilot | python3 -c 'import json,sys;print(json.load(sys.stdin)["stage"])')"
flux-isle restart >/dev/null
sleep 2
check "off: the server comes back" "0" "$(status wait_for 'grep -q "\"running\"" ${data}/flux/state.json && [ -n "$(pgrep -f "TheIsleServer-Linux-Shipping TheIsle ")" ]' 40)"
check "without the plugin" "0" "$(game_maps | grep -c libisleplugin)"
check "and the link is gone" "1" "$(status test -L "${data}/flux/islepilot/libisleplugin.so")"
check "IslePilot never counted as a crash" "0" "$(grep -c 'restarts within' /tmp/entry.log)"

kill -TERM "${entry}"
check "a stop ends the supervisor" "0" "$(status wait_for '! kill -0 ${entry} 2>/dev/null' 20)"
check "and says stopped" "stopped" "$(python3 -c 'import json;print(json.load(open("'"${data}"'/flux/state.json"))["state"])')"
check "the database was written on every stop" "0" "$(status grep -q saved "${data}/Saved/PlayerData/TheIslePersistence.db")"

printf '\n%d passed, %d failed\n' "${pass}" "${fail}"
[ "${fail}" = "0" ] || { echo '--- entrypoint log'; cat /tmp/entry.log; exit 1; }
