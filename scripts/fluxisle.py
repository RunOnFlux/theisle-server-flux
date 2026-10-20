#!/usr/bin/env python3
"""Every decision about The Isle (Evrima) server's files, its RCON, and the hub's commands.

    fluxisle.py apply                  write Game.ini from the environment and the panel (before every start)
    fluxisle.py state <state> [msg]    record what the supervisor is doing (flux/state.json)
    fluxisle.py rcon-password          print the RCON password (made once, kept on the data volume)

    flux-isle status                   state, players, queue, version (one JSON document)
    flux-isle rcon <op> [args]         one RCON command by name (see OPS), its reply as JSON
    flux-isle settings [password]      the panel's settings, the env that overrides them, the choices
                                       (the join password only with `password`)
    flux-isle set-settings '<json>'    save settings; the ones RCON can change are applied live too
    flux-isle bans                     PlayerBans.json
    flux-isle unban <steamid>          lifted on the next start (the server owns the file while it runs)
    flux-isle restart                  save, stop and start again
    flux-isle backups                  the backups in flux/backups (name, size, date, why)
    flux-isle restore <backup>         stop, keep a safety backup, put that backup in place, start
    fluxisle.py migrate-legacy         move a server from the previous image's layout (the entrypoint)
    flux-isle islepilot                IslePilot: on or off, loaded, connected, its key and its log
    flux-isle islepilot on|off         turn the IslePilot plugin on or off (applies on the next start)
    flux-isle islepilot reset-key      a new IslePilot key on the next start (unpairs the server)
    fluxisle.py islepilot-enabled      exit 0 when IslePilot is on (the entrypoint)

THE RCON IS NEVER PUBLISHED. The Isle's RCON authorises an IP address once a password was right,
not a connection: anyone behind the same address gets in afterwards with no password (measured).
It listens on RconPort inside the container and only the panel's exec reaches it, on 127.0.0.1.
ServerDetails prints the join password in plain text, so its reply is never passed on whole.

Precedence, the same everywhere: an environment variable that is SET to a value is applied on
every start; one that is not set, or set EMPTY, leaves the panel's value, then the default. (The
marketplace writes every declared parameter, blank or not: an empty one is the panel's to decide.)
"""

import json
import os
import re
import secrets
import shutil
import socket
import subprocess
import sys
import tempfile
import time

SERVER_DIR = os.environ.get("FLUX_SERVER_DIR", "/mnt/isle/server")
DATA_DIR = os.environ.get("FLUX_DATA_DIR", "/mnt/isle/data")
STATE_DIR = os.environ.get("FLUX_STATE_DIR", os.path.join(DATA_DIR, "flux"))
STATE_FILE = os.path.join(STATE_DIR, "state.json")
SETTINGS_FILE = os.path.join(STATE_DIR, "settings.json")
UNBAN_FILE = os.path.join(STATE_DIR, "unban-pending.json")
BACKUP_DIR = os.environ.get("FLUX_BACKUP_DIR", os.path.join(STATE_DIR, "backups"))
RESTORE_MARKER = os.environ.get("FLUX_RESTORE_MARKER", "/tmp/flux-restore-requested")
# The previous image (ghcr.io/auhrus/theisleevrima) synced the WHOLE install: on its volume the
# saves are at TheIsle/Saved, which our data volume shows at <data>/TheIsle/Saved after the spec
# moves the mount to /mnt/isle/data.
LEGACY_SAVED = os.path.join(DATA_DIR, "TheIsle", "Saved")
MIGRATION_FILE = os.path.join(STATE_DIR, "migrated.json")
RCON_SECRET = os.path.join(STATE_DIR, "rcon.secret")
SAVED_DIR = os.path.join(DATA_DIR, "Saved")
GAME_INI = os.path.join(SAVED_DIR, "Config", "LinuxServer", "Game.ini")
BANS_FILE = os.path.join(SAVED_DIR, "PlayerData", "PlayerBans.json")
# IslePilot (islepilot.eu), a third party's plugin preloaded into the game when the owner turns it
# on. It keeps its key, config and log next to the library it was loaded from, so the entrypoint
# preloads it through a link in ISLEPILOT_DIR (synced: the key survives a move to another node)
# to the copy it downloads into the install (local: 11 MB that need no syncing).
ISLEPILOT_DIR = os.path.join(STATE_DIR, "islepilot")
ISLEPILOT_SWITCH = os.path.join(STATE_DIR, "islepilot.json")
ISLEPILOT_DOWNLOAD = os.path.join(STATE_DIR, "islepilot-download.json")
ISLEPILOT_CONFIG = os.path.join(ISLEPILOT_DIR, "islepilot-config.json")
ISLEPILOT_LOG = os.path.join(ISLEPILOT_DIR, "islepilot-plugin.log")
ISLEPILOT_LIB = "libisleplugin.so"
RCON_HOST = "127.0.0.1"
RCON_PORT = int(os.environ.get("FLUX_RCON_PORT", "8888"))

SESSION = "/Script/TheIsle.TIGameSession"
STATE_BASE = "/Script/TheIsle.TIGameStateBase"
# Unreal's own player cap, which AMP's template also writes: MaxPlayerCount is The Isle's, and the
# engine's GameSession default (16) is not guaranteed to follow it.
ENGINE_SESSION = "/Script/Engine.GameSession"

# Every class Evrima has as of build 24664709 (the AMP template's list, which the server's own
# AllowedClasses default matches). Unknown names are kept as typed: new classes ship with patches.
PLAYABLES = ["Diabloceratops", "Dryosaurus", "Hypsilophodon", "Maiasaura", "Pachycephalosaurus", "Stegosaurus",
             "Tenontosaurus", "Triceratops", "Allosaurus", "Carnotaurus", "Ceratosaurus", "Deinosuchus",
             "Dilophosaurus", "Herrerasaurus", "Omniraptor", "Pteranodon", "Troodon", "Tyrannosaurus",
             "Beipiaosaurus", "Gallimimus"]
AI_CLASSES = ["Compsognathus", "Pterodactylus", "Boar", "Deer", "Goat", "Seaturtle", "Rabbit", "Chicken",
              "Crab", "Frog", "Piranha", "Salmon"]

# Each setting: (ini section, ini key, kind, default). kind: bool, int, float, text, list.
SETTINGS = {
    "serverName": (SESSION, "ServerName", "text", "The Isle on Flux"),
    "maxPlayers": (SESSION, "MaxPlayerCount", "int", 50),
    "password": (SESSION, "ServerPassword", "text", ""),
    "queue": (SESSION, "bQueueEnabled", "bool", True),
    "discord": (SESSION, "Discord", "text", ""),
    "humans": (SESSION, "bEnableHumans", "bool", False),
    "globalChat": (SESSION, "bEnableGlobalChat", "bool", False),
    "fallDamage": (SESSION, "bServerFallDamage", "bool", True),
    "dynamicWeather": (SESSION, "bServerDynamicWeather", "bool", True),
    "minWeatherInterval": (SESSION, "MinWeatherVariationInterval", "int", 600),
    "maxWeatherInterval": (SESSION, "MaxWeatherVariationInterval", "int", 900),
    "dayLength": (SESSION, "ServerDayLengthMinutes", "int", 45),
    "nightLength": (SESSION, "ServerNightLengthMinutes", "int", 25),
    "spawnPlants": (SESSION, "bSpawnPlants", "bool", True),
    "plantMultiplier": (SESSION, "PlantSpawnMultiplier", "float", 1.0),
    "spawnAI": (SESSION, "bSpawnAI", "bool", True),
    "aiSpawnInterval": (SESSION, "AISpawnInterval", "int", 40),
    "aiDensity": (SESSION, "AIDensity", "float", 1.0),
    # One line per class (the AMP template's documented format: "DisallowedAIClasses=Compsognathus").
    "disallowedAI": (SESSION, "DisallowedAIClasses", "list", []),
    "migration": (SESSION, "bEnableMigration", "bool", True),
    "speciesMigrationTime": (SESSION, "SpeciesMigrationTime", "int", 10800),
    "massMigration": (SESSION, "bEnableMassMigration", "bool", True),
    "massMigrationTime": (SESSION, "MassMigrationTime", "int", 43200),
    "massMigrationDisableTime": (SESSION, "MassMigrationDisableTime", "int", 7200),
    "patrolZones": (SESSION, "bEnablePatrolZones", "bool", True),
    "diets": (SESSION, "bEnableDiets", "bool", True),
    "mutations": (SESSION, "bEnableMutations", "bool", False),
    "growthMultiplier": (SESSION, "GrowthMultiplier", "float", 1.0),
    "regionSpawning": (SESSION, "bUseRegionSpawning", "bool", False),
    "regionSpawnCooldown": (SESSION, "bUseRegionSpawnCooldown", "bool", False),
    "regionSpawnCooldownSeconds": (SESSION, "RegionSpawnCooldownTimeSeconds", "int", 30),
    "spawnCodes": (SESSION, "bEnableSpawnCodes", "bool", True),
    "corpseDecay": (SESSION, "CorpseDecayMultiplier", "float", 1.0),
    "recordReplay": (SESSION, "bAllowRecordingReplay", "bool", True),
    "whitelist": (SESSION, "bServerWhitelist", "bool", False),
    "admins": (STATE_BASE, "AdminsSteamIDs", "list", []),
    "whitelistIds": (STATE_BASE, "WhitelistIDs", "list", []),
    "vips": (STATE_BASE, "VIPs", "list", []),
    "playables": (STATE_BASE, "AllowedClasses", "list", PLAYABLES),
    "enabledMutations": (STATE_BASE, "EnabledMutations", "list", []),
}

# The environment variables the spec can set, and the setting each one is.
ENV = {
    "ISLE_SERVER_NAME": "serverName", "ISLE_MAX_PLAYERS": "maxPlayers", "ISLE_PASSWORD": "password",
    "ISLE_QUEUE": "queue", "ISLE_DISCORD": "discord", "ISLE_HUMANS": "humans", "ISLE_ADMINS": "admins",
    "ISLE_GROWTH_MULTIPLIER": "growthMultiplier", "ISLE_AI_DENSITY": "aiDensity", "ISLE_WHITELIST": "whitelist",
    "ISLE_GLOBAL_CHAT": "globalChat", "ISLE_MUTATIONS": "mutations",
}

# The RCON commands the panel uses, by name: (opcode, takes an argument).
OPS = {
    "announce": (0x10, True), "dm": (0x11, True), "wipecorpses": (0x13, False), "playables": (0x14, False),
    "addplayable": (0x1A, True), "removeplayable": (0x1B, True), "togglemigrations": (0x19, False),
    "ban": (0x20, True), "togglegrowth": (0x21, False), "growth": (0x22, True), "kick": (0x30, True),
    "players": (0x40, False), "save": (0x50, False), "playerdata": (0x77, False),
    "togglewhitelist": (0x81, False), "addwhitelist": (0x82, True), "removewhitelist": (0x83, True),
    "toggleglobalchat": (0x84, False), "togglehumans": (0x86, False), "toggleai": (0x90, False),
    "disableai": (0x91, True), "aidensity": (0x92, True), "queue": (0x93, False),
}

# Settings that RCON changes on a running server (the setting is saved for the next start too).
LIVE = {"aiDensity": "aidensity", "disallowedAI": "disableai"}


# ------------------------------------------------------------------------------------------------
# Files and values
# ------------------------------------------------------------------------------------------------

def read_json(path, default=None):
    try:
        with open(path, encoding="utf-8-sig") as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def write_text(path, text, mode=None):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".flux-")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(text)
    if mode is not None:
        os.chmod(tmp, mode)
    os.replace(tmp, path)


def write_json(path, data, indent=2):
    write_text(path, json.dumps(data, indent=indent, ensure_ascii=False) + "\n")


def out(data):
    print(json.dumps(data, ensure_ascii=False))


def fail(message, code=1):
    out({"ok": False, "error": message})
    sys.exit(code)


def load_settings():
    data = read_json(SETTINGS_FILE, {})
    return data if isinstance(data, dict) else {}


def steam_ids(value):
    items = value if isinstance(value, list) else re.split(r"[\s,;]+", str(value or ""))
    ids = []
    for item in items:
        item = str(item).strip()
        if re.fullmatch(r"7656119\d{10}", item) and item not in ids:
            ids.append(item)
    return ids


def coerce(name, value):
    """A setting's value as its kind, or raises ValueError with what is wrong."""
    _, _, kind, _ = SETTINGS[name]
    if kind == "bool":
        if isinstance(value, bool):
            return value
        v = str(value).strip().lower()
        if v in ("1", "true", "yes", "on"):
            return True
        if v in ("0", "false", "no", "off", ""):
            return False
        raise ValueError(f"{name} must be true or false")
    if kind == "int":
        if not re.fullmatch(r"-?\d{1,9}", str(value).strip()):
            raise ValueError(f"{name} must be a whole number")
        n = int(str(value).strip())
        if name == "maxPlayers" and not 1 <= n <= 300:
            raise ValueError("maxPlayers must be 1 to 300")
        if n < 0:
            raise ValueError(f"{name} cannot be negative")
        return n
    if kind == "float":
        try:
            f = float(str(value).strip())
        except ValueError:
            raise ValueError(f"{name} must be a number") from None
        if not 0 <= f <= 100:
            raise ValueError(f"{name} must be from 0 to 100")
        return f
    if name == "enabledMutations":
        return mutation_entries(value)
    if kind in ("list", "csv"):
        items = value if isinstance(value, list) else re.split(r"[\n,;]+", str(value or ""))
        items = [re.sub(r"[\x00-\x1f\x7f=]", "", str(i)).strip() for i in items]
        items = [i for i in items if i]
        if name in ("admins", "whitelistIds", "vips"):
            bad = [i for i in items if not re.fullmatch(r"7656119\d{10}", i)]
            if bad:
                raise ValueError(f"not a SteamID64: {', '.join(bad)}")
        if name in ("playables", "disallowedAI") and any(not re.fullmatch(r"[A-Za-z0-9_ ]{2,40}", i) for i in items):
            raise ValueError(f"{name}: class names are letters and digits")
        return list(dict.fromkeys(items))
    text = re.sub(r"[\x00-\x1f\x7f]", " ", str(value)).strip()
    return text[:100 if name != "discord" else 200]


MUTATION_STRUCT = re.compile(r'^\(\s*MutationName\s*=\s*"?([^",)]+?)"?\s*,\s*EffectValue\s*=\s*([0-9]*\.?[0-9]+)\s*\)$', re.I)
MUTATION_PAIR = re.compile(r"^([A-Za-z][A-Za-z ]{1,60}?)\s*,\s*([0-9]*\.?[0-9]+)$")


def mutation_entry(name, value):
    name = str(name).strip()
    if not re.fullmatch(r"[A-Za-z][A-Za-z ]{1,60}", name):
        raise ValueError(f"enabledMutations: {name!r} is not a mutation name")
    try:
        v = float(value)
    except (TypeError, ValueError):
        raise ValueError(f"enabledMutations: {name} needs a number") from None
    if not 0 <= v <= 100:
        raise ValueError(f"enabledMutations: {name} must be from 0 to 100")
    return f'(MutationName="{name}",EffectValue={v:g})'


def mutation_entries(value):
    """EnabledMutations as the game reads it: one `(MutationName="Hemomania",EffectValue=0.05)`
    per line, in [/Script/TheIsle.TIGameStateBase]. MEASURED on build 24664709: the
    "Hemomania, 0.05" form (the CubeCoders template's, and what 1.0.2 wrote) is refused by the
    engine, "ImportText (EnabledMutations): Missing opening parenthesis", so the list was empty.
    Taken in either form, or as {"name", "value"}, and always written as the struct."""
    items = value if isinstance(value, list) else [i for i in re.split(r"[\n;]+", str(value or "")) if i.strip()]
    out = []
    for item in items:
        if isinstance(item, dict):
            entry = mutation_entry(item.get("name", ""), item.get("value", item.get("chance")))
        else:
            text = re.sub(r"[\x00-\x1f\x7f]", "", str(item)).strip()
            if not text:
                continue
            m = MUTATION_STRUCT.match(text) or MUTATION_PAIR.match(text)
            if not m:
                raise ValueError(f"enabledMutations: cannot read {text!r}")
            entry = mutation_entry(m.group(1), m.group(2))
        if entry not in out:
            out.append(entry)
    return out


def effective_settings(settings=None):
    """(values, sources): every setting, from the environment when set, the panel, else the default."""
    settings = load_settings() if settings is None else settings
    values, sources = {}, {}
    env_for = {v: k for k, v in ENV.items()}
    for name, (_, _, _, default) in SETTINGS.items():
        env = env_for.get(name)
        if env and str(os.environ.get(env, "")).strip():
            try:
                values[name] = coerce(name, os.environ[env] if name != "admins" else steam_ids(os.environ[env]))
                sources[name] = "env"
                continue
            except ValueError:
                pass
        if name in settings:
            values[name] = settings[name]
            if name == "enabledMutations":
                # A list saved by 1.0.2 is in the form the game refuses; read it as the struct.
                try:
                    values[name] = mutation_entries(settings[name])
                except ValueError:
                    values[name] = []
            sources[name] = "panel"
        else:
            values[name] = default
            sources[name] = "default"
    return values, sources


# ------------------------------------------------------------------------------------------------
# Game.ini
# ------------------------------------------------------------------------------------------------

def ini_value(kind, value):
    if kind == "bool":
        return "true" if value else "false"
    if kind == "float":
        return f"{float(value):g}"
    if kind == "csv":
        return ",".join(value)
    return str(value)


def parse_ini(text):
    """[(section, [lines])] in order, comments and unknown keys kept."""
    sections, current = [], None
    for line in text.splitlines():
        m = re.match(r"^\s*\[(.+)\]\s*$", line)
        if m:
            current = (m.group(1), [])
            sections.append(current)
        elif current is None:
            sections.append((None, [line]))
            current = sections[-1]
        else:
            current[1].append(line)
    return sections


def render_game_ini(existing, values, rcon_password, rcon_port, queue_port, game_port=7777):
    """Game.ini with OUR keys written and everything else the file had kept. The server rewrites
    this file itself (it adds ;METADATA, drops quotes, writes values RCON changed): what it wrote
    stays unless it is a key we own, which is written from the settings on every start.

    QueryPort is the port the server registers with Epic Online Services (ADDRESSBOUND_s), and the
    in-game list sends players there. It does NOT follow -Port: without it the list said 7777 on a
    server bound to another port and every join timed out (measured on 0.21.784)."""
    owned = {}
    for name, (section, key, kind, _) in SETTINGS.items():
        owned.setdefault(section, {})[key] = (kind, values[name])
    extra = {ENGINE_SESSION: {"MaxPlayers": ("int", values["maxPlayers"])}, SESSION: {
        "MapName": ("text", "Gateway"), "bServerPassword": ("bool", bool(values["password"])),
        "bRconEnabled": ("bool", True), "RconPassword": ("text", rcon_password), "RconPort": ("int", rcon_port),
        "QueuePort": ("int", queue_port), "QueryPort": ("int", game_port),
    }}
    for section, keys in extra.items():
        owned.setdefault(section, {}).update(keys)
    sections = parse_ini(existing or "")
    seen = set()
    lines = []
    for section, body in sections:
        if section is None:
            lines += body
            continue
        lines.append(f"[{section}]")
        mine = owned.get(section, {})
        seen.add(section)
        for line in body:
            key = line.split("=", 1)[0].strip().lstrip("+-.!")
            if "=" in line and key in mine:
                continue
            if line.strip():
                lines.append(line)
        lines += key_lines(mine)
        lines.append("")
    for section in (SESSION, STATE_BASE, ENGINE_SESSION):
        if section not in seen:
            lines.append(f"[{section}]")
            lines += key_lines(owned[section])
            lines.append("")
    return "\n".join(lines).rstrip("\n") + "\n"


def key_lines(keys):
    lines = []
    for key, (kind, value) in keys.items():
        if kind == "list":
            lines += [f"{key}={item}" for item in value]
        else:
            lines.append(f"{key}={ini_value(kind, value)}")
    return lines


def rcon_password():
    try:
        with open(RCON_SECRET, encoding="utf-8") as f:
            value = f.read().strip()
            if value:
                return value
    except OSError:
        pass
    value = secrets.token_urlsafe(24)
    write_text(RCON_SECRET, value + "\n", mode=0o600)
    return value


def ban_steam_id(entry):
    """The banned player's SteamID64 in one PlayerBans.json entry ("steamId", measured)."""
    if isinstance(entry, dict):
        for key in ("steamId", "SteamId", "steamID", "SteamID", "playerSteamId"):
            if key in entry:
                return str(entry[key])
    return None


def banned_ids(entry):
    """The SteamID64s that name the BANNED player in an entry: its id field, and its name field
    when that holds a SteamID64. Never bannerSteamId."""
    ids = set()
    sid = ban_steam_id(entry)
    if sid:
        ids.add(sid)
    if isinstance(entry, dict) and STEAM_ID.fullmatch(str(entry.get("playerName", ""))):
        ids.add(str(entry["playerName"]))
    return ids


def ban_entries(data):
    if isinstance(data, list):
        return data
    if isinstance(data, dict):
        return data.get("bannedPlayerData") if isinstance(data.get("bannedPlayerData"), list) else \
            next((v for v in data.values() if isinstance(v, list)), [])
    return []


def apply_unbans(notes):
    pending = read_json(UNBAN_FILE)
    if not isinstance(pending, list) or not pending:
        return
    data = read_json(BANS_FILE)
    if isinstance(data, (list, dict)):
        entries = ban_entries(data)
        before = len(entries)
        # Exactly the banned player's own id: an entry also names the admin who banned
        # (bannerSteamId), and lifting a ban must never lift every ban that admin made. The id is
        # read from either of the player's own fields, because the panel shows whichever of
        # steamId and playerName holds one (both layouts have been seen in protocol notes).
        lift = {str(i) for i in pending}
        kept = [e for e in entries if not (banned_ids(e) & lift)]
        if isinstance(data, list):
            data = kept
        else:
            key = "bannedPlayerData" if isinstance(data.get("bannedPlayerData"), list) else \
                next((k for k, v in data.items() if isinstance(v, list)), "bannedPlayerData")
            data[key] = kept
        write_json(BANS_FILE, data)
        notes.append(f"bans lifted: {before - len(kept)}")
    try:
        os.remove(UNBAN_FILE)
    except OSError:
        pass


def cmd_apply():
    notes = []
    values, sources = effective_settings()
    existing = ""
    try:
        with open(GAME_INI, encoding="utf-8-sig", errors="replace") as f:
            existing = f.read()
    except OSError:
        pass
    text = render_game_ini(existing, values, rcon_password(), RCON_PORT, int(os.environ.get("ISLE_QUEUE_PORT", "10000")),
                           int(os.environ.get("ISLE_PORT", "7777")))
    write_text(GAME_INI, text)
    apply_unbans(notes)
    state = read_json(STATE_FILE, {}) or {}
    state["applied"] = int(time.time()) + 1
    write_json(STATE_FILE, state, indent=None)
    notes.append(f"Game.ini: {values['serverName']!r}, {values['maxPlayers']} players, password {'set' if values['password'] else 'none'}, queue {'on' if values['queue'] else 'off'}, {len(values['admins'])} admin(s)")
    changed = [n for n, s in sources.items() if s != "default"]
    notes.append(f"settings from env: {', '.join(n for n in changed if sources[n] == 'env') or '-'}; from the panel: {', '.join(n for n in changed if sources[n] == 'panel') or '-'}")
    for note in notes:
        print(f"# {note}")


# ------------------------------------------------------------------------------------------------
# RCON
# ------------------------------------------------------------------------------------------------

def rcon(commands, timeout=4.0):
    """[(opcode, argument)] on ONE connection: authorise, then each command. Returns the replies.
    Replies have no terminator: read until the socket is quiet."""
    def recv(s, first=timeout):
        s.settimeout(first)
        data = b""
        try:
            while True:
                chunk = s.recv(65536)
                if not chunk:
                    break
                data += chunk
                s.settimeout(0.6)
        except socket.timeout:
            pass
        return data.decode("utf-8", "replace")

    with socket.create_connection((RCON_HOST, RCON_PORT), timeout=timeout) as s:
        s.sendall(b"\x01" + rcon_password().encode() + b"\x00")
        auth = recv(s)
        if "Accepted" not in auth:
            raise RuntimeError(f"RCON refused the password ({auth.strip() or 'no answer'})")
        replies = []
        for op, arg in commands:
            s.sendall(b"\x02" + bytes([op]) + (arg or "").encode() + b"\x00")
            replies.append(recv(s, 2.0 if op not in (0x40, 0x77, 0x50) else timeout))
        return replies


def strip_stamp(text):
    return re.sub(r"^\[\d{4}\.\d{2}\.\d{2}-\d{2}\.\d{2}\.\d{2}\]\s*", "", text.strip())


STEAM_ID = re.compile(r"7656119\d{10}")


def reply_fields(line):
    """One line of a reply's fields: "a,b,c," -> ["a", "b", "c"]. Only the LAST comma is the
    terminator, so an empty field in the middle (a blank name) keeps its place."""
    line = line.strip()
    if line.endswith(","):
        line = line[:-1]
    return [f.strip() for f in line.split(",")]


def parse_players(text):
    """PlayerList: the SteamID64s and names of the players online.

    The layout is one line per FIELD, every player in the same order on each (the community
    clients read it so, e.g. the isle-evrima-rcon package):
        PlayerList
        <id>,<id>,
        <name>,<name>,
        <EOS id>,<EOS id>,
    The EOS line is not a name. A name holding a comma makes the names line longer than the ids
    line, and then which name is whose cannot be known: every name is left out (the panel shows the
    SteamID) rather than one being paired with the wrong player, since kick and ban act on the id.
    Older protocol notes show one field per line for each player ("<id>,\n<name>,\n" again and
    again); that is read too, a whole line being one name, commas and all."""
    body = text.split("PlayerList", 1)[-1]
    lines = [line for line in body.splitlines() if line.strip()]
    if not lines:
        return []
    first = reply_fields(lines[0])
    if not first or not all(STEAM_ID.fullmatch(f) for f in first):
        return []
    one_id_line = lambda line: (lambda f: len(f) == 1 and bool(STEAM_ID.fullmatch(f[0])))(reply_fields(line))
    if len(first) == 1 and len(lines) >= 3 and one_id_line(lines[2]):
        players, i = [], 0
        while i < len(lines):
            if one_id_line(lines[i]):
                nxt = lines[i + 1] if i + 1 < len(lines) and not one_id_line(lines[i + 1]) else None
                name = nxt.strip()[:-1].strip() if nxt is not None and nxt.strip().endswith(",") else (nxt or "").strip()
                players.append({"id": reply_fields(lines[i])[0], "name": name})
                i += 2 if nxt is not None else 1
            else:
                i += 1
        return players
    names = reply_fields(lines[1]) if len(lines) > 1 else []
    if len(names) != len(first) or any(STEAM_ID.fullmatch(n) for n in names):
        names = [""] * len(first)
    return [{"id": i, "name": n} for i, n in zip(first, names)]


def parse_queue(text):
    m = re.search(r"QueueEnabled\W+(\w+).*?QueueLength\W+(\d+).*?PendingConnections\W+(\d+)", text, re.S | re.I)
    if not m:
        return None
    return {"enabled": m.group(1).lower() in ("true", "on", "1"), "length": int(m.group(2)), "pending": int(m.group(3))}


def cmd_rcon(name, *args):
    if name not in OPS:
        fail(f"unknown command {name}; one of {', '.join(sorted(OPS))}", 64)
    op, takes = OPS[name]
    arg = ",".join(args) if args else ""
    if takes and not arg:
        fail(f"{name} needs an argument", 64)
    arg = re.sub(r"[\x00-\x1f\x7f]", " ", arg)[:500]
    if name in ("dm", "kick"):
        # "<steamid>,<text>": the text must not hold the separator, or the server may cut it (or
        # read the rest as more fields). Commas in it become semicolons.
        target, _, message = arg.partition(",")
        arg = f"{target.strip()},{message.replace(',', ';').strip()}"
    elif name == "ban":
        # "<name>,<steamid>,<reason>,<hours>": the SteamID and the hours are found by shape, and
        # commas anywhere else (a name, a reason typed with commas) become semicolons.
        parts = [p.strip() for p in arg.split(",")]
        at = next((i for i, p in enumerate(parts) if STEAM_ID.fullmatch(p)), None)
        if at is None or len(parts) < at + 3 or not re.fullmatch(r"\d{1,6}", parts[-1]):
            fail("ban needs name,SteamID64,reason,hours", 64)
        arg = ",".join([";".join(parts[:at]) or "Player", parts[at], ";".join(parts[at + 1:-1]) or "Banned by an admin", parts[-1]])
    elif name in ("announce",):
        arg = arg.strip()
    try:
        reply = rcon([(op, arg)])[0]
    except (OSError, RuntimeError) as e:
        fail(f"RCON: {e}", 3)
    result = {"ok": True, "command": name, "reply": strip_stamp(reply)}
    if name == "players":
        result["players"] = parse_players(reply)
    elif name == "queue":
        result["queue"] = parse_queue(reply)
    out(result)


# ------------------------------------------------------------------------------------------------
# State and status
# ------------------------------------------------------------------------------------------------

def cmd_state(state, message=None):
    data = read_json(STATE_FILE, {}) or {}
    if data.get("state") != state:
        data["since"] = int(time.time())
    data.update({"state": state, "message": message or None, "image": os.environ.get("FLUX_IMAGE_VERSION", "dev")})
    write_json(STATE_FILE, data, indent=None)


def installed_build():
    path = os.path.join(SERVER_DIR, "steamapps", "appmanifest_412680.acf")
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            m = re.search(r'"buildid"\s+"(\d+)"', f.read())
            return m.group(1) if m else None
    except OSError:
        return None


def changes_pending(state):
    if os.path.exists(UNBAN_FILE):
        return True
    try:
        return os.path.getmtime(SETTINGS_FILE) > (state.get("applied") or 0)
    except OSError:
        return False


def cmd_status():
    state = read_json(STATE_FILE, {}) or {}
    values, _ = effective_settings()
    players, queue, rcon_ok = [], None, False
    if state.get("state") == "running":
        try:
            pl, qu = rcon([(0x40, ""), (0x93, "")])
            players, queue, rcon_ok = parse_players(pl), parse_queue(qu), True
        except (OSError, RuntimeError):
            pass
    out({
        "state": state.get("state", "stopped"), "message": state.get("message"), "since": state.get("since"),
        "image": state.get("image"), "build": installed_build(), "map": "Gateway",
        "name": values["serverName"], "players": players, "max_players": values["maxPlayers"],
        "queue": queue, "rcon": rcon_ok, "pending": changes_pending(state),
        "legacyData": legacy_present(), "migrated": read_json(MIGRATION_FILE),
        "islepilot": {"enabled": islepilot_enabled(), "loaded": islepilot_loaded()},
    })


# ------------------------------------------------------------------------------------------------
# Panel: settings, bans, restart
# ------------------------------------------------------------------------------------------------

def cmd_settings(*what):
    """The settings. The join password is in it only when asked for (`settings password`, the
    Server Settings tab): the console and the other tabs read this every few seconds and have no
    use for it."""
    values, sources = effective_settings()
    values = dict(values)
    if sources.get("password") == "env":
        values["password"] = "(set in Deployment Settings)" if values["password"] else ""
    elif what != ("password",):
        values["password"] = ""
    out({"values": values, "sources": sources, "panel": {k: v for k, v in load_settings().items() if k != "password"},
         "passwordSet": bool(effective_settings()[0]["password"]),
         "choices": {"playables": PLAYABLES, "aiClasses": AI_CLASSES},
         "env": {k: v for k, v in ENV.items() if k in os.environ}})


def cmd_set_settings(raw):
    try:
        incoming = json.loads(raw)
    except ValueError:
        fail("not JSON")
    if not isinstance(incoming, dict):
        fail("expected a JSON object")
    settings = load_settings()
    errors, live = [], []
    for name, value in incoming.items():
        if name not in SETTINGS:
            errors.append(f"unknown setting {name}")
            continue
        if value is None:
            settings.pop(name, None)
            continue
        try:
            settings[name] = coerce(name, value)
        except ValueError as e:
            errors.append(str(e))
            continue
        if name in LIVE:
            live.append(name)
    if errors:
        fail("; ".join(errors), 2)
    write_json(SETTINGS_FILE, settings)
    applied = []
    state = read_json(STATE_FILE, {}) or {}
    if live and state.get("state") == "running":
        values, sources = effective_settings(settings)
        commands = []
        for name in live:
            if sources[name] == "env":
                continue
            value = values[name]
            commands.append((OPS[LIVE[name]][0], ",".join(value) if isinstance(value, list) else ini_value(SETTINGS[name][2], value)))
            applied.append(name)
        try:
            if commands:
                rcon(commands)
        except (OSError, RuntimeError):
            applied = []
    out({"ok": True, "settings": {k: v for k, v in settings.items() if k != "password"}, "appliedLive": applied,
         "appliesOn": "restart"})


def cmd_bans():
    data = read_json(BANS_FILE)
    out({"bans": data, "pending": read_json(UNBAN_FILE)})


def cmd_unban(steamid):
    if not re.fullmatch(r"7656119\d{10}", steamid):
        fail("not a SteamID64", 2)
    pending = read_json(UNBAN_FILE, []) or []
    if steamid not in pending:
        pending.append(steamid)
    write_json(UNBAN_FILE, pending)
    out({"ok": True, "pending": pending, "appliesOn": "restart"})


def cmd_restart():
    pids = subprocess.run(["pgrep", "-f", r"TheIsleServer-Linux-Shipping TheIsle "], capture_output=True, text=True).stdout.split()
    if not pids:
        fail("the server is not running", 3)
    with open(os.environ.get("FLUX_RESTART_MARKER", "/tmp/flux-restart-requested"), "w") as f:
        f.write("requested: from the panel\n")
    try:
        rcon([(0x50, "")])
    except (OSError, RuntimeError):
        pass
    import signal
    for pid in pids:
        try:
            os.kill(int(pid), signal.SIGTERM)
        except OSError:
            pass
    out({"ok": True})


# ------------------------------------------------------------------------------------------------
# IslePilot: a third party's plugin, off unless the owner turns it on
# ------------------------------------------------------------------------------------------------
#
# The plugin (Folgmann Studios, islepilot.eu) runs INSIDE the game process: it is preloaded into
# the server binary only (LD_PRELOAD on the game's exec, never on anything else: its constructor
# starts a thread in any process that loads it). It prints a key (ipk_ + 32 hex) on its first
# start and writes it to islepilot-config.json; the owner pastes the key on islepilot.eu to pair,
# and from then on the plugin talks to IslePilot over a WebSocket. Until the key is paired every
# connection is refused ("Invalid key", measured), which the plugin logs as a failed handshake.

KEY_RE = re.compile(r"ipk_[0-9a-f]{32}")


def islepilot_enabled():
    data = read_json(ISLEPILOT_SWITCH, {}) or {}
    return data.get("enabled") is True


def game_pids():
    return subprocess.run(["pgrep", "-f", r"TheIsleServer-Linux-Shipping TheIsle "], capture_output=True, text=True).stdout.split()


def islepilot_loaded():
    """True when the running server has the plugin mapped, None when no server runs."""
    pids = game_pids()
    if not pids:
        return None
    # Read as the server's own user: root in the container has no CAP_SYS_PTRACE, which reading
    # another user's maps takes.
    uid = os.environ.get("FLUX_UID", "1000")
    try:
        maps = subprocess.run(["setpriv", f"--reuid={uid}", f"--regid={uid}", "--clear-groups", "cat", f"/proc/{pids[0]}/maps"],
                              capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return ISLEPILOT_LIB in maps.stdout if maps.returncode == 0 else None


def islepilot_log_facts(lines):
    """What the plugin's own log says: its build, and whether its last WebSocket attempt connected."""
    build, connection, anticrash = None, None, 0
    for line in lines:
        m = re.search(r"\[build\] plugin build (\S+)", line)
        if m:
            build = m.group(1)
            connection = None
        if "[ws] connected to " in line:
            connection = "connected"
        elif "[ws] connect failed" in line:
            connection = "refused"
        if "ANTI-CRASH" in line:
            anticrash += 1
    return {"pluginBuild": build, "connection": connection, "anticrashRestarts": anticrash}


def islepilot_log_tail(count=60):
    try:
        with open(ISLEPILOT_LOG, encoding="utf-8", errors="replace") as f:
            lines = f.read().splitlines()
    except OSError:
        return []
    # From the newest start on: an older start's lines say nothing about this one.
    starts = [i for i, line in enumerate(lines) if "IslePilot plugin attached" in line]
    if starts:
        lines = lines[starts[-1]:]
    return lines[-count:] if count else lines


def cmd_islepilot(action=None):
    if action in ("on", "off"):
        write_json(ISLEPILOT_SWITCH, {"enabled": action == "on", "changed": int(time.time())})
        out({"ok": True, "enabled": action == "on", "appliesOn": "restart"})
        return
    if action == "reset-key":
        try:
            os.remove(ISLEPILOT_CONFIG)
        except FileNotFoundError:
            pass
        out({"ok": True, "appliesOn": "restart"})
        return
    if action is not None:
        fail("expected on, off or reset-key", 2)
    lines = islepilot_log_tail(0)
    facts = islepilot_log_facts(lines)
    config = read_json(ISLEPILOT_CONFIG, {}) or {}
    key = config.get("apiKey") if isinstance(config.get("apiKey"), str) and KEY_RE.fullmatch(config.get("apiKey")) else None
    enabled, loaded = islepilot_enabled(), islepilot_loaded()
    if not enabled:
        stage = "restart" if loaded else "off"
    elif loaded is None:
        stage = "stopped"
    elif not loaded:
        stage = "restart" if read_json(ISLEPILOT_DOWNLOAD, {}).get("ok") is not False else "unavailable"
    elif facts["connection"] == "connected":
        stage = "connected"
    else:
        stage = "unpaired" if key else "starting"
    out({
        "enabled": enabled, "loaded": loaded, "stage": stage, "apiKey": key,
        "download": read_json(ISLEPILOT_DOWNLOAD), **facts,
        # The key is shown above on purpose (the owner pastes it); never in the log lines.
        "log": [KEY_RE.sub("ipk_" + "•" * 8, line) for line in lines[-60:]],
    })


# ------------------------------------------------------------------------------------------------
# The previous image's layout: migrated on the first start of this one
# ------------------------------------------------------------------------------------------------

# What the previous image's synced install leaves on our data volume: the game, never data.
LEGACY_INSTALL = ("TheIsle", "Engine", "steamapps", "TheIsleServer.sh")
LEGACY_INSTALL_GLOBS = (r"^Manifest_\w+_Linux\.txt$",)


def legacy_present():
    return os.path.isdir(LEGACY_SAVED) or any(
        os.path.exists(os.path.join(DATA_DIR, n)) for n in ("Engine", "steamapps", "TheIsleServer.sh"))


def import_game_ini(text, settings, notes):
    """Every setting the old Game.ini holds that the panel does not already have: the owner's
    server keeps its name, rules, admins, classes and lists across the move."""
    sections = parse_ini(text)
    found = {}
    for section, body in sections:
        if section is None:
            continue
        for line in body:
            if "=" not in line or line.lstrip().startswith((";", "#", "//")):
                continue
            key, _, value = line.partition("=")
            found.setdefault((section.strip(), key.strip().lstrip("+-.!")), []).append(value.strip().strip('"'))
    imported = []
    for name, (section, key, kind, _) in SETTINGS.items():
        values = found.get((section, key))
        if not values or name in settings:
            continue
        try:
            settings[name] = coerce(name, values if kind == "list" else values[-1])
            imported.append(name)
        except ValueError:
            notes.append(f"WARN the old Game.ini's {key}={values[-1]!r} could not be kept")
    return imported


def import_additional_commands(value, settings):
    """The previous image's `additionalcommands` env: -ini:Game:[section]:Key=Value overrides
    (ServerName, MaxPlayerCount, bQueueEnabled... set by the old marketplace spec)."""
    by_key = {(sec, key): name for name, (sec, key, _, _) in SETTINGS.items()}
    imported = []
    for sec, key, val in re.findall(r"-ini:Game:\[([^\]]+)\]:([A-Za-z0-9_]+)=(\S+)", value or ""):
        name = by_key.get((sec, key))
        if name and name not in settings:
            try:
                settings[name] = coerce(name, val)
                imported.append(name)
            except ValueError:
                pass
    return imported


def cmd_migrate_legacy():
    """Moves a server from the previous image's layout, once and idempotently:
      1. a safety backup of the old saves (flux/backups/<date>-theisle-legacy.tar.gz)
      2. the old Game.ini's settings (and the old env's -ini overrides) into the panel's settings
      3. TheIsle/Saved -> Saved: the player database, Game.ini, bans. If Saved already holds a
         player database (this image ran before), the old one is kept aside, never merged
      4. the old install (Engine/, TheIsle/, steamapps/...) removed from the SYNCED volume: it is
         the game, re-downloaded onto the local volume, and 1.5 GB of it synced for nothing."""
    notes = []
    if not legacy_present():
        return
    os.makedirs(STATE_DIR, exist_ok=True)
    settings = load_settings()
    if os.path.isdir(LEGACY_SAVED) and not os.path.islink(LEGACY_SAVED):
        os.makedirs(BACKUP_DIR, exist_ok=True)
        stamp = time.strftime("%Y%m%d-%H%M%S", time.gmtime())
        archive = os.path.join(BACKUP_DIR, f"{stamp}-theisle-legacy.tar.gz")
        r = subprocess.run(["tar", "-C", os.path.dirname(LEGACY_SAVED), "--exclude=Saved/Logs", "--exclude=Saved/Demos",
                            "--exclude=Saved/Crashes", "-czf", archive + ".part", "Saved"], capture_output=True)
        if r.returncode in (0, 1) and os.path.getsize(archive + ".part") > 0:
            os.replace(archive + ".part", archive)
            notes.append(f"legacy: safety backup flux/backups/{os.path.basename(archive)}")
        else:
            try:
                os.remove(archive + ".part")
            except OSError:
                pass
            print("# ERROR legacy: the safety backup of the old saves failed; nothing moved")
            sys.exit(2)
        old_ini = os.path.join(LEGACY_SAVED, "Config", "LinuxServer", "Game.ini")
        try:
            imported = import_game_ini(open(old_ini, encoding="utf-8-sig", errors="replace").read(), settings, notes)
        except OSError:
            imported = []
        imported += import_additional_commands(os.environ.get("additionalcommands", ""), settings)
        if imported:
            write_json(SETTINGS_FILE, settings)
            notes.append(f"legacy: settings kept from the old server: {', '.join(sorted(set(imported)))}")
        os.makedirs(SAVED_DIR, exist_ok=True)
        new_db = os.path.join(SAVED_DIR, "PlayerData", "TheIslePersistence.db")
        if os.path.exists(new_db) and os.path.exists(os.path.join(LEGACY_SAVED, "PlayerData")):
            aside = os.path.join(STATE_DIR, f"legacy-saved-{stamp}")
            shutil.move(LEGACY_SAVED, aside)
            notes.append(f"legacy: this server already has a player database; the old saves are kept in flux/{os.path.basename(aside)}")
        else:
            for child in os.listdir(LEGACY_SAVED):
                src, dst = os.path.join(LEGACY_SAVED, child), os.path.join(SAVED_DIR, child)
                if os.path.isdir(src) and os.path.isdir(dst):
                    for root, dirs, files in os.walk(src):
                        rel = os.path.relpath(root, src)
                        os.makedirs(os.path.join(dst, rel), exist_ok=True)
                        for f in files:
                            os.replace(os.path.join(root, f), os.path.join(dst, rel, f))
                else:
                    if os.path.exists(dst):
                        shutil.rmtree(dst) if os.path.isdir(dst) and not os.path.islink(dst) else os.remove(dst)
                    shutil.move(src, dst)
            shutil.rmtree(LEGACY_SAVED, ignore_errors=True)
            notes.append("legacy: the player database, Game.ini and bans moved to Saved/")
    removed = []
    for name in os.listdir(DATA_DIR):
        path = os.path.join(DATA_DIR, name)
        if name in LEGACY_INSTALL or any(re.match(g, name) for g in LEGACY_INSTALL_GLOBS):
            if name == "TheIsle" and os.path.isdir(os.path.join(path, "Saved")) and not os.path.islink(os.path.join(path, "Saved")):
                continue  # never delete saves that were not moved
            if os.path.isdir(path) and not os.path.islink(path):
                shutil.rmtree(path, ignore_errors=True)
            else:
                try:
                    os.remove(path)
                except OSError:
                    pass
            removed.append(name)
    if removed:
        notes.append(f"legacy: the old install removed from the synced volume ({', '.join(sorted(removed))})")
    write_json(MIGRATION_FILE, {"at": int(time.time()), "notes": notes})
    for note in notes:
        print(f"# {note}")


# ------------------------------------------------------------------------------------------------
# Backups and restore
# ------------------------------------------------------------------------------------------------

BACKUP_RE = re.compile(r"^(\d{8}-\d{6})-theisle(?:-([a-z-]+))?\.tar\.gz$")


def list_backups():
    items = []
    if os.path.isdir(BACKUP_DIR):
        for name in os.listdir(BACKUP_DIR):
            m = BACKUP_RE.match(name)
            if not m:
                continue
            st = os.stat(os.path.join(BACKUP_DIR, name))
            items.append({"name": name, "size": st.st_size, "at": int(st.st_mtime), "why": m.group(2) or "backup"})
    return sorted(items, key=lambda b: b["name"], reverse=True)


def cmd_backups():
    out({"backups": list_backups(), "path": "flux/backups"})


def backups_to_prune(backups, keep, now):
    """backups: [{"name", "at"}] (any order). The ones to delete: everything but the newest `keep`,
    the newest one older than a day and the newest older than a week (a crash loop can never rotate
    every good backup away), and the previous image's safety backup (made once)."""
    ordered = sorted(backups, key=lambda b: b["name"], reverse=True)
    kept = {b["name"] for b in ordered[:max(keep, 1)]}
    for age in (86400, 7 * 86400):
        older = next((b for b in ordered if now - b["at"] >= age), None)
        if older:
            kept.add(older["name"])
    kept |= {b["name"] for b in ordered if b["name"].endswith("-legacy.tar.gz")}
    return [b["name"] for b in ordered if b["name"] not in kept]


def cmd_prune_backups(keep):
    for name in backups_to_prune(list_backups(), int(keep), int(time.time())):
        try:
            os.remove(os.path.join(BACKUP_DIR, name))
            print(f"# backup pruned: flux/backups/{name}")
        except OSError:
            pass


def cmd_restore(name):
    """Asks the supervisor to restore a backup: it stops the server (a clean shutdown writes the
    database), keeps a safety backup of what is there now, puts the backup in place and starts."""
    if not BACKUP_RE.match(name or "") or os.path.basename(name) != name:
        fail("not a backup name (see flux-isle backups)", 2)
    if not os.path.isfile(os.path.join(BACKUP_DIR, name)):
        fail("no such backup", 2)
    with open(RESTORE_MARKER, "w") as f:
        f.write(name + "\n")
    pids = subprocess.run(["pgrep", "-f", r"TheIsleServer-Linux-Shipping TheIsle "], capture_output=True, text=True).stdout.split()
    if pids:
        with open(os.environ.get("FLUX_RESTART_MARKER", "/tmp/flux-restart-requested"), "w") as f:
            f.write(f"requested: restore {name}\n")
        import signal
        for pid in pids:
            try:
                os.kill(int(pid), signal.SIGTERM)
            except OSError:
                pass
    out({"ok": True, "restore": name, "appliesOn": "now" if pids else "next start"})


def main(argv):
    commands = {
        "apply": (cmd_apply, (0,)), "state": (cmd_state, (1, 2)), "rcon-password": (lambda: print(rcon_password()), (0,)),
        "status": (cmd_status, (0,)), "rcon": (cmd_rcon, tuple(range(1, 10))), "settings": (cmd_settings, (0, 1)),
        "set-settings": (cmd_set_settings, (1,)), "bans": (cmd_bans, (0,)), "unban": (cmd_unban, (1,)),
        "restart": (cmd_restart, (0,)), "backups": (cmd_backups, (0,)), "restore": (cmd_restore, (1,)),
        "prune-backups": (cmd_prune_backups, (1,)),
        "migrate-legacy": (cmd_migrate_legacy, (0,)),
        "islepilot": (cmd_islepilot, (0, 1)),
        "islepilot-enabled": (lambda: sys.exit(0 if islepilot_enabled() else 1), (0,)),
    }
    if not argv or argv[0] not in commands or len(argv) - 1 not in commands[argv[0]][1]:
        print(__doc__, file=sys.stderr)
        return 64
    commands[argv[0]][0](*argv[1:])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
