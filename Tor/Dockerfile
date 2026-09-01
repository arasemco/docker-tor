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
# tor — the single runtime stage. SOCKS/control/hidden-service are all
# runtime toggles (entrypoint.sh writes torrc from env), so "socks",
# "hs", and "all" are the same image with different defaults/ports —
# no need for separate build stages per variant.
# =============================================================================
FROM base AS tor

ARG TOR_VERSION
ARG ENABLE_SOCKS=false
ARG ENABLE_CONTROL=false
ARG ENABLE_HS=false
ARG SOCKS_PORT=9050
ARG CONTROL_PORT=9051
ARG HS_PORT=80
ARG HS_TARGET=127.0.0.1:80
ARG HS_PORTS=""

ENV TOR_VERSION=${TOR_VERSION} \
    ENABLE_SOCKS=${ENABLE_SOCKS} \
    ENABLE_CONTROL=${ENABLE_CONTROL} \
    ENABLE_HS=${ENABLE_HS} \
    SOCKS_PORT=${SOCKS_PORT} \
    CONTROL_PORT=${CONTROL_PORT} \
    HS_PORT=${HS_PORT} \
    HS_TARGET=${HS_TARGET} \
    HS_PORTS=${HS_PORTS} \
    HS_SECRET_KEY_FILE=/run/secrets/tor_hs_ed25519_secret_key

EXPOSE ${SOCKS_PORT} ${CONTROL_PORT}

HEALTHCHECK --interval=300s --timeout=15s --start-period=60s --start-interval=10s \
    CMD sh -c '[ "$ENABLE_SOCKS" != "true" ] || curl -x socks5h://127.0.0.1:${SOCKS_PORT} "https://check.torproject.org/api/ip" | grep -qm1 "\"IsTor\"[[:space:]]*:[[:space:]]*true"'

# tor user/group come from the apk "tor" package; drop root only when
# we don't need to chown the HS/data dir at startup as root first —
# entrypoint.sh still runs as root to fix permissions, then execs tor
# via su-exec-style drop if desired. Left as root here since
# entrypoint.sh performs chown; switch to USER tor if you remove that step.
