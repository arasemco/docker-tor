// =============================================================================
// docker-bake.hcl — build definitions for the Tor proxy container image
// =============================================================================
//
// A single "tor" target builds from the Dockerfile in ./Tor. As of the
// s6-overlay merge, this is ONE image running both Tor and (optionally)
// Privoxy, supervised independently by s6-overlay — see Tor/Dockerfile
// and Tor/services/{tor,privoxy}/run. This replaces the previous
// two-target design ("tor" + "tor-privoxy" as separate images); Privoxy
// is now a runtime toggle (PRIVOXY_ENABLE) on the same image rather than
// a separate build.
//
// Usage (via bake.sh):
//   bash bake.sh --print   # resolve and print the full config, no build
//   bash bake.sh           # build the "default" group (the "tor" target)
//   bash bake.sh --push    # build and push
//
// GIT_SHA/GIT_REF/REGISTRY/etc. can't be detected from inside this file —
// HCL has no access to git, the filesystem, or CI context. bake.sh computes
// them (e.g. `git rev-parse HEAD`) and exports them as env vars before
// calling `docker buildx bake`, since env vars override a `variable`
// block's default whenever the names match. The defaults below only cover
// a bare, no-args build.

// REGISTRY: where images get pushed (e.g. ghcr.io/arasemco).
// SOURCE_URL: where the code lives. Kept separate from REGISTRY on purpose —
// this repo may push to more than one git remote under different usernames
// on each, but a build from either host can still push to the same
// REGISTRY, so the two shouldn't be derived from one another.
variable "REGISTRY"   { default = "ghcr.io/arasemco" }
variable "SOURCE_URL" { default = "https://github.com/arasemco/docker-tor" }

// Static identity/provenance metadata, same across every build — grouped
// into one map so oci_labels() can pull it all from a single
// PROVENANCE_METADATA.* reference instead of three separate variables.
// Doesn't vary per-build like GIT_SHA/GIT_REF do, so it's safe to leave as
// a plain default rather than something CI has to inject.
variable "PROVENANCE_METADATA" {
  default = {
    authors  = "Aram SEMO <aram.semo@asemo.pro>",
    vendor   = "asemo.pro",
    licenses = "MIT",
  }
}

// Base image pinned by digest, not just tag — Alpine's floating tags
// (including "edge") can be repointed upstream at any time, so pinning
// here guarantees every build starts from the exact same layer.
//
// NOTE: the digest below is a PLACEHOLDER. Resolve the real one before
// building:
//   docker pull alpine:edge --platform linux/amd64
//   docker inspect --format='{{index .RepoDigests 0}}' alpine:edge
// and paste the sha256:... value in here.
variable "ALPINE_BASE" {
  default = {
    name   = "docker.io/library/alpine"
    tag    = "3.24.1"
    digest = "sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b"
  }
}

// Turns a base map into the full "name:tag@digest" string a Dockerfile's
// FROM instruction accepts, so the Dockerfile receives one string
// (ALPINE_REF) rather than reassembling the pin itself.
// To bump the base image: update its digest here (docker pull <name>:<tag>
// --platform linux/amd64 and copy the resulting digest), not just its tag.
function "pinned_ref" {
  params = [base]
  result = "${base.name}:${base.tag}@${base.digest}"
}

// Pinned upstream Alpine package versions, passed to the Dockerfile as
// build args to select what actually gets installed. Verify current
// values with, e.g.: docker run --rm alpine:<tag> sh -c "apk update &&
// apk policy tor nyx lyrebird privoxy" — these drift over time as Alpine
// repos update, and a stale pin here is a build-time failure, not a
// silent problem, so it's always caught before shipping.
variable "TOR_VERSION"      { default = "0.4.9.11-r0" }
variable "NYX_VERSION"      { default = "2.1.0-r6"    }
variable "LYREBIRD_VERSION" { default = "0.8.1-r5"    }
variable "PRIVOXY_VERSION"  { default = "4.0.0-r0"    }

// s6-overlay release version — see Tor/Dockerfile's own comment for how
// this is verified (sha256 checksums fetched and checked at build time).
// Bump by checking https://github.com/just-containers/s6-overlay/releases.
variable "S6_OVERLAY_VERSION" { default = "3.2.3.0" }

// Default to "unknown" rather than empty string — a bare build outside of
// bake.sh (or before the first commit) can't know these, and "unknown" is
// unambiguous in the resulting image.revision/ref.name labels. Set normally
// by bake.sh via `git rev-parse HEAD` / `git symbolic-ref --short HEAD`.
variable "GIT_SHA" { default = "unknown" }
variable "GIT_REF" { default = "unknown" }

// Comma-separated string, not an HCL list — env vars are always strings,
// so this can be overridden with PLATFORMS=linux/amd64,linux/arm64 without
// touching the file. split(",", PLATFORMS) below turns it into the list
// `platforms` actually needs. NOTE: Tor/Dockerfile's TARGETARCH ->
// s6-overlay-arch mapping currently only covers amd64/arm64 — extend that
// mapping in the Dockerfile before adding other platforms here.
variable "PLATFORMS" { default = "linux/amd64" }


// -----------------------------------------------------------------------
// Labels
// -----------------------------------------------------------------------
// Custom (non-OCI-standard) labels describing the upstream products this
// image packages. Both are applied unconditionally now (not per-target,
// since there's only one target) — Privoxy's labels are included even
// though PRIVOXY_ENABLE defaults to false, because the software is
// present in the image regardless of whether it's toggled on at runtime.
variable "TOR_LABELS" {
  default = {
    "org.torproject.product" = "Tor"
    "org.torproject.website" = "https://www.torproject.org"
    "org.torproject.docs"    = "https://support.torproject.org"
    "org.torproject.source"  = "https://gitlab.torproject.org/tpo/core/tor"
  }
}

variable "PRIVOXY_LABELS" {
  default = {
    "org.privoxy.product" = "Privoxy"
    "org.privoxy.website" = "https://www.privoxy.org"
    "org.privoxy.docs"    = "https://www.privoxy.org/user-manual/"
    "org.privoxy.source"  = "https://github.com/ndbroadbent/privoxy"
  }
}

// -----------------------------------------------------------------------
// OCI Labels function - pure OCI standard labels only
// -----------------------------------------------------------------------
// Centralizes every org.opencontainers.image.* label so the target calls
// this once with its own title/description/version/base, instead of
// duplicating ~14 label lines inline.
//
// image.documentation links to the README at GIT_SHA specifically (falling
// back to "main" only if GIT_SHA is unknown), so a label baked into an old
// image points at the docs as they existed at build time, not whatever
// main has since become.
function "oci_labels" {
  params = [
    title,        // human-readable image title
    description,  // human-readable description of the packaged software
    version,      // packaged software version, ideally semver
    base,         // the base image map above (ALPINE_BASE) "dict of name, tag and digest"
  ]
  result = {
    "org.opencontainers.image.created"       = timestamp()
    "org.opencontainers.image.authors"       = PROVENANCE_METADATA.authors
    "org.opencontainers.image.url"           = SOURCE_URL
    "org.opencontainers.image.documentation" = "${SOURCE_URL}/blob/${GIT_SHA != "unknown" ? GIT_SHA : "main"}/README.md"
    "org.opencontainers.image.source"        = SOURCE_URL
    "org.opencontainers.image.version"       = version
    "org.opencontainers.image.revision"      = GIT_SHA
    "org.opencontainers.image.vendor"        = PROVENANCE_METADATA.vendor
    "org.opencontainers.image.licenses"      = PROVENANCE_METADATA.licenses
    "org.opencontainers.image.ref.name"      = GIT_REF
    "org.opencontainers.image.title"         = title
    "org.opencontainers.image.description"   = description
    "org.opencontainers.image.base.name"     = "${base.name}:${base.tag}"
    "org.opencontainers.image.base.digest"   = base.digest
  }
}

// default group: `bash bake.sh` with no target name builds the one image.
group "default" {
  targets = ["tor"]
}

// Single runtime image. Tor and Privoxy are both present in every build;
// which processes actually run, and Tor's SOCKS/control/hidden-service/
// node-selection/bridge configuration, are runtime toggles (each
// service's s6 run script writes its own config file from env vars at
// container start) — not build-time variants. Tagged by TOR_VERSION
// since Tor is the image's primary purpose; PRIVOXY_VERSION isn't part
// of the tag but is captured in the image's labels.
target "tor" {
  context    = "Tor"
  dockerfile = "Dockerfile"
  pull       = true

  args = {
    ALPINE_REF         = pinned_ref(ALPINE_BASE)
    TOR_VERSION        = TOR_VERSION
    NYX_VERSION        = NYX_VERSION
    LYREBIRD_VERSION   = LYREBIRD_VERSION
    PRIVOXY_VERSION    = PRIVOXY_VERSION
    S6_OVERLAY_VERSION = S6_OVERLAY_VERSION
  }

  tags = [
    "${REGISTRY}/tor:latest",
    "${REGISTRY}/tor:${TOR_VERSION}",
  ]

  labels = merge(
    TOR_LABELS,
    PRIVOXY_LABELS,
    oci_labels(
      "tor",
      "Tor proxy (SOCKS5/ControlPort/Hidden Service/bridges/node selection) with an optional Privoxy HTTP front-end, both supervised by s6-overlay and toggled at runtime via env vars",
      TOR_VERSION,
      ALPINE_BASE,
    )
  )

  platforms = split(",", PLATFORMS)
}
