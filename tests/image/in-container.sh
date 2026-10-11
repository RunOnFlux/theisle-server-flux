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
export FLUX_RESTART_BACKOFF=1 FLUX_UPDATE_CHECK_MINUTES=0 ISLE_SERVER_NAME="Image Test"
/opt/flux/flux-entrypoint.sh >/tmp/entry.log 2>&1 &
entry=$!
check "the server comes up (its RCON answers)" "0" "$(status wait_for 'grep -q "\"running\"" ${data}/flux/state.json 2>/dev/null' 40)"
check "as uid 1000" "1000" "$(ps -o uid= -p "$(pgrep -f 'TheIsleServer-Linux-Shipping TheIsle ')" | tr -d ' ')"
check "with the EOS client" "1" "$(pgrep -af 'TheIsleServer-Linux-Shipping TheIsle ' | grep -c 'DedicatedServerClientId=xyza7891')"
check "Saved/ is the data volume" "${data}/Saved" "$(readlink /mnt/isle/server/TheIsle/Saved)"
check "status over RCON" "True []" "$(flux-isle status | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d["rcon"], d["players"])')"
check "an RCON command" "Game saved" "$(flux-isle rcon save | python3 -c 'import json,sys;print(json.load(sys.stdin)["reply"])')"

flux-isle set-settings '{"discord": "https://discord.gg/flux"}' >/dev/null
flux-isle restart >/dev/null
check "a panel restart writes the database" "0" "$(status wait_for 'test -s ${data}/Saved/PlayerData/TheIslePersistence.db' 20)"
check "and comes back with the new setting" "0" "$(status wait_for 'grep -q "^Discord=https://discord.gg/flux" ${data}/Saved/Config/LinuxServer/Game.ini && grep -q "\"running\"" ${data}/flux/state.json' 40)"
check "not counted as a crash" "0" "$(grep -c 'restarts within' /tmp/entry.log)"
check "a backup on the second start" "0" "$(status wait_for 'ls ${data}/flux/backups/*-theisle.tar.gz' 5)"

kill -TERM "${entry}"
check "a stop ends the supervisor" "0" "$(status wait_for '! kill -0 ${entry} 2>/dev/null' 20)"
check "and says stopped" "stopped" "$(python3 -c 'import json;print(json.load(open("'"${data}"'/flux/state.json"))["state"])')"
check "the database was written twice" "2" "$(wc -l <"${data}/Saved/PlayerData/TheIslePersistence.db")"

printf '\n%d passed, %d failed\n' "${pass}" "${fail}"
[ "${fail}" = "0" ] || { echo '--- entrypoint log'; cat /tmp/entry.log; exit 1; }
