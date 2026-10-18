#!/bin/bash
# PID 1, and the supervisor of The Isle (Evrima) server.
#
# The game runs as a CHILD, never exec, so a stop reaches us first and becomes a save, and a
# server that ends on its own is followed by the next one in place:
#
#   - every start: SteamCMD update of the `evrima` branch (the default branch is the 2022 Legacy
#     game and has no Linux server), TheIsle/Saved linked to the data volume, a backup, Game.ini
#     from the environment and the panel (fluxisle.py apply), then the server as an unprivileged
#     user with Epic Online Services' dedicated-server client (without it the server never finishes
#     starting)
#   - SIGTERM/SIGINT from Docker: SIGTERM to the server, which shuts the engine down cleanly and
#     writes the player database (2 s measured)
#   - a new Evrima build on Steam: players warned over RCON for FLUX_WARN_MINUTES, then a restart
#     onto it (an out-of-date server refuses the new client); ISLE_RESTART_TIME = a daily one
#   - the server ending on its own: a new generation in place; FLUX_RESTART_MAX_ATTEMPTS
#     unplanned ones inside FLUX_RESTART_WINDOW seconds end the container with 42
#   - a backup of Saved/ (the player database, config, bans) on every start and every
#     FLUX_BACKUP_HOURS, after a save
#
# THE RCON IS NOT PUBLISHED and must never be: it authorises an IP address, not a connection
# (fluxisle.py). The hub reaches it with an exec, on 127.0.0.1.

set -uo pipefail
# shellcheck source=scripts/flux-lib.sh
source /opt/flux/flux-lib.sh

FLUX_RESTART_MAX_ATTEMPTS="${FLUX_RESTART_MAX_ATTEMPTS:-5}"
FLUX_RESTART_WINDOW="${FLUX_RESTART_WINDOW:-3600}"
FLUX_RESTART_BACKOFF="${FLUX_RESTART_BACKOFF:-10}"
FLUX_STOP_GRACE="${FLUX_STOP_GRACE:-90}"
FLUX_BACKUP_HOURS="${FLUX_BACKUP_HOURS:-6}"
FLUX_BACKUP_KEEP="${FLUX_BACKUP_KEEP:-10}"
# A start backup is skipped when the newest backup is younger than this: restarts in a row (panel
# saves, a crash loop, update restarts) must not rotate every good backup away.
FLUX_BACKUP_MIN_AGE_MINUTES="${FLUX_BACKUP_MIN_AGE_MINUTES:-60}"
# A game update that did not install is not tried again for this long.
FLUX_UPDATE_RETRY_HOURS="${FLUX_UPDATE_RETRY_HOURS:-6}"
FLUX_RESTORE_MARKER="${FLUX_RESTORE_MARKER:-/tmp/flux-restore-requested}"
FLUX_UPDATE_FAILED="${FLUX_STATE_DIR}/update-failed"
FLUX_UPDATE_CHECK_MINUTES="${FLUX_UPDATE_CHECK_MINUTES:-30}"
FLUX_WARN_MINUTES="${FLUX_WARN_MINUTES:-5}"
# IslePilot's Linux plugin, the URL its own self-hosted panel downloads it from (PLUGIN_SO_URL),
# with a .sha256 beside it. Rebuilt by IslePilot for every Evrima build, so fetched on every start.
ISLEPILOT_URL="${ISLEPILOT_URL:-https://islepilot.eu/cdn/plugin/libisleplugin.so}"
ISLEPILOT_LOG_MAX_LINES="${ISLEPILOT_LOG_MAX_LINES:-5000}"
# Epic Online Services' dedicated-server client for The Isle: the pair every host and template
# uses (CubeCoders AMP, the Pterodactyl egg). Overridable, should Afterthought ever rotate it.
ISLE_EOS_CLIENT_ID="${ISLE_EOS_CLIENT_ID:-xyza7891gk5PRo3J7G9puCJGFJjmEguW}"
ISLE_EOS_CLIENT_SECRET="${ISLE_EOS_CLIENT_SECRET:-pKWl6t5i9NJK8gTpVlAxzENZ65P8hYzodV8Dqe5Rlc8}"

s="${FLUX_SERVER_DIR}"
d="${FLUX_DATA_DIR}"
isle() { python3 /opt/flux/fluxisle.py "$@"; }

rm -f "${FLUX_RESTART_MARKER}"
mkdir -p "${s}" "${d}/Saved" "${FLUX_STATE_DIR}"

if ! port="$(flux_valid_port "${ISLE_PORT:-}" 7777)"; then
  flux_log "ERROR ISLE_PORT='${ISLE_PORT:-}' is not a port; refusing to start"
  isle state crashed "ISLE_PORT is not a usable port"
  exit 42
fi
if ! queue_port="$(flux_valid_port "${ISLE_QUEUE_PORT:-}" 10000)"; then
  flux_log "ERROR ISLE_QUEUE_PORT='${ISLE_QUEUE_PORT:-}' is not a port; refusing to start"
  exit 42
fi
export ISLE_QUEUE_PORT="${queue_port}"
if ! restart_at="$(flux_restart_time "${ISLE_RESTART_TIME:-}")"; then
  flux_log "WARN ISLE_RESTART_TIME='${ISLE_RESTART_TIME}' is not HH:MM; no daily restart"
  restart_at=""
fi
flux_log "flux-entrypoint starting (image ${FLUX_IMAGE_VERSION:-dev}): game ${port}/udp, queue ${queue_port}/tcp, RCON on 127.0.0.1 only, daily restart ${restart_at:-off}"

game_pid=""
islepilot_so=""
islepilot_from=0
watch_pid=""
backup_pid=""
terminating=0
generation=0
restart_history=()

rcon() { python3 /opt/flux/fluxisle.py rcon "$@" >/dev/null 2>&1; }

# SIGTERM: the engine shuts down cleanly and the player database is written (2 s measured). No
# RCON `save` first: on Docker's 10 seconds it cost 4 more (6.5 s measured) and adds nothing.
stop_server() {
  local pid
  pid="$(flux_game_pid)"
  pid="${pid:-${game_pid}}"
  [ -n "${pid}" ] || return 0
  kill -TERM "${pid}" 2>/dev/null
}

# shellcheck disable=SC2329  # invoked by the trap below
term_handler() {
  terminating=1
  flux_log "stop requested: saving and shutting down, no restart will follow"
  stop_server
}
trap term_handler TERM INT

update_server() {
  local attempt validate steam_pid rc
  if flux_truthy "${SKIP_UPDATE:-}" && [ -x "${s}/${FLUX_GAME_BINARY}" ]; then
    flux_log "SKIP_UPDATE is set: not updating the server files"
    return 0
  fi
  isle state updating "Downloading the server from Steam"
  flux_log "updating the server from Steam (app ${FLUX_STEAM_APP}, branch ${FLUX_STEAM_BRANCH})"
  validate=""
  for attempt in 1 2 3 4 5; do
    # In the background and waited for: a foreground command would hold off the TERM trap until
    # it ended, and Docker's 10 seconds would end the container mid-download instead.
    # shellcheck disable=SC2086  # validate is "" or "validate"
    steamcmd +force_install_dir "${s}" +login anonymous +app_update "${FLUX_STEAM_APP}" -beta "${FLUX_STEAM_BRANCH}" ${validate} +quit >/tmp/steamcmd.log 2>&1 &
    steam_pid=$!
    wait "${steam_pid}"
    rc=$?
    if [ "${terminating}" = "1" ]; then
      kill "${steam_pid}" 2>/dev/null
      return 1
    fi
    if [ "${rc}" = "0" ]; then
      flux_log "server build $(flux_installed_build "${s}/steamapps/appmanifest_${FLUX_STEAM_APP}.acf")"
      return 0
    fi
    [ "${terminating}" = "1" ] && return 1
    validate="validate"
    flux_log "WARN steamcmd failed (attempt ${attempt}/5): $(grep -aE 'ERROR|Error|error' /tmp/steamcmd.log | tail -1 | tr -d '\r'); retrying in 5s with validate"
    sleep 5
  done
  if [ -x "${s}/${FLUX_GAME_BINARY}" ]; then
    flux_log "WARN could not update from Steam; starting the build already installed"
    return 0
  fi
  flux_log "ERROR could not install the server from Steam"
  return 1
}

# TheIsle/Saved (the player database, Game.ini, bans, logs) IS the data volume.
link_saved() {
  local saved="${s}/TheIsle/Saved"
  mkdir -p "${s}/TheIsle"
  if [ -L "${saved}" ]; then
    [ "$(readlink "${saved}")" = "${d}/Saved" ] && return 0
    rm -f "${saved}"
  elif [ -d "${saved}" ]; then
    cp -an "${saved}/." "${d}/Saved/" 2>/dev/null
    rm -rf "${saved}"
  fi
  ln -s "${d}/Saved" "${saved}"
}

# The unprivileged user owns what the server writes; Steam's client library where it looks.
prepare_user() {
  local home
  home="$(getent passwd "${FLUX_UID}" | cut -d: -f6)"
  mkdir -p "${home}/.steam/sdk64"
  cp -f /root/.local/share/Steam/steamcmd/linux64/steamclient.so "${home}/.steam/sdk64/" 2>/dev/null
  chown -R "${FLUX_UID}:${FLUX_UID}" "${home}/.steam" "${d}/Saved"
  chown "${FLUX_UID}:${FLUX_UID}" "${s}/TheIsle" 2>/dev/null
}

# IslePilot, when the owner turned it on in the panel (flux-isle islepilot on): the newest plugin
# downloaded into the install and checked against its .sha256, then linked from flux/islepilot on
# the data volume. The plugin keeps its key, config and log beside the path it was loaded from,
# so they are synced and the key survives a move to another node. A failed download starts the
# copy already here; with none, the server starts without it. Sets islepilot_so.
islepilot_prepare() {
  local dir="${d}/flux/islepilot" local_dir="${s}/islepilot" lib="libisleplugin.so" error="" f
  islepilot_so=""
  islepilot_from=0
  if ! isle islepilot-enabled; then
    rm -f "${dir}/${lib}"
    return 0
  fi
  mkdir -p "${dir}" "${local_dir}"
  rm -f "${local_dir}/.download" "${local_dir}/.download.sha256"
  if ! curl -fsSL --max-time 180 -o "${local_dir}/.download" "${ISLEPILOT_URL}"; then
    error="the plugin could not be downloaded from IslePilot"
  elif ! curl -fsSL --max-time 30 -o "${local_dir}/.download.sha256" "${ISLEPILOT_URL}.sha256"; then
    error="IslePilot's checksum could not be downloaded"
  elif ! flux_sha256_matches "${local_dir}/.download.sha256" "${local_dir}/.download"; then
    error="the download did not match IslePilot's checksum"
  else
    mv -f "${local_dir}/.download" "${local_dir}/${lib}"
  fi
  rm -f "${local_dir}/.download" "${local_dir}/.download.sha256"
  if [ -n "${error}" ]; then
    flux_log "WARN IslePilot: ${error}$([ -f "${local_dir}/${lib}" ] && echo "; starting the copy already on this node")"
    printf '{"ok": false, "at": %s, "error": "%s", "fallback": %s}\n' "$(date +%s)" "${error}" "$([ -f "${local_dir}/${lib}" ] && echo true || echo false)" >"${d}/flux/islepilot-download.json"
    [ -f "${local_dir}/${lib}" ] || { rm -f "${dir}/${lib}"; return 0; }
  else
    printf '{"ok": true, "at": %s, "sha256": "%s"}\n' "$(date +%s)" "$(sha256sum "${local_dir}/${lib}" | cut -d' ' -f1)" >"${d}/flux/islepilot-download.json"
  fi
  chmod 0644 "${local_dir}/${lib}"
  ln -sfn "${local_dir}/${lib}" "${dir}/${lib}"
  for f in "${dir}"/*.log "${dir}"/*.jsonl; do
    [ -f "${f}" ] && flux_trim_file "${f}" "${ISLEPILOT_LOG_MAX_LINES}"
  done
  chown -R -h "${FLUX_UID}:${FLUX_UID}" "${dir}"
  [ -f "${dir}/islepilot-plugin.log" ] && islepilot_from="$(wc -l <"${dir}/islepilot-plugin.log")"
  islepilot_so="${dir}/${lib}"
  flux_log "IslePilot: plugin $(sha256sum "${local_dir}/${lib}" | cut -c1-12) loaded into the server (a third party's; turned on in the panel)"
}

# Minutes since the newest backup was written; empty when there is none.
newest_backup_age() {
  local newest
  newest="$(find "${FLUX_BACKUP_DIR}" -maxdepth 1 -name '*-theisle*.tar.gz' -printf '%T@\n' 2>/dev/null | sort -n | tail -1)"
  [ -n "${newest}" ] && echo $((($(date +%s) - ${newest%.*}) / 60))
}

# A .tar.gz of Saved/ (the player database, config, bans), taken from a COPY: the database is
# SQLite with a write-ahead log, and archiving it in place while the server writes gives an
# archive tar itself calls inconsistent ("file changed as we read it"). The copy is made right
# after an RCON save, and the database, its WAL and SHM are copied together. $1 = why, $2 = force.
backup_saved() {
  local why="$1" force="${2:-}" out name stage age
  [ "${FLUX_BACKUP_KEEP}" -gt 0 ] 2>/dev/null || return 0
  [ -d "${d}/Saved/PlayerData" ] || return 0
  if [ "${why}" = "start" ] && [ -z "${force}" ] && age="$(newest_backup_age)" && [ -n "${age}" ] \
    && [ "${age}" -lt "${FLUX_BACKUP_MIN_AGE_MINUTES}" ]; then
    flux_log "backup (start): skipped, the newest is ${age} min old"
    return 0
  fi
  mkdir -p "${FLUX_BACKUP_DIR}"
  name="$(date -u +%Y%m%d-%H%M%S)-theisle$([ "${why}" = "pre-restore" ] && echo "-pre-restore").tar.gz"
  out="${FLUX_BACKUP_DIR}/${name}"
  stage="$(mktemp -d)"
  if (cd "${d}" && tar --exclude='Saved/Logs' --exclude='Saved/Demos' --exclude='Saved/Crashes' -cf - Saved) | tar -C "${stage}" -xf - 2>/dev/null \
    && tar -C "${stage}" -czf "${out}.part" Saved && mv "${out}.part" "${out}"; then
    flux_log "backup (${why}): flux/backups/${name}, $(du -h "${out}" | cut -f1)"
  else
    rm -f "${out}.part"
    flux_log "WARN backup (${why}) failed"
  fi
  rm -rf "${stage}"
  python3 /opt/flux/fluxisle.py prune-backups "${FLUX_BACKUP_KEEP}" | while IFS= read -r line; do flux_log "${line#\# }"; done
}

# A backup asked for by the panel (flux-isle restore): with the server stopped, a safety backup
# of what is there now, then the chosen archive unpacked aside and swapped into place.
restore_saved() {
  local name="$1" stage
  case "${name}" in
    */* | "" | .*) flux_log "WARN restore: '${name}' is not a backup name"; return 1 ;;
  esac
  if [ ! -f "${FLUX_BACKUP_DIR}/${name}" ]; then
    flux_log "WARN restore: flux/backups/${name} does not exist"
    return 1
  fi
  backup_saved "pre-restore" force
  stage="$(mktemp -d -p "${d}" .restore-XXXXXX)"
  if ! tar -C "${stage}" -xzf "${FLUX_BACKUP_DIR}/${name}" || [ ! -d "${stage}/Saved" ]; then
    flux_log "WARN restore: flux/backups/${name} could not be unpacked; nothing changed"
    rm -rf "${stage}"
    return 1
  fi
  rm -rf "${d}/Saved.before-restore"
  [ -d "${d}/Saved" ] && mv "${d}/Saved" "${d}/Saved.before-restore"
  mv "${stage}/Saved" "${d}/Saved" && rm -rf "${stage}" "${d}/Saved.before-restore"
  flux_log "restore: flux/backups/${name} is in place (the state before it is in the pre-restore backup)"
}

# shellcheck disable=SC2329  # run in the background below
backupper() {
  [ "${FLUX_BACKUP_HOURS}" -gt 0 ] 2>/dev/null || exit 0
  while true; do
    sleep $((FLUX_BACKUP_HOURS * 3600))
    rcon save
    sleep 3
    backup_saved "every ${FLUX_BACKUP_HOURS}h"
  done
}

player_count() {
  python3 /opt/flux/fluxisle.py rcon players 2>/dev/null | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("players") or []))' 2>/dev/null
}

restart_with_warning() {
  local why="$1" left="${FLUX_WARN_MINUTES}"
  while [ "${left}" -gt 0 ] && [ "$(player_count)" != "0" ]; do
    rcon announce "Server restart in ${left} minute$([ "${left}" = 1 ] || echo s): ${2}. Find a safe spot."
    sleep 60
    left=$((left - 1))
  done
  printf '%s\n' "${why}" >"${FLUX_RESTART_MARKER}"
  flux_log "${why}: restarting the server"
  stop_server
}

# $1 = a build. True when an update to it was tried less than FLUX_UPDATE_RETRY_HOURS ago and did
# not install (Steam down, disk full): the server is not restarted for it again and again.
update_recently_failed() {
  local target at
  [ -f "${FLUX_UPDATE_FAILED}" ] || return 1
  read -r target at <"${FLUX_UPDATE_FAILED}"
  [ "${target}" = "$1" ] && [ $(($(date +%s) - ${at:-0})) -lt $((FLUX_UPDATE_RETRY_HOURS * 3600)) ]
}

# shellcheck disable=SC2329  # run in the background below
# Marks the server running once its RCON answers, then follows Steam and the daily restart.
watcher() {
  local now last_check next_restart="" build public i
  for i in $(seq 1 600); do
    if rcon players; then
      isle state running
      flux_log "the server is up (generation ${generation})"
      break
    fi
    sleep 2
    [ "${i}" = 600 ] && flux_log "WARN the server's RCON has not answered in 20 minutes"
  done
  last_check="$(date -u +%s)"
  [ -n "${restart_at}" ] && next_restart="$(flux_next_daily "$(date -u +%s)" "${restart_at}")"
  while true; do
    sleep 60
    now="$(date -u +%s)"
    if [ "${FLUX_UPDATE_CHECK_MINUTES}" -gt 0 ] 2>/dev/null && [ $((now - last_check)) -ge $((FLUX_UPDATE_CHECK_MINUTES * 60)) ]; then
      last_check="${now}"
      build="$(flux_installed_build "${s}/steamapps/appmanifest_${FLUX_STEAM_APP}.acf")"
      public="$(steamcmd +login anonymous +app_info_update 1 +app_info_print "${FLUX_STEAM_APP}" +quit 2>/dev/null | flux_public_build "${FLUX_STEAM_BRANCH}")"
      if [ -n "${public}" ] && [ -n "${build}" ] && [ "${public}" != "${build}" ] && ! update_recently_failed "${public}"; then
        flux_log "a new Evrima build is on Steam (${build} -> ${public})"
        restart_with_warning "planned: game update ${build} -> ${public}" "a game update"
        exit 0
      fi
    fi
    if [ -n "${next_restart}" ] && [ "${now}" -ge "${next_restart}" ]; then
      restart_with_warning "planned: the daily restart (${restart_at})" "the daily restart"
      exit 0
    fi
  done
}

start_generation() {
  local line
  generation=$((generation + 1))
  rm -f "${FLUX_RESTART_MARKER}"

  update_server || return 1
  [ "${terminating}" = "1" ] && return 2
  # An update restart that did not reach its build: remembered, so it is not tried every half hour.
  if [[ "${last_reason:-}" == "planned: game update "*" -> "* ]]; then
    local target="${last_reason##* -> }"
    if [ "$(flux_installed_build "${s}/steamapps/appmanifest_${FLUX_STEAM_APP}.acf")" != "${target}" ]; then
      printf '%s %s\n' "${target}" "$(date +%s)" >"${FLUX_UPDATE_FAILED}"
      flux_log "WARN the update to build ${target} did not install; not trying it again for ${FLUX_UPDATE_RETRY_HOURS} h"
    else
      rm -f "${FLUX_UPDATE_FAILED}"
    fi
  fi
  while IFS= read -r line; do
    flux_log "${line#\# }"
  done < <(isle migrate-legacy 2>&1)
  link_saved
  if [ -f "${FLUX_RESTORE_MARKER}" ]; then
    restore_saved "$(head -1 "${FLUX_RESTORE_MARKER}")"
    rm -f "${FLUX_RESTORE_MARKER}"
  else
    backup_saved "start"
  fi
  while IFS= read -r line; do
    flux_log "config: ${line#\# }"
  done < <(isle apply 2>&1)
  prepare_user
  islepilot_prepare
  [ "${terminating}" = "1" ] && return 2

  isle state starting "Loading Gateway"
  flux_log "starting the server (generation ${generation})"
  local preload=()
  [ -n "${islepilot_so}" ] && preload=("LD_PRELOAD=${islepilot_so}")
  (
    cd "${s}" || exit 1
    # -log: the engine log to stdout (the container's output) and Saved/Logs/TheIsle.log.
    # IslePilot's plugin is preloaded by `env` into the game only: setpriv and env are already
    # running when it is set, and its constructor starts a thread in whatever loads it.
    exec setpriv --reuid="${FLUX_UID}" --regid="${FLUX_UID}" --init-groups env HOME="$(getent passwd "${FLUX_UID}" | cut -d: -f6)" "${preload[@]}" \
      "./${FLUX_GAME_BINARY}" TheIsle -Port="${port}" -log \
      "-ini:Engine:[EpicOnlineServices]:DedicatedServerClientId=${ISLE_EOS_CLIENT_ID}" \
      "-ini:Engine:[EpicOnlineServices]:DedicatedServerClientSecret=${ISLE_EOS_CLIENT_SECRET}"
  ) &
  game_pid=$!

  watcher &
  watch_pid=$!
  backupper &
  backup_pid=$!
  return 0
}

sweep_generation() {
  local pid
  for pid in "${watch_pid}" "${backup_pid}"; do
    [ -n "${pid}" ] && kill "${pid}" 2>/dev/null
  done
  watch_pid="" backup_pid=""
  pkill -KILL -f 'TheIsleServer-Linux-Shipping TheIsle ' 2>/dev/null
  game_pid=""
}

wait_for_generation() {
  local asked_at=0 now
  while kill -0 "${game_pid}" 2>/dev/null; do
    sleep 1 &
    wait $!
    if [ "${terminating}" = "1" ] || [ -f "${FLUX_RESTART_MARKER}" ]; then
      now="$(date -u +%s)"
      [ "${asked_at}" = "0" ] && asked_at="${now}"
      if [ $((now - asked_at)) -ge "${FLUX_STOP_GRACE}" ]; then
        flux_log "WARN the server was asked to stop ${FLUX_STOP_GRACE}s ago and has not; ending it"
        kill -KILL "${game_pid}" 2>/dev/null
        break
      fi
    else
      asked_at=0
    fi
  done
  wait "${game_pid}" 2>/dev/null
}

while true; do
  if [ "${terminating}" = "1" ]; then
    isle state stopped
    exit 0
  fi
  start_generation
  started=$?
  if [ "${started}" = "2" ]; then
    flux_log "stopped on request before the server started"
    isle state stopped
    exit 0
  elif [ "${started}" != "0" ]; then
    flux_log "ERROR the server could not be prepared; ending the container (42)"
    isle state crashed "The server could not be installed or started"
    exit 42
  fi
  wait_for_generation
  rc=$?

  reason=""
  [ -f "${FLUX_RESTART_MARKER}" ] && reason="$(cat "${FLUX_RESTART_MARKER}" 2>/dev/null)"
  sweep_generation
  rm -f "${FLUX_RESTART_MARKER}"

  if [ "${terminating}" = "1" ]; then
    flux_log "stopped on request (server exited ${rc})"
    isle state stopped
    exit 0
  fi
  if [ -z "${reason}" ] && [ -n "${islepilot_so}" ]; then
    reason="$(tail -n +"$((islepilot_from + 1))" "${d}/flux/islepilot/islepilot-plugin.log" 2>/dev/null | flux_islepilot_reason "${rc}")"
  fi
  [ -z "${reason}" ] && reason="the server ended on its own (exit ${rc})"
  last_reason="${reason}"

  if flux_restart_counts "${reason}"; then
    now="$(date -u +%s)"
    read -r -a restart_history <<<"$(flux_restarts_in_window "${now}" "${FLUX_RESTART_WINDOW}" "${restart_history[@]}")"
    restart_history+=("${now}")
    if [ "${#restart_history[@]}" -gt "${FLUX_RESTART_MAX_ATTEMPTS}" ]; then
      flux_log "${reason}: ${#restart_history[@]} restarts within ${FLUX_RESTART_WINDOW}s; ending the container (42)"
      isle state crashed "The server keeps stopping: ${reason}"
      exit 42
    fi
  fi

  isle state restarting "${reason}"
  flux_log "${reason}: restarting the server in place in ${FLUX_RESTART_BACKOFF}s"
  sleep "${FLUX_RESTART_BACKOFF}" &
  wait $!
done
