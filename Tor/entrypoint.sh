#!/bin/bash
# =============================================================================
# entrypoint.sh — writes /etc/tor/torrc from env vars, then execs tor.
#
# NOTE: this file was not supplied in the original project and is authored
# here to match the behavior described in the Dockerfile's comments. Review
# before relying on it in production — in particular the control-port auth
# story (currently cookie-only, no password).
#
# All runtime-config env vars use a TORRC_ prefix (e.g. TORRC_ENABLE_SOCKS,
# TORRC_HS_PORTS) to namespace them clearly as "things that end up in
# torrc", distinct from anything else the container/orchestrator might set.
# This is a breaking rename from the previous unprefixed vars
# (ENABLE_SOCKS -> TORRC_ENABLE_SOCKS, etc.) — no back-compat shim is
# provided, update your env/compose files accordingly.
#
# -----------------------------------------------------------------------
# SOCKS / Control / Hidden Service (existing, renamed)
# -----------------------------------------------------------------------
# TORRC_ENABLE_SOCKS         default: false
# TORRC_SOCKS_PORT           default: 9050
# TORRC_ENABLE_CONTROL       default: false
# TORRC_CONTROL_PORT         default: 9051
# TORRC_ENABLE_HS            default: false
# TORRC_HS_PORT/TORRC_HS_TARGET   single-port shorthand, default 80 / 127.0.0.1:80
# TORRC_HS_PORTS             comma-separated "<virtport>:<target>" pairs,
#                             e.g. "80:10.2.0.2:80,443:10.2.0.2:443" — takes
#                             priority over TORRC_HS_PORT/TORRC_HS_TARGET.
# TORRC_HS_SECRET_KEY_FILE   default: /run/secrets/tor_hs_ed25519_secret_key
#
# -----------------------------------------------------------------------
# Exit / entry / excluded node selection (new)
# -----------------------------------------------------------------------
# TORRC_EXIT_NODES           e.g. "{us},{de}" -> ExitNodes {us},{de}
# TORRC_ENTRY_NODES          e.g. "{fr}"      -> EntryNodes {fr}
# TORRC_EXCLUDE_NODES        e.g. "{ru},{cn}" -> ExcludeNodes {ru},{cn}
# TORRC_EXCLUDE_EXIT_NODES   e.g. "{ru}"      -> ExcludeExitNodes {ru}
# TORRC_STRICT_NODES         default: false   -> StrictNodes 0/1. Only
#                             meaningful alongside the *_NODES vars above:
#                             when true, Tor refuses to build a circuit at
#                             all rather than fall back outside the list.
#
# -----------------------------------------------------------------------
# Bridges / pluggable transports (new — activates the lyrebird package
# that was already installed but unused)
# -----------------------------------------------------------------------
# TORRC_ENABLE_BRIDGES       default: false   -> UseBridges 1
# TORRC_BRIDGE_LINES         newline- or literal-"\n"-separated bridge
#                             lines, each written verbatim as a torrc
#                             "Bridge ..." line, e.g.:
#                               obfs4 192.0.2.1:443 FINGERPRINT cert=... iat-mode=0
#                             Accepts real newlines (multi-line env var) or
#                             the two-character sequence \n as a separator,
#                             so it also works from single-line env sources
#                             (e.g. some Compose/K8s secret injection paths).
# TORRC_BRIDGE_TRANSPORT     default: obfs4  -> which ClientTransportPlugin
#                             line to emit. Set to "" to skip emitting a
#                             ClientTransportPlugin line entirely (e.g. if
#                             your bridge lines are all vanilla, unlisted
#                             bridges that need no pluggable transport).
# TORRC_LYREBIRD_PATH        default: /usr/bin/lyrebird — path to the
#                             pluggable-transport binary.
#
# =============================================================================
set -euo pipefail

TORRC=/etc/tor/torrc
DATA_DIR=/var/lib/tor
HS_DIR="${DATA_DIR}/hidden_service"

: "${TORRC_ENABLE_SOCKS:=false}"
: "${TORRC_ENABLE_CONTROL:=false}"
: "${TORRC_ENABLE_HS:=false}"
: "${TORRC_SOCKS_PORT:=9050}"
: "${TORRC_CONTROL_PORT:=9051}"
: "${TORRC_HS_PORT:=80}"
: "${TORRC_HS_TARGET:=127.0.0.1:80}"
: "${TORRC_HS_PORTS:=}"
: "${TORRC_HS_SECRET_KEY_FILE:=/run/secrets/tor_hs_ed25519_secret_key}"

: "${TORRC_EXIT_NODES:=}"
: "${TORRC_ENTRY_NODES:=}"
: "${TORRC_EXCLUDE_NODES:=}"
: "${TORRC_EXCLUDE_EXIT_NODES:=}"
: "${TORRC_STRICT_NODES:=false}"

: "${TORRC_ENABLE_BRIDGES:=false}"
: "${TORRC_BRIDGE_LINES:=}"
: "${TORRC_BRIDGE_TRANSPORT:=obfs4}"
: "${TORRC_LYREBIRD_PATH:=/usr/bin/lyrebird}"

seed_hs_key() {
    if [ -f "${TORRC_HS_SECRET_KEY_FILE}" ]; then
        install -o tor -g tor -m 600 "${TORRC_HS_SECRET_KEY_FILE}" "${HS_DIR}/hs_ed25519_secret_key"
    fi
}

write_node_selection() {
    # Node-selection lines are independent of each other; only emit a
    # line for the ones actually set, so an unset var doesn't clobber
    # Tor's own defaults with an empty directive.
    if [ -n "${TORRC_EXIT_NODES}" ]; then
        echo "ExitNodes ${TORRC_EXIT_NODES}" >> "${TORRC}"
    fi
    if [ -n "${TORRC_ENTRY_NODES}" ]; then
        echo "EntryNodes ${TORRC_ENTRY_NODES}" >> "${TORRC}"
    fi
    if [ -n "${TORRC_EXCLUDE_NODES}" ]; then
        echo "ExcludeNodes ${TORRC_EXCLUDE_NODES}" >> "${TORRC}"
    fi
    if [ -n "${TORRC_EXCLUDE_EXIT_NODES}" ]; then
        echo "ExcludeExitNodes ${TORRC_EXCLUDE_EXIT_NODES}" >> "${TORRC}"
    fi

    # StrictNodes only makes sense once at least one of the above is set;
    # emitting "StrictNodes 1" with no *Nodes list would just be a no-op,
    # but we still respect an explicit true/false either way rather than
    # silently overriding the user's choice.
    if [ "${TORRC_STRICT_NODES}" = "true" ]; then
        echo "StrictNodes 1" >> "${TORRC}"
    else
        echo "StrictNodes 0" >> "${TORRC}"
    fi
}

write_bridges() {
    [ "${TORRC_ENABLE_BRIDGES}" = "true" ] || return 0

    echo "UseBridges 1" >> "${TORRC}"

    if [ -n "${TORRC_BRIDGE_TRANSPORT}" ]; then
        echo "ClientTransportPlugin ${TORRC_BRIDGE_TRANSPORT} exec ${TORRC_LYREBIRD_PATH}" >> "${TORRC}"
    fi

    if [ -n "${TORRC_BRIDGE_LINES}" ]; then
        # Normalize the literal two-character sequence \n to a real
        # newline first, so this accepts either an actual multi-line env
        # var (Compose/K8s "|"-style block) or a single-line value from
        # sources that can't carry real newlines (e.g. some secret
        # managers, `docker run -e`).
        normalized="${TORRC_BRIDGE_LINES//\\n/$'\n'}"
        while IFS= read -r line; do
            # Skip blank lines that fall out of the split/normalize step.
            [ -n "${line}" ] && echo "Bridge ${line}" >> "${TORRC}"
        done <<< "${normalized}"
    fi
}

write_torrc() {
    : > "${TORRC}"
    echo "DataDirectory ${DATA_DIR}" >> "${TORRC}"
    echo "Log notice stdout" >> "${TORRC}"
    echo "RunAsDaemon 0" >> "${TORRC}"

    if [ "${TORRC_ENABLE_SOCKS}" = "true" ]; then
        echo "SocksPort 0.0.0.0:${TORRC_SOCKS_PORT}" >> "${TORRC}"
    else
        echo "SocksPort 0" >> "${TORRC}"
    fi

    if [ "${TORRC_ENABLE_CONTROL}" = "true" ]; then
        echo "ControlPort 0.0.0.0:${TORRC_CONTROL_PORT}" >> "${TORRC}"
        # No control-port auth configured by default. Set
        # HashedControlPassword (via `tor --hash-password`) or
        # CookieAuthentication before exposing this beyond localhost.
        echo "CookieAuthentication 1" >> "${TORRC}"
    fi

    if [ "${TORRC_ENABLE_HS}" = "true" ]; then
        mkdir -p "${HS_DIR}"
        chmod 700 "${HS_DIR}"
        chown -R tor:tor "${HS_DIR}"
        seed_hs_key
        echo "HiddenServiceDir ${HS_DIR}" >> "${TORRC}"

        if [ -n "${TORRC_HS_PORTS}" ]; then
            # "80:10.2.0.2:80,443:10.2.0.2:443" -> one HiddenServicePort
            # line per comma-separated entry, split on the first ":" only
            # (the target itself contains a ":" between host and port).
            IFS=',' read -ra _hs_entries <<< "${TORRC_HS_PORTS}"
            for entry in "${_hs_entries[@]}"; do
                virtport="${entry%%:*}"
                target="${entry#*:}"
                echo "HiddenServicePort ${virtport} ${target}" >> "${TORRC}"
            done
        else
            echo "HiddenServicePort ${TORRC_HS_PORT} ${TORRC_HS_TARGET}" >> "${TORRC}"
        fi
    fi

    write_node_selection
    write_bridges
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
