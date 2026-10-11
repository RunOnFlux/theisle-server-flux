# The Isle (Evrima) dedicated server image for Flux.
#
# Written from scratch. The game's Linux server (Steam app 412680, branch evrima), installed and
# updated with SteamCMD on every start, run as an unprivileged user under a supervisor that writes
# Game.ini from the environment and the hub's panel, keeps the RCON private (it authorises by IP
# address, so it is never published), saves on stop, follows Evrima updates with in-game warnings,
# keeps backups, and gives the hub JSON status and RCON commands. See README.md.
FROM steamcmd/steamcmd:ubuntu-24

ARG DEBIAN_FRONTEND=noninteractive
ARG FLUX_IMAGE_VERSION=dev

# python3, NOT python3-minimal: fluxisle.py needs json and socket. util-linux brings setpriv.
RUN apt-get update -y && \
    apt-get install -y --no-install-recommends ca-certificates curl procps tzdata python3 util-linux && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

COPY scripts/flux-lib.sh scripts/flux-entrypoint.sh scripts/fluxisle.py /opt/flux/
RUN chmod 0755 /opt/flux/*.sh /opt/flux/fluxisle.py && \
    ln -s /opt/flux/fluxisle.py /usr/local/bin/flux-isle

# SteamCMD's self-update, done once here; the weekly rebuild keeps it current. The server runs as
# uid 1000 (the base image's `ubuntu` user): Unreal servers refuse to run as root.
RUN steamcmd +quit >/dev/null 2>&1; test -d /root/.local/share/Steam && getent passwd 1000 >/dev/null

ENV FLUX_IMAGE_VERSION=${FLUX_IMAGE_VERSION}

VOLUME ["/mnt/isle/server", "/mnt/isle/data"]

# The game (UDP) and the join queue (TCP). The RCON (8888/tcp) is deliberately NOT exposed.
EXPOSE 7777/udp 10000/tcp

HEALTHCHECK --interval=60s --timeout=10s --start-period=20m --retries=3 \
    CMD pgrep -f "TheIsleServer-Linux-Shipping TheIsle " >/dev/null || exit 1

ENTRYPOINT []
CMD ["/opt/flux/flux-entrypoint.sh"]
