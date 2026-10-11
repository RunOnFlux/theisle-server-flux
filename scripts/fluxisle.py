#!/usr/bin/env python3
"""Every decision about The Isle (Evrima) server's files, its RCON, and the hub's commands.

    fluxisle.py apply                  write Game.ini from the environment and the panel (before every start)
    fluxisle.py state <state> [msg]    record what the supervisor is doing (flux/state.json)
    fluxisle.py rcon-password          print the RCON password (made once, kept on the data volume)

    flux-isle status                   state, players, queue, version (one JSON document)
    flux-isle rcon <op> [args]         one RCON command by name (see OPS), its reply as JSON
    flux-isle settings                 the panel's settings, the env that overrides them, the choices
    flux-isle set-settings '<json>'    save settings; the ones RCON can change are applied live too
    flux-isle bans                     PlayerBans.json
    flux-isle unban <steamid>          lifted on the next start (the server owns the file while it runs)
    flux-isle restart                  save, stop and start again

THE RCON IS NEVER PUBLISHED. The Isle's RCON authorises an IP address once a password was right,
not a connection: anyone behind the same address gets in afterwards with no password (measured).
It listens on RconPort inside the container and only the panel's exec reaches it, on 127.0.0.1.
ServerDetails prints the join password in plain text, so its reply is never passed on whole.

Precedence, the same everywhere: an environment variable that is SET (even to "") is applied on
every start; one that is not set leaves the panel's value, then the default.
"""

import json
import os
import re
import secrets
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
RCON_SECRET = os.path.join(STATE_DIR, "rcon.secret")
SAVED_DIR = os.path.join(DATA_DIR, "Saved")
GAME_INI = os.path.join(SAVED_DIR, "Config", "LinuxServer", "Game.ini")
BANS_FILE = os.path.join(SAVED_DIR, "PlayerData", "PlayerBans.json")
RCON_HOST = "127.0.0.1"
RCON_PORT = int(os.environ.get("FLUX_RCON_PORT", "8888"))

SESSION = "/Script/TheIsle.TIGameSession"
STATE_BASE = "/Script/TheIsle.TIGameStateBase"

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
    "disallowedAI": (SESSION, "DisallowedAIClasses", "csv", []),
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


def effective_settings(settings=None):
    """(values, sources): every setting, from the environment when set, the panel, else the default."""
    settings = load_settings() if settings is None else settings
    values, sources = {}, {}
    env_for = {v: k for k, v in ENV.items()}
    for name, (_, _, _, default) in SETTINGS.items():
        env = env_for.get(name)
        if env and env in os.environ:
            try:
                values[name] = coerce(name, os.environ[env] if name != "admins" else steam_ids(os.environ[env]))
                sources[name] = "env"
                continue
            except ValueError:
                pass
        if name in settings:
            values[name] = settings[name]
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


def render_game_ini(existing, values, rcon_password, rcon_port, queue_port):
    """Game.ini with OUR keys written and everything else the file had kept. The server rewrites
    this file itself (it adds ;METADATA, drops quotes, writes values RCON changed): what it wrote
    stays unless it is a key we own, which is written from the settings on every start."""
    owned = {}
    for name, (section, key, kind, _) in SETTINGS.items():
        owned.setdefault(section, {})[key] = (kind, values[name])
    extra = {SESSION: {
        "MapName": ("text", "Gateway"), "bServerPassword": ("bool", bool(values["password"])),
        "bRconEnabled": ("bool", True), "RconPassword": ("text", rcon_password), "RconPort": ("int", rcon_port),
        "QueuePort": ("int", queue_port),
    }}
    for section, keys in extra.items():
        owned[section].update(keys)
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
    for section in (SESSION, STATE_BASE):
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


def apply_unbans(notes):
    pending = read_json(UNBAN_FILE)
    if not isinstance(pending, list) or not pending:
        return
    data = read_json(BANS_FILE)
    if isinstance(data, (list, dict)):
        entries = data if isinstance(data, list) else next((v for v in data.values() if isinstance(v, list)), [])
        before = len(entries)
        kept = [e for e in entries if not any(str(i) in json.dumps(e) for i in pending)]
        if isinstance(data, list):
            data = kept
        else:
            for k, v in data.items():
                if isinstance(v, list):
                    data[k] = kept
                    break
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
    text = render_game_ini(existing, values, rcon_password(), RCON_PORT, int(os.environ.get("ISLE_QUEUE_PORT", "10000")))
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


def parse_players(text):
    """PlayerList: SteamID64 and name pairs after the header, each field ended by a comma (the
    community's protocol notes; separators between players are not documented, so this reads any
    run of "<17-digit id>" then "<name>")."""
    body = text.split("PlayerList", 1)[-1]
    tokens = [t.strip() for t in re.split(r"[,\n]", body) if t.strip()]
    players, i = [], 0
    while i < len(tokens):
        if re.fullmatch(r"7656119\d{10}", tokens[i]):
            name = tokens[i + 1] if i + 1 < len(tokens) and not re.fullmatch(r"7656119\d{10}", tokens[i + 1]) else ""
            players.append({"id": tokens[i], "name": name})
            i += 2 if name else 1
        else:
            i += 1
    return players


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
    })


# ------------------------------------------------------------------------------------------------
# Panel: settings, bans, restart
# ------------------------------------------------------------------------------------------------

def cmd_settings():
    values, sources = effective_settings()
    values = dict(values)
    if sources.get("password") == "env":
        values["password"] = "(set in Deployment Settings)" if values["password"] else ""
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


def main(argv):
    commands = {
        "apply": (cmd_apply, (0,)), "state": (cmd_state, (1, 2)), "rcon-password": (lambda: print(rcon_password()), (0,)),
        "status": (cmd_status, (0,)), "rcon": (cmd_rcon, tuple(range(1, 10))), "settings": (cmd_settings, (0,)),
        "set-settings": (cmd_set_settings, (1,)), "bans": (cmd_bans, (0,)), "unban": (cmd_unban, (1,)),
        "restart": (cmd_restart, (0,)),
    }
    if not argv or argv[0] not in commands or len(argv) - 1 not in commands[argv[0]][1]:
        print(__doc__, file=sys.stderr)
        return 64
    commands[argv[0]][0](*argv[1:])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
