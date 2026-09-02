# syntax=docker/dockerfile:1
# =============================================================================
# Tor proxy image(s) — SOCKS5 + Hidden Service, plus an optional Privoxy
# front-end, from one shared Dockerfile
# =============================================================================
#
# Two independent final targets share the same "base" package layer:
#   - "tor"          the Tor daemon itself (SOCKS5/ControlPort/HS/bridges/
#                     node selection — all runtime toggles, see
#                     entrypoint.sh).
#   - "tor-privoxy"   Privoxy ONLY, configured to forward through a Tor
#                     SOCKS5 proxy reachable over the network (typically a
#                     separate "tor" container — see the "tor-privoxy"
#                     example service in docker-compose.yml). This does
#                     NOT run Tor itself in the same container; it's an
#                     HTTP/HTTPS-proxy front-end for clients that can't
#                     speak SOCKS.
#
# Base image ref is pinned by digest and passed in from docker-bake.hcl
# (via pinned_ref()) rather than hardcoded here — see that file's
# ALPINE_BASE variable for the actual name:tag@digest value.
ARG ALPINE_REF=docker.io/library/alpine:edge@sha256:020dfcbaaf4cc1078bf2d9c7ba31a8466e334061dcd2f248001d68f79e52c000

ARG TOR_VERSION=0.4.9.11-r0
ARG NYX_VERSION=2.1.0-r6
ARG LYREBIRD_VERSION=0.8.1-r6
ARG PRIVOXY_VERSION=3.0.35-r0
# ^ used only by the "tor-privoxy" stage below; declared at top-level (not
# inline in that stage) purely so docker-bake.hcl can override it the same
# way it overrides TOR_VERSION/NYX_VERSION/LYREBIRD_VERSION — global ARGs
# declared before the first FROM are the only ones a bake `variable` can
# reach without extra plumbing.


# =============================================================================
# base — packages + entrypoint scripts common setup only, no ENTRYPOINT/CMD
# and no runtime config. Shared by every downstream stage so it's the
# layer most likely to hit build cache. Deliberately stops short of
# setting ENTRYPOINT/CMD, since "tor" and "tor-privoxy" below need
# different ones — each final stage sets its own.
# =============================================================================
FROM ${ALPINE_REF} AS base

ARG TOR_VERSION
ARG NYX_VERSION
ARG LYREBIRD_VERSION

# NOTE: privoxy is intentionally NOT installed here — it's only pulled in
# by the "tor-privoxy" stage below, so the plain "tor" image doesn't carry
# a package it never runs.
RUN apk add --no-cache \
        curl \
        bash \
        su-exec \
        "tor=${TOR_VERSION}" \
        "nyx=${NYX_VERSION}" \
        "lyrebird=${LYREBIRD_VERSION}" \
    && rm -rf /var/cache/apk/*


# =============================================================================
# tor — the single runtime stage. SOCKS/control/hidden-service/node-
# selection/bridges are all runtime toggles (entrypoint.sh writes torrc
# from TORRC_* env vars), so every deployment shape is the same image
# with different defaults/ports at `docker run` time, not different
# build targets.
#
# All runtime-config args/env below are prefixed TORRC_ to namespace them
# as "things that end up in torrc" — this matches entrypoint.sh's env
# vars exactly, so a build-time ARG default flows straight through to
# the same-named runtime ENV.
# =============================================================================
FROM base AS tor

COPY --chmod=755 entrypoint.sh /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
CMD ["tor"]

ARG TOR_VERSION
ARG TORRC_ENABLE_SOCKS=false
ARG TORRC_ENABLE_CONTROL=false
ARG TORRC_ENABLE_HS=false
ARG TORRC_SOCKS_PORT=9050
ARG TORRC_CONTROL_PORT=9051
ARG TORRC_HS_PORT=80
ARG TORRC_HS_TARGET=127.0.0.1:80
ARG TORRC_HS_PORTS=""
ARG TORRC_EXIT_NODES=""
ARG TORRC_ENTRY_NODES=""
ARG TORRC_EXCLUDE_NODES=""
ARG TORRC_EXCLUDE_EXIT_NODES=""
ARG TORRC_STRICT_NODES=false
ARG TORRC_ENABLE_BRIDGES=false
ARG TORRC_BRIDGE_LINES=""
ARG TORRC_BRIDGE_TRANSPORT=obfs4
ARG TORRC_LYREBIRD_PATH=/usr/bin/lyrebird

ENV TOR_VERSION=${TOR_VERSION} \
    TORRC_ENABLE_SOCKS=${TORRC_ENABLE_SOCKS} \
    TORRC_ENABLE_CONTROL=${TORRC_ENABLE_CONTROL} \
    TORRC_ENABLE_HS=${TORRC_ENABLE_HS} \
    TORRC_SOCKS_PORT=${TORRC_SOCKS_PORT} \
    TORRC_CONTROL_PORT=${TORRC_CONTROL_PORT} \
    TORRC_HS_PORT=${TORRC_HS_PORT} \
    TORRC_HS_TARGET=${TORRC_HS_TARGET} \
    TORRC_HS_PORTS=${TORRC_HS_PORTS} \
    TORRC_HS_SECRET_KEY_FILE=/run/secrets/tor_hs_ed25519_secret_key \
    TORRC_EXIT_NODES=${TORRC_EXIT_NODES} \
    TORRC_ENTRY_NODES=${TORRC_ENTRY_NODES} \
    TORRC_EXCLUDE_NODES=${TORRC_EXCLUDE_NODES} \
    TORRC_EXCLUDE_EXIT_NODES=${TORRC_EXCLUDE_EXIT_NODES} \
    TORRC_STRICT_NODES=${TORRC_STRICT_NODES} \
    TORRC_ENABLE_BRIDGES=${TORRC_ENABLE_BRIDGES} \
    TORRC_BRIDGE_LINES=${TORRC_BRIDGE_LINES} \
    TORRC_BRIDGE_TRANSPORT=${TORRC_BRIDGE_TRANSPORT} \
    TORRC_LYREBIRD_PATH=${TORRC_LYREBIRD_PATH}

EXPOSE ${TORRC_SOCKS_PORT} ${TORRC_CONTROL_PORT}

HEALTHCHECK --interval=300s --timeout=15s --start-period=60s --start-interval=10s \
    CMD sh -c '[ "$TORRC_ENABLE_SOCKS" != "true" ] || curl -x socks5h://127.0.0.1:${TORRC_SOCKS_PORT} "https://check.torproject.org/api/ip" | grep -qm1 "\"IsTor\"[[:space:]]*:[[:space:]]*true"'

# tor user/group come from the apk "tor" package; drop root only when
# we don't need to chown the HS/data dir at startup as root first —
# entrypoint.sh still runs as root to fix permissions, then execs tor
# via su-exec-style drop if desired. Left as root here since
# entrypoint.sh performs chown; switch to USER tor if you remove that step.


# =============================================================================
# tor-privoxy — Privoxy front-end ONLY. Does not run Tor; forwards to a
# Tor SOCKS5 proxy reachable over the network (PRIVOXY_TOR_SOCKS_HOST/
# PORT). Built from "base" (shares the curl/bash/su-exec layer + Tor
# packages already cached from the "tor" target) with privoxy layered on
# top, so building both targets doesn't redownload the common packages.
#
# All runtime-config args/env below are prefixed PRIVOXY_ to mirror the
# TORRC_ convention used by the "tor" stage — same idea, different
# process/config file (/etc/privoxy/config vs /etc/tor/torrc).
# =============================================================================
FROM base AS tor-privoxy

ARG PRIVOXY_VERSION

RUN apk add --no-cache "privoxy=${PRIVOXY_VERSION}" \
    && rm -rf /var/cache/apk/*

COPY --chmod=755 privoxy-entrypoint.sh /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
CMD ["privoxy"]

ARG PRIVOXY_LISTEN_ADDRESS=0.0.0.0
ARG PRIVOXY_LISTEN_PORT=8118
ARG PRIVOXY_TOR_SOCKS_HOST=tor
ARG PRIVOXY_TOR_SOCKS_PORT=9050
ARG PRIVOXY_FORWARD_DNS=true
ARG PRIVOXY_ENABLE_FILTERS=true
ARG PRIVOXY_ENABLE_LOGGING=false
ARG PRIVOXY_TRUSTED_CIDRS=""

ENV PRIVOXY_VERSION=${PRIVOXY_VERSION} \
    PRIVOXY_LISTEN_ADDRESS=${PRIVOXY_LISTEN_ADDRESS} \
    PRIVOXY_LISTEN_PORT=${PRIVOXY_LISTEN_PORT} \
    PRIVOXY_TOR_SOCKS_HOST=${PRIVOXY_TOR_SOCKS_HOST} \
    PRIVOXY_TOR_SOCKS_PORT=${PRIVOXY_TOR_SOCKS_PORT} \
    PRIVOXY_FORWARD_DNS=${PRIVOXY_FORWARD_DNS} \
    PRIVOXY_ENABLE_FILTERS=${PRIVOXY_ENABLE_FILTERS} \
    PRIVOXY_ENABLE_LOGGING=${PRIVOXY_ENABLE_LOGGING} \
    PRIVOXY_TRUSTED_CIDRS=${PRIVOXY_TRUSTED_CIDRS}

EXPOSE ${PRIVOXY_LISTEN_PORT}

# Privoxy has its own lightweight liveness endpoint (the CGI status/
# config page it serves on every listener) — hitting it confirms the
# process is up and actually answering HTTP, not just that the port is
# open.
HEALTHCHECK --interval=300s --timeout=15s --start-period=30s --start-interval=10s \
    CMD curl -s -o /dev/null -x "http://127.0.0.1:${PRIVOXY_LISTEN_PORT}" "http://p.p/" || exit 1

# privoxy user/group come from the apk "privoxy" package. Same rationale
# as the "tor" stage: entrypoint runs as root briefly to chown
# /etc/privoxy and /var/log/privoxy, then drops to the privoxy user via
# su-exec before exec'ing the daemon.
