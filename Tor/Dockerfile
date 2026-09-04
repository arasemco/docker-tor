# syntax=docker/dockerfile:1
# =============================================================================
# Tor proxy image — Tor (SOCKS5/ControlPort/Hidden Service/bridges/node
# selection) plus an optional Privoxy HTTP/HTTPS front-end, supervised by
# s6-overlay in a single container.
# =============================================================================
#
# This replaces the previous two-image design (separate "tor" and
# "tor-privoxy" bake targets). Both processes now run in the same
# container, each independently supervised by s6-overlay: if tor crashes,
# s6 restarts only tor; privoxy keeps running (and just fails to reach the
# SOCKS port until tor is back). Privoxy is toggled on/off at runtime via
# PRIVOXY_ENABLE — see services/privoxy/run — so the same image serves
# both "Tor only" and "Tor + Privoxy" deployments; nothing is a separate
# build target anymore.
#
# s6-overlay: https://github.com/just-containers/s6-overlay
# Installed as two tarballs (noarch scripts + arch-specific static
# binaries) per its own install instructions, extracted with tar -p to
# preserve permissions. ENTRYPOINT becomes /init (s6's own PID 1), and our
# two services live under /etc/services.d/{tor,privoxy}/run — the
# "legacy" s6-overlay service style, which is simpler than full s6-rc and
# sufficient here since neither service needs to wait on the other's
# startup (Privoxy just retries the upstream SOCKS connection per-request
# if Tor isn't ready yet).
#
# Base image ref is pinned by digest and passed in from docker-bake.hcl
# (via pinned_ref()) rather than hardcoded here — see that file's
# ALPINE_BASE variable for the actual name:tag@digest value.
ARG ALPINE_REF=docker.io/library/alpine:edge@sha256:020dfcbaaf4cc1078bf2d9c7ba31a8466e334061dcd2f248001d68f79e52c000

ARG TOR_VERSION=0.4.9.11-r0
ARG NYX_VERSION=2.1.0-r6
ARG LYREBIRD_VERSION=0.8.1-r6
ARG PRIVOXY_VERSION=4.0.0-r0

# s6-overlay release version and its checksums — pinned explicitly rather
# than tracking "latest", same rationale as every other pin in this
# Dockerfile. Bump by checking https://github.com/just-containers/s6-overlay/releases
# for a new version tag and updating S6_OVERLAY_VERSION below; the
# .sha256 files are fetched from the same release and verified at build
# time (see the RUN step), so a corrupted/tampered download fails the
# build rather than silently shipping.
ARG S6_OVERLAY_VERSION=3.2.3.0


# =============================================================================
# base — packages, s6-overlay install, and both service scripts. Single
# stage now (no more base/tor/tor-privoxy split) since there's only one
# final image.
# =============================================================================
FROM ${ALPINE_REF} AS base

ARG TOR_VERSION
ARG NYX_VERSION
ARG LYREBIRD_VERSION
ARG PRIVOXY_VERSION
ARG S6_OVERLAY_VERSION

# xz is required to extract s6-overlay's .tar.xz release tarballs (not
# present in Alpine's base image by default).
RUN apk add --no-cache \
        curl \
        bash \
        su-exec \
        xz \
        "tor=${TOR_VERSION}" \
        "nyx=${NYX_VERSION}" \
        "lyrebird=${LYREBIRD_VERSION}" \
        "privoxy=${PRIVOXY_VERSION}" \
    && rm -rf /var/cache/apk/*

# s6-overlay install: noarch (scripts, arch-independent) + x86_64 (static
# binaries) tarballs, each verified against its published sha256 before
# extraction. TARGETARCH is a Buildx-provided automatic build arg; s6's
# tarball naming (x86_64/aarch64/arm/armhf/...) differs from Docker's
# (amd64/arm64/arm-v7/arm-v6/...), so this maps between the two rather
# than assuming amd64.
#
# NOTE: only amd64 and arm64 are mapped below since docker-bake.hcl's
# PLATFORMS default is linux/amd64 only at present — extend this mapping
# if/when PLATFORMS is widened (see s6-overlay's own README table for the
# full TARGETARCH -> s6 arch mapping).
ARG TARGETARCH
RUN set -euo pipefail; \
    case "${TARGETARCH}" in \
        amd64) S6_ARCH=x86_64 ;; \
        arm64) S6_ARCH=aarch64 ;; \
        *) echo "unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    cd /tmp && \
    curl -fsSLO "https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-noarch.tar.xz" && \
    curl -fsSLO "https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-noarch.tar.xz.sha256" && \
    curl -fsSLO "https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-${S6_ARCH}.tar.xz" && \
    curl -fsSLO "https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-${S6_ARCH}.tar.xz.sha256" && \
    sha256sum -c ./*.sha256 && \
    tar -C / -Jxpf "s6-overlay-noarch.tar.xz" && \
    tar -C / -Jxpf "s6-overlay-${S6_ARCH}.tar.xz" && \
    rm -f /tmp/*.tar.xz /tmp/*.sha256

COPY --chmod=755 services /etc/services.d

ENTRYPOINT ["/init"]

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

ARG PRIVOXY_ENABLE=false
ARG PRIVOXY_LISTEN_ADDRESS=0.0.0.0
ARG PRIVOXY_LISTEN_PORT=8118
ARG PRIVOXY_TOR_SOCKS_HOST=127.0.0.1
ARG PRIVOXY_TOR_SOCKS_PORT=9050
ARG PRIVOXY_FORWARD_DNS=true
ARG PRIVOXY_ENABLE_FILTERS=true
ARG PRIVOXY_ENABLE_LOGGING=false
ARG PRIVOXY_TRUSTED_CIDRS=""

ENV TOR_VERSION=${TOR_VERSION} \
    PRIVOXY_VERSION=${PRIVOXY_VERSION} \
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
    TORRC_LYREBIRD_PATH=${TORRC_LYREBIRD_PATH} \
    PRIVOXY_ENABLE=${PRIVOXY_ENABLE} \
    PRIVOXY_LISTEN_ADDRESS=${PRIVOXY_LISTEN_ADDRESS} \
    PRIVOXY_LISTEN_PORT=${PRIVOXY_LISTEN_PORT} \
    PRIVOXY_TOR_SOCKS_HOST=${PRIVOXY_TOR_SOCKS_HOST} \
    PRIVOXY_TOR_SOCKS_PORT=${PRIVOXY_TOR_SOCKS_PORT} \
    PRIVOXY_FORWARD_DNS=${PRIVOXY_FORWARD_DNS} \
    PRIVOXY_ENABLE_FILTERS=${PRIVOXY_ENABLE_FILTERS} \
    PRIVOXY_ENABLE_LOGGING=${PRIVOXY_ENABLE_LOGGING} \
    PRIVOXY_TRUSTED_CIDRS=${PRIVOXY_TRUSTED_CIDRS}

EXPOSE ${TORRC_SOCKS_PORT} ${TORRC_CONTROL_PORT} ${PRIVOXY_LISTEN_PORT}

# Checks tor's SOCKS port when enabled, and Privoxy's liveness page when
# PRIVOXY_ENABLE=true — both conditional on their respective toggles, so
# this HEALTHCHECK is meaningful regardless of which combination of
# services this particular container is actually running.
HEALTHCHECK --interval=300s --timeout=15s --start-period=60s --start-interval=10s \
    CMD sh -c ' \
        ok=0; \
        if [ "$TORRC_ENABLE_SOCKS" = "true" ]; then \
            curl -s -x socks5h://127.0.0.1:${TORRC_SOCKS_PORT} "https://check.torproject.org/api/ip" | grep -qm1 "\"IsTor\"[[:space:]]*:[[:space:]]*true" || ok=1; \
        fi; \
        if [ "$PRIVOXY_ENABLE" = "true" ]; then \
            curl -s -o /dev/null -x "http://127.0.0.1:${PRIVOXY_LISTEN_PORT}" "http://p.p/" || ok=1; \
        fi; \
        exit $ok \
    '

# tor/privoxy users/groups come from their respective apk packages; each
# service's run script performs its own chown/permission-fixing as root,
# then drops to its daemon's own user via su-exec before exec'ing —
# staying root at the container level since both services need that step.
