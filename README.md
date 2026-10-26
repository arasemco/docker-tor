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
| `ghcr.io/arasemco/tor:<TOR_VERSION>` | Pinned to a specific Tor package version, e.g. `0.4.9.12-r0` |

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
| `TORRC_ENABLE_CONTROL` | `false` | Enable the Tor ControlPort (cookie auth, plus password auth when a secret is provided — see [Security notes](#security-notes)) |
| `TORRC_CONTROL_PORT` | `9051` | ControlPort listen port |
| `TORRC_CONTROL_ADDRESS` | `127.0.0.1` | Interface the ControlPort binds to. A non-loopback address (e.g. `0.0.0.0` so a published port works) is refused at startup unless a control password is supplied. |
| `TORRC_CONTROL_COOKIE_AUTH` | `true` | Set `false` to turn off cookie auth. With no control password either, the ControlPort is unauthenticated: allowed only on loopback, and a warning is logged. Anyone in the same network namespace (e.g. a `network_mode: service:tor` sidecar) can then control Tor. |
| `TORRC_CONTROL_PASSWORD_FILE` | `/run/secrets/tor_control_password` | File with the **plaintext** control password (e.g. a Docker secret). Hashed with `tor --hash-password` at start and written as `HashedControlPassword`; the plaintext never goes into `torrc` or the environment. |
| `TORRC_ENABLE_HS` | `false` | Enable the Hidden Service |
| `TORRC_HS_PORT` / `TORRC_HS_TARGET` | `80` / `127.0.0.1:80` | Single-port hidden service shorthand |
| `TORRC_HS_PORTS` | *(unset)* | Comma-separated `<virtport>:<target>` pairs for a multi-port hidden service, e.g. `80:10.2.0.2:80,443:10.2.0.2:443`. Takes priority over `TORRC_HS_PORT`/`TORRC_HS_TARGET` when set. |
| `TORRC_HS_SECRET_KEY_FILE` | `/run/secrets/tor_hs_ed25519_secret_key` | Path to an existing `hs_ed25519_secret_key` to seed into the hidden service directory, so the container reuses a known onion address instead of generating a new one on first start |

### File ownership (PUID / PGID)

| Variable | Default | Description |
|---|---|---|
| `PUID` | *(unset)* | Remap the `tor` user to this uid so a bind-mounted `/var/lib/tor` is owned by your host user |
| `PGID` | *(unset)* | Remap the `tor` group to this gid |

Applied at start by [`Tor/cont-init.d/05-ids`](./Tor/cont-init.d/05-ids),
before the firewall rules are created. Startup aborts if the id isn't a
positive integer or already belongs to another account. `privoxy` is not
remapped.

> **Firewall caveat:** don't set `PUID` to a uid that any process in a
> container sharing this one's network namespace runs as (for example the
> `client` browser below, which runs as `1000`). The firewall allows
> outbound traffic by numeric uid, so that process would get past it. The
> startup check can only see this container's own users.

### SOCKS entry policy

| Variable | Default | Description |
|---|---|---|
| `TORRC_SOCKS_POLICY` | `accept private:*,reject *` | Comma-separated `accept <CIDR>` / `reject <CIDR>` entries, evaluated first to last (first match wins), each written as its own `SocksPolicy` line. Set to an empty string to emit no `SocksPolicy` lines at all — Tor's own fallback then applies (accept all requests that reach the SocksPort). |

The default accepts all private/local networks (RFC1918 + loopback +
link-local, via Tor's built-in `private` alias) and rejects everything
else, so a bare `TORRC_ENABLE_SOCKS=true` is safe-by-default for
local/LAN clients without setting this explicitly. See the
`tor-socks-policy` example service in `docker-compose.yml` for a
tighter, explicit override.

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

### Firewall

| Variable | Default | Description |
|---|---|---|
| `TORRC_ENABLE_FIREWALL` | `false` | Apply an iptables ruleset restricting all new outbound connections in this container to the `tor` process (plus `privoxy` only if `PRIVOXY_TOR_SOCKS_HOST` is not loopback), before either service starts |
| `TORRC_FIREWALL_ALLOW_INBOUND_PORTS` | *(empty)* | Comma-separated TCP ports to accept new inbound connections on, e.g. `3000,3001`. Only takes effect when `TORRC_ENABLE_FIREWALL=true`. |

This targets a specific deployment shape: another container sharing this
container's network namespace via Compose's `network_mode:
"service:tor"` (see the `tor-locked-down` / `client` pair in
`docker-compose.yml`). A container attached this way has no network
interface of its own — it uses the `tor` container's single interface
directly. With the firewall enabled, only the `tor` process (and
`privoxy`, if it forwards to a non-loopback Tor) may open new outbound
connections on that interface; loopback
and already-established connections are still allowed, but a co-located
process has no path to the network except through one of them. If Tor's
SOCKS port (or Privoxy, when enabled) becomes unreachable, that process
is cut off entirely rather than silently falling back to a direct
connection — the guarantee holds regardless of that process's own proxy
configuration, since it's enforced at the network-namespace level rather
than relying on the process to cooperate.

The base ruleset's `INPUT` chain is default-`DROP` with only loopback
and established/related connections accepted. This means a published
Compose `ports:` mapping can point at a port with a real, working
listener behind it — e.g. a co-located browser's noVNC UI on `3000`/
`3001` — and still be unreachable from outside, because a fresh inbound
connection is `NEW`, not `ESTABLISHED`, and gets dropped before it
reaches that listener. `TORRC_FIREWALL_ALLOW_INBOUND_PORTS` is what
opens specific ports back up for this case; list every port that needs
to accept new inbound connections from outside the container.

Applied via `/etc/cont-init.d/10-firewall`, which s6-overlay always runs
to completion before starting any `/etc/services.d` service — this
ordering guarantee is why the firewall is a `cont-init.d` script and not
a third supervised service, since a supervised oneshot would only race
`tor`/`privoxy`'s own startup rather than strictly precede it.

Requires the `tor` service to run with the `NET_ADMIN` capability
(`cap_add: [NET_ADMIN]` in Compose) — without it, the `iptables` calls in
`cont-init.d/10-firewall` fail, which aborts container startup rather
than silently running unprotected.

## Browser hardening

A network-layer firewall (above) stops a browser sharing this
container's namespace from reaching the network by any path except
Tor/Privoxy — but it doesn't stop that browser from leaking identifying
information *through* the connection Tor/Privoxy do allow. That's a
separate, application-layer problem, and it needs an enterprise policy
on the browser itself. The `tor-locked-down` / `client` example's
`tor_locked_down_firefox_policies` config in `docker-compose.yml` is a
hardened `policies.json` for Firefox-based images (e.g.
`lscr.io/linuxserver/firefox`); the settings below and why each matters:

- **`media.peerconnection.enabled: false`** — disables WebRTC outright.
  WebRTC's STUN/ICE negotiation can establish a connection directly over
  the host's real network stack, independent of the browser's configured
  proxy — the single most common way a "proxied" browser leaks a real IP.
- **`network.proxy.allow_bypass: false`**, **`network.proxy.no_proxies_on: ""`** —
  closes Firefox's built-in bypass-proxy-for-local-addresses mechanism
  and clears any default no-proxy address list, either of which would
  otherwise let some requests skip the PAC-configured proxy entirely.
- **`network.proxy.failover_direct: false`** — the actual kill-switch.
  Firefox's default behavior when its configured proxy is unreachable is
  to fail over to a direct connection; this setting turns a dead proxy
  into a connection error instead of a leak.
- **`network.proxy.socks_remote_dns` / `socks5_remote_dns: true`** —
  forces DNS resolution through the SOCKS proxy rather than locally,
  closing a classic DNS-leak vector.
- **`network.file.disable_uri_open: true`** — blocks handing URLs off to
  external protocol handlers/helper apps, which run outside Firefox's
  proxy settings and outside this container's network namespace entirely.
- **`geo.enabled: false`** plus blanked `geo.provider.network.url` /
  `browser.region.network.url` — Firefox's geolocation API and its
  separate network-based "region" detection (used for search defaults
  and content localization) both contact Mozilla's servers directly,
  independent of the page's own proxy config.
- **`network.captive-portal-service.enabled` / `network.connectivity-service.enabled: false`** —
  background checks Firefox runs against Mozilla's own servers to detect
  network state; both bypass the page-level proxy.
- **`network.dns.disablePrefetch*`, `network.predictor.enabled`,
  `network.prefetch-next`, `network.http.speculative-parallel-limit: 0`** —
  DNS prefetching and predictive preconnects have been documented to leak
  DNS outside the configured proxy in some configurations.
- **`browser.safebrowsing.*: false`** — Safe Browsing / download
  reputation checks upload URLs and file hashes to Google's servers
  directly.
- **`app.update.*`, `extensions.blocklist.enabled: false`** — background
  services that reach Mozilla/AMO directly, independent of the browser's
  proxy configuration.
- **`DisableTelemetry: true`**, **`DisableFirefoxStudies: true`** —
  top-level policy keys covering Firefox's telemetry upload and Normandy/
  Studies system respectively. These are used instead of setting
  `toolkit.telemetry.enabled`, `toolkit.telemetry.unified`,
  `datareporting.healthreport.uploadEnabled`, or `app.normandy.enabled`
  directly under `Preferences` — Firefox rejects all four of those with
  "Preference not allowed for stability reasons" (visible at
  `about:policies#errors`) regardless of policy syntax; the dedicated
  top-level keys are the actual supported mechanism and cover the same
  ground.
- **`EnableTrackingProtection`** (`Value`/`Fingerprinting`/`Cryptomining: true`,
  `Locked: true`) — the supported policy mechanism for tracking and
  fingerprinting protection. `privacy.trackingprotection.enabled` and
  `privacy.resistFingerprinting` are not usable as raw `Preferences`
  entries for the same reason as above; `EnableTrackingProtection`'s
  `Fingerprinting` sub-key is what actually blocks fingerprinting scripts
  under current Firefox policy schema.
- **`webgl.disabled: true`** — not an IP leak, but WebGL renderer strings
  are additional fingerprinting surface that `EnableTrackingProtection`
  alone doesn't cover.

If `about:policies#errors` shows further "not allowed for stability
reasons" entries after editing this policy, that specific preference
needs its own dedicated top-level policy key (as above) or has no
policy-based equivalent at all — trial-and-error editing under
`Preferences` won't produce a different result for a pref already on
that list.

One thing this policy cannot fully guarantee on its own: it depends on
`file:///defaults/proxy.pac` loading and evaluating successfully inside
the browser. If the PAC file fails to load, Firefox's fallback behavior
differs by version, and some treat "no valid proxy config" as "no proxy"
rather than "block everything" — which is exactly the gap the
[Firewall](#firewall) section's network-namespace-level enforcement is
for. The two layers are complementary: the firewall guarantees no
packet leaves the namespace except via Tor/Privoxy regardless of what
the browser does; this policy keeps the browser from volunteering
identifying information through the connection the firewall does allow.

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
| `PRIVOXY_LISTEN_ADDRESS` | `127.0.0.1` | Interface Privoxy listens on. Set `0.0.0.0` to reach it from other containers/hosts (and pair it with `PRIVOXY_TRUSTED_CIDRS`). |
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
hidden service key/state) and `/etc/tor` (the generated `torrc`, owned by
root and only readable by the `tor` group) if you need state to survive
container recreation — see the `tor-hs` example
service in `docker-compose.yml`.

## Security notes

- `TORRC_ENABLE_CONTROL=true` binds the ControlPort to loopback
  (`TORRC_CONTROL_ADDRESS=127.0.0.1`) with `CookieAuthentication`. To
  reach it from outside the container, mount a secret with the control
  password at `TORRC_CONTROL_PASSWORD_FILE` and set
  `TORRC_CONTROL_ADDRESS=0.0.0.0`; startup aborts if you bind a
  non-loopback address without a password. Still keep the port on a
  trusted network.
- The Hidden Service directory is set to `700` and its key file to
  `600`, owned by the `tor` user, on every container start.
- `TORRC_STRICT_NODES=true` trades availability for guarantee: Tor will
  refuse to build circuits at all if it can't satisfy your `*_NODES`
  constraints, rather than silently falling back to unrestricted routing.
- `PRIVOXY_FORWARD_DNS=false` (opt-out of remote DNS resolution) leaks
  hostnames to whatever resolver the container/host uses, defeating part
  of the point of routing through Tor — leave this at its `true` default
  unless you specifically need local resolution.
- Privoxy listens on loopback by default. If you set
  `PRIVOXY_LISTEN_ADDRESS=0.0.0.0` to publish it, also set
  `PRIVOXY_TRUSTED_CIDRS` (unset = accepts anyone who can reach the port).
- Tor and Privoxy share one container/network namespace: a compromise of
  one process has local (loopback) network visibility into the other.
  This is the trade-off of running both in a single container instead of
  separate ones — weigh it against your threat model.
- `/etc/tor` and `/etc/privoxy` (and the generated configs) are owned by
  root and only readable by the daemon's group. The daemons can't change
  their own config, and a compromised daemon can't trick the root-run
  startup scripts into overwriting other files through a symlink.
- The example services in `docker-compose.yml` drop all Linux
  capabilities except the few the startup scripts need and set
  `no-new-privileges`. Keep these settings when you write your own.
- The s6-overlay tarballs are checked against digests pinned in
  `Tor/Dockerfile` / `docker-bake.hcl`. Update them together with
  `S6_OVERLAY_VERSION`.

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
for the current version, and update `S6_SHA256_NOARCH`,
`S6_SHA256_X86_64` and `S6_SHA256_AARCH64` with the values from the
release's `.sha256` files (in `docker-bake.hcl` and the Dockerfile `ARG`
defaults). Both tarballs are checked against these pinned digests at
build time, so a bad version, corrupted download or tampered release
asset fails the build.

## Process supervision (s6-overlay)

Tor and Privoxy run as two independently-supervised
[s6-overlay](https://github.com/just-containers/s6-overlay) services,
with the outbound firewall (when enabled) applied as a `cont-init.d`
step that always completes before either service starts:

```
Tor/
├── cont-init.d/
│   └── 10-firewall   # applies the iptables ruleset if TORRC_ENABLE_FIREWALL=true, then exits
└── services/
    ├── tor/run        # writes /etc/tor/torrc, execs tor
    └── privoxy/run    # writes /etc/privoxy/config, execs privoxy (or idles if PRIVOXY_ENABLE=false)
```

The container's `ENTRYPOINT` is s6-overlay's own `/init`, which becomes
PID 1. On startup it runs every `cont-init.d` script to completion, in
order, before starting any `services.d` service — so `10-firewall`
always finishes applying its ruleset before Tor or Privoxy gets a chance
to open a connection. Once running, if Tor crashes, s6 restarts only
Tor; Privoxy is unaffected (it just can't reach the SOCKS port until Tor
is back). If Privoxy crashes, only Privoxy restarts. This replaces an
earlier two-image design where Tor and Privoxy were separate containers
— now they're one image, with Privoxy toggled on/off via
`PRIVOXY_ENABLE`, but each process still fails and restarts on its own.

## CI

`.github/workflows/` builds and pushes the `default` bake group on
pushes to `main`, on version tags (`v*.*.*`), and on pull requests
(build-only, no push). Before that, a `lint` job runs shellcheck,
hadolint (ignores in `.hadolint.yaml`) and `docker compose config`, and
a `test` job builds the image locally, runs
`.github/scripts/smoke-test.sh` against it and prints a Trivy CVE
report. Works unmodified against GitHub Actions or a
compatible self-hosted Gitea Actions runner — the registry host and
image prefix are derived from `github.server_url`/`github.repository`
at runtime rather than hardcoded.

## Layout

```
.
├── Tor/
│   ├── Dockerfile           # single stage: packages + s6-overlay install
│   ├── cont-init.d/
│   │   └── 10-firewall      # applies outbound firewall before services.d starts, if TORRC_ENABLE_FIREWALL=true
│   └── services/
│       ├── tor/run          # s6 service: writes torrc from TORRC_* env vars, execs tor
│       └── privoxy/run      # s6 service: writes privoxy config from PRIVOXY_* env vars, execs privoxy
├── docker-bake.hcl       # build definition (target, labels, base pin)
├── bake.sh               # wraps buildx bake, injects GIT_SHA/GIT_REF
├── docker-compose.yml    # example services: SOCKS5, socks-policy, locked-down firewall, exit-node select, bridges, tor+privoxy, hidden service
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
