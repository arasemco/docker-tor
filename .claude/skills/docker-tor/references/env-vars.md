# docker-tor environment variables

Every value is read at container start, so restarting the container applies a change. Each variable ends up as the torrc/privoxy line shown in the Effect column. Booleans are the literal strings `true`/`false`.

## Tor: SOCKS / Control / onion service (`Tor/services/tor/run`)

| Variable | Default | Effect |
|---|---|---|
| `TORRC_ENABLE_SOCKS` | `false` | `true` writes `SocksPort 0.0.0.0:<port>` plus the policy lines; otherwise `SocksPort 0` |
| `TORRC_SOCKS_PORT` | `9050` | SOCKS port |
| `TORRC_SOCKS_POLICY` | `accept private:*,reject *` | comma-separated list, one `SocksPolicy` line per entry, first match wins; `""` writes no lines (accept all) |
| `TORRC_ENABLE_CONTROL` | `false` | writes `ControlPort <addr>:<port>` |
| `TORRC_CONTROL_PORT` | `9051` | |
| `TORRC_CONTROL_ADDRESS` | `127.0.0.1` | a non-loopback address requires the password file, or startup aborts |
| `TORRC_CONTROL_COOKIE_AUTH` | `true` | `CookieAuthentication 1/0` |
| `TORRC_CONTROL_PASSWORD_FILE` | `/run/secrets/tor_control_password` | plaintext password, hashed into `HashedControlPassword` |
| `TORRC_ENABLE_HS` | `false` | onion service in `/var/lib/tor/hidden_service` |
| `TORRC_HS_PORT` / `TORRC_HS_TARGET` | `80` / `127.0.0.1:80` | single-port shorthand |
| `TORRC_HS_PORTS` | empty | `virt:host:port,...`; takes priority over the shorthand |
| `TORRC_HS_SECRET_KEY_FILE` | `/run/secrets/tor_hs_ed25519_secret_key` | seeded as `hs_ed25519_secret_key` (600, owned by tor) |

## Tor: node selection

| Variable | Default | Effect |
|---|---|---|
| `TORRC_EXIT_NODES` | empty | `ExitNodes …` e.g. `{us},{de}` |
| `TORRC_ENTRY_NODES` | empty | `EntryNodes …` |
| `TORRC_EXCLUDE_NODES` | empty | `ExcludeNodes …` |
| `TORRC_EXCLUDE_EXIT_NODES` | empty | `ExcludeExitNodes …` |
| `TORRC_STRICT_NODES` | `false` | `StrictNodes 1/0` (1 = fail rather than fall back) |

## Tor: bridges

| Variable | Default | Effect |
|---|---|---|
| `TORRC_ENABLE_BRIDGES` | `false` | `UseBridges 1` |
| `TORRC_BRIDGE_LINES` | empty | one bridge per line (or literal `\n`); `Bridge ` is prefixed |
| `TORRC_BRIDGE_TRANSPORT` | `obfs4` | `ClientTransportPlugin <t> exec <lyrebird>` (empty = no plugin line) |
| `TORRC_LYREBIRD_PATH` | `/usr/bin/lyrebird` | |

## Firewall (`Tor/cont-init.d/10-firewall`)

| Variable | Default | Effect |
|---|---|---|
| `TORRC_ENABLE_FIREWALL` | `false` | default-deny iptables/ip6tables; needs `NET_ADMIN` |
| `TORRC_FIREWALL_ALLOW_INBOUND_PORTS` | empty | comma-separated TCP ports accepting NEW inbound connections |

## IDs (`Tor/cont-init.d/05-ids`)

| Variable | Default | Effect |
|---|---|---|
| `PUID` | unset | new uid for the `tor` user; must not match a uid used by a sidecar container |
| `PGID` | unset | new gid for the `tor` group |

## Privoxy (`Tor/services/privoxy/run`)

| Variable | Default | Effect |
|---|---|---|
| `PRIVOXY_ENABLE` | `false` | `false` makes the service idle (`sleep infinity`) |
| `PRIVOXY_LISTEN_ADDRESS` | `127.0.0.1` | `listen-address` host |
| `PRIVOXY_LISTEN_PORT` | `8118` | |
| `PRIVOXY_TOR_SOCKS_HOST` | `127.0.0.1` | upstream Tor; a non-loopback value also opens privoxy egress in the firewall |
| `PRIVOXY_TOR_SOCKS_PORT` | `9050` | keep equal to `TORRC_SOCKS_PORT` |
| `PRIVOXY_FORWARD_DNS` | `true` | `forward-socks5t` (DNS through Tor); `false` resolves DNS locally and leaks it |
| `PRIVOXY_ENABLE_FILTERS` | `true` | `actionsfile default.action` + `filterfile default.filter` |
| `PRIVOXY_ENABLE_LOGGING` | `false` | `debug 1` + logfile in `/var/log/privoxy` |
| `PRIVOXY_TRUSTED_CIDRS` | empty | `permit-access` lines; set them whenever the listen address is not loopback |

## Quick recipes

```bash
# SOCKS proxy on the host only
docker run -d -p 127.0.0.1:9050:9050 -e TORRC_ENABLE_SOCKS=true ghcr.io/arasemco/tor
curl -x socks5h://127.0.0.1:9050 https://check.torproject.org/api/ip

# SOCKS + HTTP proxy
docker run -d -p 127.0.0.1:8118:8118 -e TORRC_ENABLE_SOCKS=true \
  -e PRIVOXY_ENABLE=true -e PRIVOXY_LISTEN_ADDRESS=0.0.0.0 \
  -e PRIVOXY_TRUSTED_CIDRS=172.16.0.0/12 ghcr.io/arasemco/tor

# Onion service for a web container. Tor needs an IP target, not a
# hostname, so give the backend a fixed IP (see tor-hs in docker-compose.yml).
docker run -d -e TORRC_ENABLE_HS=true -e TORRC_HS_TARGET=10.2.0.2:80 \
  -v tor_var:/var/lib/tor ghcr.io/arasemco/tor
docker exec <c> cat /var/lib/tor/hidden_service/hostname

# Monitor with nyx (ControlPort on loopback, cookie auth)
docker run -d -e TORRC_ENABLE_SOCKS=true -e TORRC_ENABLE_CONTROL=true ghcr.io/arasemco/tor
docker exec -it <c> su-exec tor nyx
```
