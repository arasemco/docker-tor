#!/bin/bash
# Starts the built image with the same least-privilege settings as
# docker-compose.yml and checks that it comes up correctly.
#   .github/scripts/smoke-test.sh <image>
set -euo pipefail

IMAGE="${1:?usage: $0 <image>}"
CAPS=(--cap-drop ALL --cap-add CHOWN --cap-add DAC_OVERRIDE --cap-add FOWNER
      --cap-add KILL --cap-add SETGID --cap-add SETUID
      --security-opt no-new-privileges:true)
cid=""

fail() { echo "FAIL: $*" >&2; exit 1; }

cleanup() {
    if [ -n "${cid}" ]; then
        echo "--- container logs (${cid:0:12})"
        docker logs "${cid}" 2>&1 | tail -n 40
        docker rm -f "${cid}" >/dev/null
    fi
}
trap cleanup EXIT

# Waits until processes named $2 (and $3) run as their own users in $1.
wait_for_procs() {
    local c="$1"; shift
    for _ in $(seq 1 30); do
        if docker exec "${c}" ps -o user,comm | awk -v want="$*" '
            BEGIN { n = split(want, w, " ") }
            { for (i = 1; i <= n; i++) if ($1 == w[i] && $2 == w[i]) seen[w[i]] = 1 }
            END { for (i = 1; i <= n; i++) if (!(w[i] in seen)) exit 1 }'; then
            return 0
        fi
        sleep 1
    done
    return 1
}

echo "=== tor + privoxy, reduced capabilities"
cid="$(docker run -d "${CAPS[@]}" \
    -e TORRC_ENABLE_SOCKS=true -e PRIVOXY_ENABLE=true "${IMAGE}")"
wait_for_procs "${cid}" tor privoxy || fail "tor/privoxy did not start as their own users"

perms="$(docker exec "${cid}" stat -c '%n %U:%G %a' /etc/tor /etc/tor/torrc /etc/privoxy /etc/privoxy/config)"
echo "${perms}"
expected="/etc/tor root:tor 750
/etc/tor/torrc root:tor 640
/etc/privoxy root:privoxy 750
/etc/privoxy/config root:privoxy 640"
[ "${perms}" = "${expected}" ] || fail "unexpected config ownership/modes"

docker exec "${cid}" su-exec tor tor --verify-config -f /etc/tor/torrc >/dev/null \
    || fail "tor rejected the generated torrc"
docker exec "${cid}" su-exec tor touch /etc/tor/probe 2>/dev/null \
    && fail "tor user can write to /etc/tor"
cleanup; cid=""

echo "=== firewall enabled"
cid="$(docker run -d "${CAPS[@]}" --cap-add NET_ADMIN --cap-add NET_RAW \
    -e TORRC_ENABLE_SOCKS=true -e PRIVOXY_ENABLE=true -e TORRC_ENABLE_FIREWALL=true "${IMAGE}")"
wait_for_procs "${cid}" tor privoxy || fail "tor/privoxy did not start with the firewall on"

rules="$(docker exec "${cid}" iptables -S OUTPUT)"
echo "${rules}"
tor_uid="$(docker exec "${cid}" id -u tor)"
echo "${rules}" | grep -q -- "-P OUTPUT DROP" || fail "OUTPUT policy is not DROP"
echo "${rules}" | grep -q -- "--uid-owner ${tor_uid} " || fail "no egress rule for tor"
[ "$(echo "${rules}" | grep -c -- '--uid-owner')" = 1 ] \
    || fail "expected only tor's egress rule (privoxy forwards over loopback)"

echo "All smoke tests passed."
