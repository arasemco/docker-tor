---
name: docker-tor
description: Project knowledge for the arasemco/docker-tor repo and the ghcr.io/arasemco/tor image (Tor + optional Privoxy on Alpine, supervised by s6-overlay). Use it for any question about or change to this image or repo, such as how to run it, which TORRC_*/PRIVOXY_*/PUID env var does what, SOCKS/ControlPort/onion service/bridge/exit-node setup, the iptables leak firewall, the browser sidecar example, docker-compose examples, building with buildx bake, bumping versions, CI, or security hardening. Read it BEFORE opening source files, because it answers most questions without code discovery and says which file to open when you do need to.
---

# docker-tor

A single image that runs **Tor** and, optionally, **Privoxy** in one container. Both are configured only through env vars and supervised by **s6-overlay**. There is one build target, `tor`, published as `ghcr.io/arasemco/tor:latest` and `:<TOR_VERSION>`.

Full env var tables are in `references/env-vars.md`. Read that file when a question involves a specific variable.

## How a container starts

`ENTRYPOINT ["/init"]` makes s6-overlay PID 1. It runs these steps in order, and each finishes before the next begins:

1. `Tor/cont-init.d/05-ids`: if `PUID`/`PGID` are set, it remaps the `tor` user/group in `/etc/passwd`/`/etc/group`. Startup aborts if a value is not a positive integer or belongs to another account. Only the tor container's own `/etc/passwd` is checked.
2. `Tor/cont-init.d/10-firewall`: when `TORRC_ENABLE_FIREWALL=true`, it applies a default-deny iptables and ip6tables ruleset (IPv6 is skipped if unavailable). It must run after 05-ids, because `--uid-owner tor` resolves to a number when the rule is inserted.
3. `/etc/services.d/{tor,privoxy}/run` (source `Tor/services/*/run`) start in parallel and are restarted independently. If tor crashes, privoxy keeps running and simply gets connection errors until tor is back.
   - **tor/run** writes `/etc/tor/torrc` from the env vars, then runs `exec su-exec tor tor -f /etc/tor/torrc`.
   - **privoxy/run** sleeps forever when `PRIVOXY_ENABLE=false`, so s6 does not restart-loop it. Otherwise it writes `/etc/privoxy/config` and runs `exec su-exec privoxy privoxy --no-daemon`. Alpine ships the stock privoxy files as `*.new`; the script copies them to their real names if missing.

Both run scripts start as root and drop privileges only at the final `exec`. Everything before that runs as root on every restart, which is why the ownership rules below matter.

## Defaults worth knowing

- **Everything is off by default.** SOCKS, ControlPort, onion service, Privoxy and the firewall all start disabled. With no env vars, Tor runs with `SocksPort 0`.
- **SOCKS** binds `0.0.0.0:${TORRC_SOCKS_PORT}` (default 9050). The default `SocksPolicy accept private:*,reject *` allows only RFC1918, loopback and link-local clients. Caveat: behind Docker's userland proxy (rootless Docker, Docker Desktop, IPv6 clients reaching an IPv4 container) every client appears to come from the bridge gateway, which is private, so the policy allows it. Publish as `127.0.0.1:9050:9050` on those setups. Set `TORRC_SOCKS_POLICY=""` to emit no policy, which accepts everyone.
- **ControlPort** is loopback-only, with `CookieAuthentication 1`; the cookie is written in the data directory (`/var/lib/tor/control_auth_cookie`). Binding a non-loopback address requires a password file at `TORRC_CONTROL_PASSWORD_FILE` (default `/run/secrets/tor_control_password`), or startup aborts. The plaintext password is hashed with `tor --hash-password` and never written to torrc. With `TORRC_CONTROL_COOKIE_AUTH=false` and no password, the port has no authentication and a warning is logged.
- **Onion service** lives in `/var/lib/tor/hidden_service`, and its address is in the `hostname` file there. `TORRC_HS_PORTS="80:10.2.0.2:80,443:10.2.0.2:443"` takes priority over `TORRC_HS_PORT`/`TORRC_HS_TARGET`. Targets must be IP:port, not hostnames, so give the backend a fixed IP. To keep a known address, mount an `hs_ed25519_secret_key` at `/run/secrets/tor_hs_ed25519_secret_key`; it is copied in as the tor user. Tor derives the public key and hostname itself.
- **Bridges**: set `TORRC_ENABLE_BRIDGES=true` and put bridge lines in `TORRC_BRIDGE_LINES`, separated by real newlines or a literal `\n`. The `Bridge ` prefix is added for you. The transport is obfs4 via `/usr/bin/lyrebird`.
- **Node selection**: `TORRC_EXIT_NODES` / `ENTRY_NODES` / `EXCLUDE_NODES` / `EXCLUDE_EXIT_NODES` are written verbatim, e.g. `{us},{de}`. `StrictNodes` defaults to 0.
- **Privoxy** listens on `127.0.0.1:8118` and forwards via `forward-socks5t` to `127.0.0.1:9050`, so DNS is resolved through Tor. Filters are on and logging is off. Set `PRIVOXY_TRUSTED_CIDRS` whenever the listen address is not loopback.
- **Healthcheck** runs every 300s. It checks `IsTor:true` from check.torproject.org through the SOCKS port (when SOCKS is on), that the onion `hostname` file exists (when the onion service is on), and Privoxy's `http://p.p/` page (when Privoxy is on). nyx is installed in the image.

## Firewall (`TORRC_ENABLE_FIREWALL=true`, needs `NET_ADMIN`, plus `NET_RAW` in the compose example)

The firewall is meant for a sidecar using `network_mode: "service:<tor>"`, typically a browser: the sidecar can reach the network only through Tor.

- **OUTPUT**: the policy is DROP. Allowed are loopback, ESTABLISHED/RELATED, and new connections from the tor UID. The privoxy UID is allowed only when `PRIVOXY_TOR_SOCKS_HOST` is not loopback.
- **INPUT**: the policy is DROP, so a published port gets no new connections. `TORRC_FIREWALL_ALLOW_INBOUND_PORTS="9050,3000,3001"` opens specific TCP ports.
- **UID trap**: matching is by numeric UID across the shared namespace. Never set `PUID` to a UID the sidecar uses; linuxserver images use 1000. That process would bypass the firewall.

## Ownership and security model

- `/var/lib/tor` is `tor:tor`, mode 700; it is re-chowned recursively on every start. The onion service directory is 700 and its key 600, and both are created as the tor user.
- `/etc/tor` is `root:tor` 750 and `torrc` is `root:tor` 640. `/etc/privoxy` and its config are `root:privoxy` in the same way, and only `/var/log/privoxy` is writable by privoxy. The configs are built in a temp file, the old file is removed, and the new one is renamed into place. This stops a compromised daemon from planting a symlink that the root-run script would write through. Keep this pattern in any new code that writes configs as root.
- The compose examples share the `x-tor-hardening` anchor: `cap_drop: ALL`, `cap_add` CHOWN, DAC_OVERRIDE, FOWNER, KILL, SETGID, SETUID, and `no-new-privileges`. YAML merge replaces lists rather than appending, so `tor-locked-down` restates the full list plus NET_ADMIN and NET_RAW.
- The Firefox example's noVNC UI (3010/3011 on the host) is published on `127.0.0.1` only, because it has no login unless `CUSTOM_USER`/`PASSWORD` are set.

## docker-compose.yml examples

The file is a set of examples; run one service at a time, e.g. `docker compose up tor`.

| Service | Host port | What it shows |
|---|---|---|
| `tor` | 9050 | plain SOCKS5 |
| `tor-privoxy` | (commented) | SOCKS and Privoxy together |
| `tor-socks-policy` | 9055 | explicit `TORRC_SOCKS_POLICY` |
| `tor-locked-down` + `client` | 9080, 127.0.0.1:3010/3011 | firewall plus a hardened Firefox sidecar: PAC file, policies.json, prefs given via `configs:` |
| `tor-exit-select` | 9060 | ExitNodes / StrictNodes |
| `tor-bridges` | 9070 | obfs4 bridges (placeholder line) |
| `tor-hs` | none | multi-port onion service with a secret key; named volumes `tor_etc` and `tor_var` |

The browser hardening rationale is in README "Browser hardening": WebRTC off, no proxy bypass, telemetry and captive-portal checks off, DNS prefetch off, geolocation off.

## Build, versions, CI

- Build with `bash bake.sh` (sets GIT_SHA/GIT_REF), adding `--push` or `--print` as needed. Do not use `docker build` or `compose build` for releases.
- **`docker-bake.hcl` is the source of truth for versions.** The `ARG` defaults in the Dockerfile can be stale, because bake overrides them. Pinned there: the Alpine base (name, tag, digest), `TOR/NYX/LYREBIRD/PRIVOXY_VERSION` (exact apk versions such as `0.4.9.14-r0`), and `S6_OVERLAY_VERSION` with `S6_SHA256_NOARCH/X86_64/AARCH64`. When bumping s6, update all four from the release's `.sha256` files, in both bake and the Dockerfile ARG defaults.
- The only platform is `linux/amd64`. The Dockerfile maps only amd64 and arm64 to s6 architectures.
- Build cache lives at `${REGISTRY}/tor:buildcache` and is written only when `CACHE_WRITE=true`.
- CI is `.github/workflows/docker-build-push.yml`, with three jobs:
  - `lint`: shellcheck `-S warning`, hadolint with the ignore list in `.hadolint.yaml`, and `compose config`.
  - `test`: bake `--load`, then `.github/scripts/smoke-test.sh`, then a Trivy scan that reports without failing.
  - `build-and-push`: needs both. It pushes only on non-PR events, to ghcr, or to a Gitea registry derived from `github.server_url`.

## Working in a Claude cloud sandbox

- The Alpine mirrors and the ghcr blob storage are usually blocked, so the real image can't be built or pulled there. Docker Hub works, but rate-limits.
- To test a run script without the image, start `debian:bookworm-slim` (it has bash and setpriv). Create the users, add a `su-exec` shim (`exec setpriv --reuid="$u" --regid="$u" --init-groups "$@"`) and stub `tor`/`privoxy` binaries, mount the script read-only, and run it with `bash`. Use `--cap-drop ALL` plus the compose capability set to mirror production.
- For `ps`/`stat` behaving like Alpine, copy `/bin/busybox` and `/lib/ld-musl-x86_64.so.1` from the cached Alpine base image.
- Lint locally with `pip install shellcheck-py hadolint-bin` in a venv.

## Where to look when this file isn't enough

| Need | File |
|---|---|
| exact torrc generation | `Tor/services/tor/run` (the header comment documents each var) |
| privoxy config generation | `Tor/services/privoxy/run` |
| firewall rules | `Tor/cont-init.d/10-firewall` |
| PUID/PGID remap | `Tor/cont-init.d/05-ids` |
| image layout, ENV defaults, healthcheck | `Tor/Dockerfile` |
| versions, labels, cache | `docker-bake.hcl` |
| example setups, Firefox policies/PAC | `docker-compose.yml` (`configs:` at the bottom) |
| user-facing docs | `README.md` |

When you change behavior in any of those files, update this skill and `references/env-vars.md` in the same commit so later sessions don't rely on stale facts.
