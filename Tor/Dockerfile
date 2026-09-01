# syntax=docker/dockerfile:1
# =============================================================================
# Tor proxy image — SOCKS5 + Hidden Service, single unified Dockerfile
# =============================================================================
#
# Base image ref is pinned by digest and passed in from docker-bake.hcl
# (via pinned_ref()) rather than hardcoded here — see that file's
# ALPINE_BASE variable for the actual name:tag@digest value.
ARG ALPINE_REF=docker.io/library/alpine:edge@sha256:020dfcbaaf4cc1078bf2d9c7ba31a8466e334061dcd2f248001d68f79e52c000

ARG TOR_VERSION=0.4.9.11-r0
ARG NYX_VERSION=2.1.0-r6
ARG LYREBIRD_VERSION=0.8.1-r6


# =============================================================================
# base — packages only, no runtime config. Shared by every downstream
# stage so it's the layer most likely to hit build cache.
# =============================================================================
FROM ${ALPINE_REF} AS base

ARG TOR_VERSION
ARG NYX_VERSION
ARG LYREBIRD_VERSION

ENV TOR_VERSION=${TOR_VERSION} \
    NYX_VERSION=${NYX_VERSION} \
    LYREBIRD_VERSION=${LYREBIRD_VERSION}

RUN apk add --no-cache \
        curl \
        bash \
        su-exec \
        "tor=${TOR_VERSION}" \
        "nyx=${NYX_VERSION}" \
        "lyrebird=${LYREBIRD_VERSION}" \
    && rm -rf /var/cache/apk/*

COPY --chmod=755 entrypoint.sh /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
CMD ["tor"]


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
