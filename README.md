# tor

[![Build and push Docker images](https://github.com/arasemco/docker-tor/actions/workflows/docker-build-push.yml/badge.svg)](https://github.com/arasemco/docker-tor/actions/workflows/docker-build-push.yml)
[![GHCR: tor](https://img.shields.io/badge/ghcr.io-tor-blue?logo=docker)](https://github.com/arasemco/docker-tor/pkgs/container/tor)
[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](./LICENSE)
[![Alpine base](https://img.shields.io/badge/base-alpine%203.24-0D597F?logo=alpinelinux)](https://alpinelinux.org)
[![s6-overlay](https://img.shields.io/badge/supervisor-s6--overlay-orange)](https://github.com/just-containers/s6-overlay)

A minimal Tor proxy container: SOCKS5, ControlPort, Hidden Service,
exit/entry node selection, and bridges — all toggled at runtime via
environment variables. An optional Privoxy HTTP/HTTPS front-end runs
alongside Tor in the same container, toggled with `PRIVOXY_ENABLE`, for
clients that can't speak SOCKS directly.

Both processes are supervised independently by
[s6-overlay](https://github.com/just-containers/s6-overlay): if Tor
crashes, only Tor restarts — Privoxy (if enabled) keeps running and
simply fails to reach the SOCKS port until Tor is back up.

Built from Alpine, base image pinned by digest (see
[`docker-bake.hcl`](./docker-bake.hcl)).

## Images

| Tag | Contents |
|---|---|
| `ghcr.io/arasemco/tor:latest` | Latest build off `main` |
| `ghcr.io/arasemco/tor:<TOR_VERSION>` | Pinned to a specific Tor package version, e.g. `0.4.9.11-r0` |

One image, built from [`Tor/Dockerfile`](./Tor/Dockerfile). Tor always
runs; Privoxy is present in every build but only actually starts when
`PRIVOXY_ENABLE=true` — see [Privoxy](#privoxy-http-front-end) below.

## Quick start

```bash
docker compose up tor
```

Starts a plain SOCKS5 proxy on `localhost:9050`. See [`docker-compose.yml`](./docker-compose.yml)
for the full set of example services, including exit-node selection
(`tor-exit-select`), bridges (`tor-bridges`), Tor + Privoxy together
(`tor-privoxy`), and a hidden-service example (`tor-hs`).

## Runtime configuration

Nothing is baked into the image at build time except package versions —
what actually runs (SOCKS only, hidden service only, node selection,
bridges, Privoxy, or any combination) is decided by environment variables
read by each s6-supervised service's `run` script on container start:
[`Tor/services/tor/run`](./Tor/services/tor/run) writes `/etc/tor/torrc`;
[`Tor/services/privoxy/run`](./Tor/services/privoxy/run) writes
`/etc/privoxy/config`.

> **Breaking change:** every runtime-config variable uses a `TORRC_`
> prefix for Tor (e.g. `TORRC_ENABLE_SOCKS`) or `PRIVOXY_` for Privoxy.
> There is no back-compat shim for old unprefixed names — update your
> env/Compose files.

### SOCKS / ControlPort / Hidden Service

| Variable | Default | Description |
|---|---|---|
| `TORRC_ENABLE_SOCKS` | `false` | Enable the SOCKS5 proxy |
| `TORRC_SOCKS_PORT` | `9050` | SOCKS5 listen port |
| `TORRC_ENABLE_CONTROL` | `false` | Enable the Tor ControlPort (cookie auth only — see [Security notes](#security-notes)) |
| `TORRC_CONTROL_PORT` | `9051` | ControlPort listen port |
| `TORRC_ENABLE_HS` | `false` | Enable the Hidden Service |
| `TORRC_HS_PORT` / `TORRC_HS_TARGET` | `80` / `127.0.0.1:80` | Single-port hidden service shorthand |
| `TORRC_HS_PORTS` | *(unset)* | Comma-separated `<virtport>:<target>` pairs for a multi-port hidden service, e.g. `80:10.2.0.2:80,443:10.2.0.2:443`. Takes priority over `TORRC_HS_PORT`/`TORRC_HS_TARGET` when set. |
| `TORRC_HS_SECRET_KEY_FILE` | `/run/secrets/tor_hs_ed25519_secret_key` | Path to an existing `hs_ed25519_secret_key` to seed into the hidden service directory, so the container reuses a known onion address instead of generating a new one on first start |

### Exit / entry / excluded node selection

| Variable | Default | Description |
|---|---|---|
| `TORRC_EXIT_NODES` | *(unset)* | Restrict exit nodes, e.g. `{us},{de}` → `ExitNodes {us},{de}` |
| `TORRC_ENTRY_NODES` | *(unset)* | Restrict entry/guard nodes, e.g. `{fr}` → `EntryNodes {fr}` |
| `TORRC_EXCLUDE_NODES` | *(unset)* | Exclude nodes at any hop, e.g. `{ru},{cn}` → `ExcludeNodes {ru},{cn}` |
| `TORRC_EXCLUDE_EXIT_NODES` | *(unset)* | Exclude specific exit nodes, e.g. `{ru}` → `ExcludeExitNodes {ru}` |
| `TORRC_STRICT_NODES` | `false` | When `true`, Tor refuses to build a circuit at all rather than fall back outside the `*_NODES` lists above (`StrictNodes 1`). Only meaningful combined with one of the vars above. |

Country codes use Tor's `{cc}` syntax and can be combined/comma-separated,
e.g. `TORRC_EXIT_NODES="{us},{nl},{ch}"`. See the [Tor manual's node
selection section](https://2019.www.torproject.org/docs/tor-manual.html.en)
for the full expression syntax (individual fingerprints, `{cc}` country
codes, etc.).

### Bridges / pluggable transports

The image already ships `lyrebird` (obfs4) — these variables activate it.

| Variable | Default | Description |
|---|---|---|
| `TORRC_ENABLE_BRIDGES` | `false` | Enable bridge mode (`UseBridges 1`) |
| `TORRC_BRIDGE_LINES` | *(unset)* | One or more `Bridge` lines, newline-separated (a YAML block scalar in Compose) or using the literal `\n` sequence as a separator for single-line sources. Each line is written verbatim after `Bridge `, e.g. `obfs4 192.0.2.1:443 FINGERPRINT cert=... iat-mode=0`. |
| `TORRC_BRIDGE_TRANSPORT` | `obfs4` | Which `ClientTransportPlugin` line to emit. Set to an empty string to skip emitting one (e.g. for vanilla, non-pluggable-transport bridges). |
| `TORRC_LYREBIRD_PATH` | `/usr/bin/lyrebird` | Path to the pluggable-transport binary used in the `ClientTransportPlugin` line |

Get bridge lines from [bridges.torproject.org](https://bridges.torproject.org)
or by emailing `bridges@torproject.org`.

## Privoxy (HTTP front-end)

Privoxy ships in every build of this image but only runs when
`PRIVOXY_ENABLE=true`. When enabled, it forwards everything through
Tor's SOCKS5 proxy over loopback (`127.0.0.1`, since both processes share
one container/network namespace) — giving HTTP/HTTPS-only clients
(`http_proxy`/`https_proxy` env vars, browser proxy settings, some CLI
tools) a way into Tor without speaking SOCKS directly.

Tor and Privoxy are supervised independently. A crash in one doesn't
restart the other — Privoxy just fails to reach the SOCKS port until Tor
recovers, and a Privoxy crash has no effect on Tor since Privoxy isn't
a dependency of it. `docker exec <container> ps` shows both processes
running side by side under s6's supervision tree.

All Privoxy runtime-config variables use a `PRIVOXY_` prefix — see
[`Tor/services/privoxy/run`](./Tor/services/privoxy/run) for the full
reference.

| Variable | Default | Description |
|---|---|---|
| `PRIVOXY_ENABLE` | `false` | Enable Privoxy. When `false`, the service idles and does nothing. |
| `PRIVOXY_LISTEN_ADDRESS` | `0.0.0.0` | Interface Privoxy listens on |
| `PRIVOXY_LISTEN_PORT` | `8118` | Privoxy's HTTP proxy port |
| `PRIVOXY_TOR_SOCKS_HOST` | `127.0.0.1` | Host of the upstream Tor SOCKS5 proxy — loopback by default since Tor runs in the same container |
| `PRIVOXY_TOR_SOCKS_PORT` | `9050` | Port of the upstream Tor SOCKS5 proxy — should match `TORRC_SOCKS_PORT` |
| `PRIVOXY_FORWARD_DNS` | `true` | When `true`, DNS resolution happens remotely via Tor (`forward-socks5t`, no local DNS leak). When `false`, resolves locally first (`forward-socks5`) — **not recommended**, leaks hostnames outside Tor. |
| `PRIVOXY_ENABLE_FILTERS` | `true` | Enable Privoxy's default ad/tracker/banner content filtering. When `false`, traffic is relayed with no filtering. |
| `PRIVOXY_ENABLE_LOGGING` | `false` | Enable Privoxy's own request logging. Off by default — verbose request logs are themselves a privacy leak on an anonymizing proxy. |
| `PRIVOXY_TRUSTED_CIDRS` | *(unset)* | Comma-separated CIDRs allowed to connect (`permit-access` lines), e.g. `10.0.0.0/8,192.168.0.0/16`. Restrict this in any multi-tenant/shared-network deployment. |

```bash
docker compose up tor-privoxy
```

then point a client at `http://localhost:8118`:

```bash
curl -x http://localhost:8118 https://check.torproject.org/api/ip
```

### Multi-port hidden service

Tor expresses multiple ports on one onion address as repeated
`HiddenServicePort` lines under a single `HiddenServiceDir` — there's no
single-line list syntax in `torrc`. The `tor` service's `run` script
builds that from `TORRC_HS_PORTS`:

```yaml
environment:
  TORRC_ENABLE_HS: "true"
  TORRC_HS_PORTS: "80:10.2.0.2:80,443:10.2.0.2:443"
```

produces:

```
HiddenServiceDir /var/lib/tor/hidden_service
HiddenServicePort 80 10.2.0.2:80
HiddenServicePort 443 10.2.0.2:443
```

### Reusing an onion address (secrets)

Mount an existing `hs_ed25519_secret_key` as a Docker secret and the
`tor` service copies it into the hidden service directory with the
ownership/permissions Tor requires (secrets mount read-only and
root-owned by default, which Tor refuses to start against):

```yaml
secrets:
  - source: tor_hs_ed25519_secret_key
    target: tor_hs_ed25519_secret_key

secrets:
  tor_hs_ed25519_secret_key:
    file: /path/to/onion/keys/folder/hs_ed25519_secret_key
```

Only the secret key is seeded — Tor derives the matching public key and
`.onion` hostname itself on first start.

### Persistence

Mount volumes over `/var/lib/tor` (Tor's data directory, including the
hidden service key/state) and `/etc/tor` (the generated `torrc`) if you
need state to survive container recreation — see the `tor-hs` example
service in `docker-compose.yml`.

## Security notes

- `TORRC_ENABLE_CONTROL=true` enables `CookieAuthentication` only — no
  password auth is configured. Don't expose the ControlPort beyond
  `localhost`/a trusted network without adding `HashedControlPassword`
  (via `tor --hash-password`) first.
- The Hidden Service directory is set to `700` and its key file to
  `600`, owned by the `tor` user, on every container start.
- `TORRC_STRICT_NODES=true` trades availability for guarantee: Tor will
  refuse to build circuits at all if it can't satisfy your `*_NODES`
  constraints, rather than silently falling back to unrestricted routing.
- `PRIVOXY_FORWARD_DNS=false` (opt-out of remote DNS resolution) leaks
  hostnames to whatever resolver the container/host uses, defeating part
  of the point of routing through Tor — leave this at its `true` default
  unless you specifically need local resolution.
- `PRIVOXY_TRUSTED_CIDRS` is unset by default, meaning Privoxy accepts
  connections from wherever `PRIVOXY_LISTEN_ADDRESS` binds (`0.0.0.0` by
  default = everywhere). Set it explicitly in any deployment where the
  Privoxy port might be reachable from an untrusted network.
- Tor and Privoxy share one container/network namespace: a compromise of
  one process has local (loopback) network visibility into the other.
  This is the trade-off of running both in a single container instead of
  separate ones — weigh it against your threat model.

## Building

Images are built with `docker buildx bake`, not `docker build` or
`docker compose build`:

```bash
bash bake.sh            # build the default group (the "tor" target)
bash bake.sh --push     # build and push to REGISTRY
bash bake.sh --print    # resolve and print the full config, no build
```

`bake.sh` sets `GIT_SHA`/`GIT_REF` from the local git checkout before
invoking `docker buildx bake -f docker-bake.hcl`; these feed the
`org.opencontainers.image.revision`/`ref.name` labels defined in
`docker-bake.hcl`'s `oci_labels()` function. Everything else CI needs
(`REGISTRY`, `SOURCE_URL`) is also just environment variables the bake
file reads — see [`docker-bake.hcl`](./docker-bake.hcl) for the full
list and their defaults.

### Bumping the base image

The Alpine base is pinned by digest, not just tag, so upstream can't
silently repoint it. To bump:

```bash
docker pull alpine:edge --platform linux/amd64
docker inspect --format='{{index .RepoDigests 0}}' alpine:edge
```

and update `ALPINE_BASE.digest` in `docker-bake.hcl`.

### Bumping package versions

`TOR_VERSION`, `NYX_VERSION`, `LYREBIRD_VERSION`, and `PRIVOXY_VERSION` in
`docker-bake.hcl` select exact `apk` package versions at build time. Bump
them there.
Or `docker run --rm alpine:edge sh -c "apk update && apk policy tor nyx lyrebird privoxy"`

### Bumping s6-overlay

`S6_OVERLAY_VERSION` in `docker-bake.hcl` selects the s6-overlay release
extracted into the image (see [Process supervision](#process-supervision-s6-overlay)
below). Check [the releases page](https://github.com/just-containers/s6-overlay/releases)
for the current version; the Dockerfile downloads and verifies both the
noarch and architecture-specific tarballs against their published sha256
checksums at build time, so a bad version string or corrupted download
fails the build rather than shipping silently.

## Process supervision (s6-overlay)

Tor and Privoxy run as two independently-supervised
[s6-overlay](https://github.com/just-containers/s6-overlay) services:

```
Tor/services/
├── tor/run       # writes /etc/tor/torrc, execs tor
└── privoxy/run   # writes /etc/privoxy/config, execs privoxy (or idles if PRIVOXY_ENABLE=false)
```

The container's `ENTRYPOINT` is s6-overlay's own `/init`, which becomes
PID 1 and starts both services. If Tor crashes, s6 restarts only Tor;
Privoxy is unaffected (it just can't reach the SOCKS port until Tor is
back). If Privoxy crashes, only Privoxy restarts. This replaces an
earlier two-image design where Tor and Privoxy were separate containers
— now they're one image, with Privoxy toggled on/off via
`PRIVOXY_ENABLE`, but each process still fails and restarts on its own.

## CI

`.github/workflows/` builds and pushes the `default` bake group on
pushes to `main`, on version tags (`v*.*.*`), and on pull requests
(build-only, no push). Works unmodified against GitHub Actions or a
compatible self-hosted Gitea Actions runner — the registry host and
image prefix are derived from `github.server_url`/`github.repository`
at runtime rather than hardcoded.

## Layout

```
.
├── Tor/
│   ├── Dockerfile           # single stage: packages + s6-overlay install
│   └── services/
│       ├── tor/run          # s6 service: writes torrc from TORRC_* env vars, execs tor
│       └── privoxy/run      # s6 service: writes privoxy config from PRIVOXY_* env vars, execs privoxy
├── docker-bake.hcl       # build definition (target, labels, base pin)
├── bake.sh               # wraps buildx bake, injects GIT_SHA/GIT_REF
├── docker-compose.yml    # example services: SOCKS5, exit-node select, bridges, tor+privoxy, hidden service
└── .github/workflows/    # CI: build + push via buildx bake
```

Links
-----
* [Project home page (GitHub)](https://github.com/arasemco/docker-tor)
* [`tor` image (GHCR)](https://github.com/arasemco/docker-tor/pkgs/container/tor)
* [Tor Project](https://www.torproject.org)
* [Privoxy](https://www.privoxy.org)
* [s6-overlay](https://github.com/just-containers/s6-overlay)

Bugs
----
Please report bugs, issues, and feature requests on
[GitHub Issues](https://github.com/arasemco/docker-tor/issues).

## License

MIT — see [`LICENSE`](./LICENSE).
