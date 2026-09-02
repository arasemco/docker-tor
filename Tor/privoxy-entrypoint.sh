#!/bin/bash
# =============================================================================
# privoxy-entrypoint.sh — writes /etc/privoxy/config from env vars, then
# execs privoxy.
#
# This is the entrypoint for the separate "tor-privoxy" build target (see
# ../docker-bake.hcl and the "privoxy" stage in Dockerfile) — NOT the same
# image/process as the plain "tor" target. It runs Privoxy configured to
# forward everything through a Tor SOCKS5 proxy, giving HTTP/HTTPS-only
# clients (anything that can't speak SOCKS directly) a plain HTTP proxy
# interface into Tor.
#
# It does not run Tor itself — point PRIVOXY_TOR_SOCKS_HOST/PORT at a
# separate "tor" container's SOCKS port (see the "tor-privoxy" example
# service in docker-compose.yml, which wires this to the plain "tor"
# service over a Compose network).
#
# All variables here use a PRIVOXY_ prefix, mirroring the TORRC_ prefix
# convention used by entrypoint.sh, so it's clear at a glance which
# config file/process a given env var feeds.
#
# -----------------------------------------------------------------------
# Variables
# -----------------------------------------------------------------------
# PRIVOXY_LISTEN_ADDRESS   default: 0.0.0.0        -> listen-address host
# PRIVOXY_LISTEN_PORT      default: 8118           -> listen-address port
# PRIVOXY_TOR_SOCKS_HOST   default: tor             -> host of the upstream
#                           Tor SOCKS5 proxy (typically another container
#                           on the same Compose network/service name).
# PRIVOXY_TOR_SOCKS_PORT   default: 9050            -> port of the
#                           upstream Tor SOCKS5 proxy.
# PRIVOXY_FORWARD_DNS      default: true            -> when true, uses
#                           socks5t (Tor resolves DNS remotely, avoiding
#                           local DNS leaks); when false, uses socks5
#                           (DNS resolved locally by Privoxy/the host —
#                           NOT recommended, leaks hostnames outside Tor).
# PRIVOXY_ENABLE_FILTERS   default: true            -> toggles Privoxy's
#                           default content-filtering (ads/trackers/
#                           banners) via the `filterfile default.filter`
#                           + per-request `+filter{...}` action groups
#                           shipped with the apk package. When false,
#                           traffic is forwarded with no filtering, pure
#                           relay-only behavior.
# PRIVOXY_ENABLE_LOGGING   default: false           -> when true, enables
#                           Privoxy's own request logging (`debug 1` +
#                           logfile). Off by default since verbose
#                           request logs are themselves a privacy leak on
#                           an anonymizing proxy.
# PRIVOXY_TRUSTED_CIDRS    default: (unset)         -> comma-separated
#                           CIDRs allowed to connect, written as
#                           `permit-access` lines, e.g.
#                           "10.0.0.0/8,192.168.0.0/16". When unset,
#                           Privoxy's default (accept from wherever
#                           listen-address binds) applies — restrict this
#                           in any multi-tenant/shared-network deployment.
# =============================================================================
set -euo pipefail

CONFIG=/etc/privoxy/config

: "${PRIVOXY_LISTEN_ADDRESS:=0.0.0.0}"
: "${PRIVOXY_LISTEN_PORT:=8118}"
: "${PRIVOXY_TOR_SOCKS_HOST:=tor}"
: "${PRIVOXY_TOR_SOCKS_PORT:=9050}"
: "${PRIVOXY_FORWARD_DNS:=true}"
: "${PRIVOXY_ENABLE_FILTERS:=true}"
: "${PRIVOXY_ENABLE_LOGGING:=false}"
: "${PRIVOXY_TRUSTED_CIDRS:=}"

write_config() {
    : > "${CONFIG}"

    echo "listen-address ${PRIVOXY_LISTEN_ADDRESS}:${PRIVOXY_LISTEN_PORT}" >> "${CONFIG}"

    # socks5t = Privoxy sends the hostname to Tor and lets Tor resolve it
    # (no local/host DNS leak). Plain socks5 resolves locally first, which
    # defeats a chunk of the point of routing through Tor — only offered
    # as an explicit opt-out, not a default.
    if [ "${PRIVOXY_FORWARD_DNS}" = "true" ]; then
        echo "forward-socks5t / ${PRIVOXY_TOR_SOCKS_HOST}:${PRIVOXY_TOR_SOCKS_PORT} ." >> "${CONFIG}"
    else
        echo "forward-socks5 / ${PRIVOXY_TOR_SOCKS_HOST}:${PRIVOXY_TOR_SOCKS_PORT} ." >> "${CONFIG}"
    fi

    echo "confdir /etc/privoxy" >> "${CONFIG}"
    echo "templdir /etc/privoxy/templates" >> "${CONFIG}"
    echo "cgi-error-detail 1" >> "${CONFIG}"

    if [ "${PRIVOXY_ENABLE_LOGGING}" = "true" ]; then
        echo "logdir /var/log/privoxy" >> "${CONFIG}"
        echo "logfile privoxy.log" >> "${CONFIG}"
        echo "debug 1" >> "${CONFIG}"
    fi

    if [ "${PRIVOXY_ENABLE_FILTERS}" = "true" ]; then
        echo "actionsfile default.action" >> "${CONFIG}"
        echo "filterfile default.filter" >> "${CONFIG}"
    fi

    if [ -n "${PRIVOXY_TRUSTED_CIDRS}" ]; then
        IFS=',' read -ra _cidrs <<< "${PRIVOXY_TRUSTED_CIDRS}"
        for cidr in "${_cidrs[@]}"; do
            echo "permit-access ${cidr}" >> "${CONFIG}"
        done
    fi
}

mkdir -p /etc/privoxy /var/log/privoxy
chown -R privoxy:privoxy /etc/privoxy /var/log/privoxy 2>/dev/null || true

write_config

case "${1:-privoxy}" in
    privoxy)
        exec su-exec privoxy privoxy --no-daemon "${CONFIG}"
        ;;
    *)
        exec "$@"
        ;;
esac
