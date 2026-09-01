#!/bin/bash
# =============================================================================
# entrypoint.sh — writes /etc/tor/torrc from env vars, then execs tor.
#
# NOTE: this file was not supplied in the original project and is authored
# here to match the behavior described in the Dockerfile's comments
# (ENABLE_SOCKS/ENABLE_CONTROL/ENABLE_HS toggles, SOCKS_PORT/CONTROL_PORT/
# HS_PORTS/HS_TARGET). Review before relying on it in production — in
# particular the control-port auth story (currently none).
#
# Multi-port hidden services: HS_PORTS is a comma-separated list of
# "<virtport>:<target>" pairs (target is host:port, same shape Tor itself
# expects), e.g. HS_PORTS=80:10.2.0.2:80,443:10.2.0.2:443 — one
# HiddenServicePort line is written per entry, all under the same
# HiddenServiceDir/key, matching how torrc actually expresses multiple
# ports on one onion address. HS_PORT/HS_TARGET (singular) still work as a
# one-port shorthand for back-compat; if HS_PORTS is set it takes over
# and HS_PORT/HS_TARGET are ignored.
#
# Secret-seeded key: if a hs_ed25519_secret_key is mounted (e.g. via
# Docker/Compose `secrets:`) at HS_SECRET_KEY_FILE, it's copied into
# HiddenServiceDir with the ownership/permissions Tor requires (secrets
# mount read-only and root-owned, which Tor refuses to start with as-is).
# This only seeds the secret key — Tor derives/recreates the matching
# public key and hostname on first start if they're not already present
# in the persisted volume.
# =============================================================================
set -euo pipefail

TORRC=/etc/tor/torrc
DATA_DIR=/var/lib/tor
HS_DIR="${DATA_DIR}/hidden_service"

: "${ENABLE_SOCKS:=false}"
: "${ENABLE_CONTROL:=false}"
: "${ENABLE_HS:=false}"
: "${SOCKS_PORT:=9050}"
: "${CONTROL_PORT:=9051}"
: "${HS_PORT:=80}"
: "${HS_TARGET:=127.0.0.1:80}"
: "${HS_PORTS:=}"
: "${HS_SECRET_KEY_FILE:=/run/secrets/tor_hs_ed25519_secret_key}"

seed_hs_key() {
    if [ -f "${HS_SECRET_KEY_FILE}" ]; then
        install -o tor -g tor -m 600 "${HS_SECRET_KEY_FILE}" "${HS_DIR}/hs_ed25519_secret_key"
    fi
}

write_torrc() {
    : > "${TORRC}"
    echo "DataDirectory ${DATA_DIR}" >> "${TORRC}"
    echo "Log notice stdout" >> "${TORRC}"
    echo "RunAsDaemon 0" >> "${TORRC}"

    if [ "${ENABLE_SOCKS}" = "true" ]; then
        echo "SocksPort 0.0.0.0:${SOCKS_PORT}" >> "${TORRC}"
    else
        echo "SocksPort 0" >> "${TORRC}"
    fi

    if [ "${ENABLE_CONTROL}" = "true" ]; then
        echo "ControlPort 0.0.0.0:${CONTROL_PORT}" >> "${TORRC}"
        # No control-port auth configured by default. Set
        # HashedControlPassword (via `tor --hash-password`) or
        # CookieAuthentication before exposing this beyond localhost.
        echo "CookieAuthentication 1" >> "${TORRC}"
    fi

    if [ "${ENABLE_HS}" = "true" ]; then
        mkdir -p "${HS_DIR}"
        chmod 700 "${HS_DIR}"
        chown -R tor:tor "${HS_DIR}"
        seed_hs_key
        echo "HiddenServiceDir ${HS_DIR}" >> "${TORRC}"

        if [ -n "${HS_PORTS}" ]; then
            # "80:10.2.0.2:80,443:10.2.0.2:443" -> one HiddenServicePort
            # line per comma-separated entry, split on the first ":" only
            # (the target itself contains a ":" between host and port).
            IFS=',' read -ra _hs_entries <<< "${HS_PORTS}"
            for entry in "${_hs_entries[@]}"; do
                virtport="${entry%%:*}"
                target="${entry#*:}"
                echo "HiddenServicePort ${virtport} ${target}" >> "${TORRC}"
            done
        else
            echo "HiddenServicePort ${HS_PORT} ${HS_TARGET}" >> "${TORRC}"
        fi
    fi
}

mkdir -p "${DATA_DIR}"
chown -R tor:tor "${DATA_DIR}"
chmod 700 "${DATA_DIR}"

mkdir -p "$(dirname "${TORRC}")"
chown tor:tor "$(dirname "${TORRC}")"

write_torrc
chown tor:tor "${TORRC}"

case "${1:-tor}" in
    tor)
        exec su-exec tor tor -f "${TORRC}"
        ;;
    nyx)
        exec su-exec tor nyx
        ;;
    *)
        exec "$@"
        ;;
esac
