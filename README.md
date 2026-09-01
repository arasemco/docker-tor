# tor

A minimal Tor proxy container: SOCKS5, ControlPort, and Hidden Service
support, all toggled at runtime via environment variables — one image,
no build-time variants.

Built from Alpine, base image pinned by digest (see [`docker-bake.hcl`](./docker-bake.hcl)).

## Images

| Tag | Contents |
|---|---|
| `ghcr.io/arasemco/tor:latest` | Latest build off `main` |
| `ghcr.io/arasemco/tor:<TOR_VERSION>` | Pinned to a specific Tor package version, e.g. `0.4.9.11-r0` |

## Quick start

```bash
docker compose up tor
```

Starts a plain SOCKS5 proxy on `localhost:9050`. See [`docker-compose.yml`](./docker-compose.yml)
for the full set of example services, including a hidden-service example
(`tor-hs`).

## Runtime configuration

Nothing is baked into the image at build time except package versions —
what actually runs (SOCKS only, hidden service only, or both together) is
decided by environment variables read by [`entrypoint.sh`](./Tor/entrypoint.sh)
on container start, which writes `/etc/tor/torrc` accordingly.

| Variable | Default | Description |
|---|---|---|
| `ENABLE_SOCKS` | `false` | Enable the SOCKS5 proxy |
| `SOCKS_PORT` | `9050` | SOCKS5 listen port |
| `ENABLE_CONTROL` | `false` | Enable the Tor ControlPort (cookie auth only — see [Security notes](#security-notes)) |
| `CONTROL_PORT` | `9051` | ControlPort listen port |
| `ENABLE_HS` | `false` | Enable the Hidden Service |
| `HS_PORT` / `HS_TARGET` | `80` / `127.0.0.1:80` | Single-port hidden service shorthand |
| `HS_PORTS` | *(unset)* | Comma-separated `<virtport>:<target>` pairs for a multi-port hidden service, e.g. `80:10.2.0.2:80,443:10.2.0.2:443`. Takes priority over `HS_PORT`/`HS_TARGET` when set. |
| `HS_SECRET_KEY_FILE` | `/run/secrets/tor_hs_ed25519_secret_key` | Path to an existing `hs_ed25519_secret_key` to seed into the hidden service directory, so the container reuses a known onion address instead of generating a new one on first start |

### Multi-port hidden service

Tor expresses multiple ports on one onion address as repeated
`HiddenServicePort` lines under a single `HiddenServiceDir` — there's no
single-line list syntax in `torrc`. `entrypoint.sh` builds that from
`HS_PORTS`:

```yaml
environment:
  ENABLE_HS: "true"
  HS_PORTS: "80:10.2.0.2:80,443:10.2.0.2:443"
```

produces:

```
HiddenServiceDir /var/lib/tor/hidden_service
HiddenServicePort 80 10.2.0.2:80
HiddenServicePort 443 10.2.0.2:443
```

### Reusing an onion address (secrets)

Mount an existing `hs_ed25519_secret_key` as a Docker secret and
`entrypoint.sh` copies it into the hidden service directory with the
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

- `ENABLE_CONTROL=true` enables `CookieAuthentication` only — no
  password auth is configured. Don't expose the ControlPort beyond
  `localhost`/a trusted network without adding `HashedControlPassword`
  (via `tor --hash-password`) first.
- The Hidden Service directory is set to `700` and its key file to
  `600`, owned by the `tor` user, on every container start.

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

`TOR_VERSION`, `NYX_VERSION`, and `LYREBIRD_VERSION` in `docker-bake.hcl`
select exact `apk` package versions at build time. Bump them there.
Or `docker run --rm alpine:edge sh -c "apk update && apk policy tor nyx lyrebird"`

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
│   ├── Dockerfile        # base + tor stages
│   └── entrypoint.sh     # writes torrc from env vars, execs tor
├── docker-bake.hcl       # build definitions (targets, labels, base pin)
├── bake.sh               # wraps buildx bake, injects GIT_SHA/GIT_REF
├── docker-compose.yml    # example services: plain SOCKS5, hidden service
└── .github/workflows/    # CI: build + push via buildx bake
```

## License

MIT
