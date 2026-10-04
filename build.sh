#!/usr/bin/env bash
# Build the sandbox images for the Mistral Vibe devcontainer toolkit.
#
# Produces:
#   mistral-vibe-sandbox         - the runtime image (python + tools + vibe CLI
#                                  + the startup security check)
#   mistral-vibe-sandbox-proxy   - the egress proxy image (squid + hardened config)
#
# Every build fetches the CURRENT base images (--pull) and re-runs every
# layer (--no-cache), so a build always delivers the latest base OS
# packages and the latest Vibe CLI. Layer caching is deliberately off:
# updates at build time are the requirement; build speed is the cost.
#
# Tags per image:
#   :latest                  - referenced by every project's compose.yaml
#   :<date>-<short image id> - e.g. 2026-10-04-a1b2c3d4e5f6. Identifies the
#                             exact build, survives same-day rebuilds, and is
#                             idempotent: identical content -> identical tag.
#
# Every build is appended to image/builds.log (per-host, gitignored):
# UTC timestamp, structured tag, full image ID, and the toolkit repo's git
# HEAD. Use it to roll back to an exact build:
#   podman tag <structured tag or image ID> mistral-vibe-sandbox:latest

set -euo pipefail

cd "$(dirname "$0")"

BUILDS_LOG="image/builds.log"

log_build() { # <image-name> <tag> <full-image-id>
    local ts git_head
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    git_head=$(git rev-parse --short HEAD 2>/dev/null || echo "-")
    printf '%s  %-50s  %s  git:%s\n' "$ts" "$1:$2" "$3" "$git_head" >> "$BUILDS_LOG"
}

build_image() { # <image-name> <dockerfile>
    local name="$1" dockerfile="$2" id short tag
    echo "== building ${name} (pulls current base, no layer cache) =="
    podman build \
        --pull --no-cache \
        -t "${name}:latest" \
        -f "image/${dockerfile}" \
        image/

    id=$(podman image inspect --format '{{.Id}}' "${name}:latest")
    short=$(printf '%s' "${id#sha256:}" | cut -c1-12)
    tag="$(date +%Y-%m-%d)-${short}"
    podman tag "$id" "${name}:${tag}"
    log_build "$name" "$tag" "$id"
    echo "  tagged: ${name}:${tag}"
    echo
}

build_image mistral-vibe-sandbox runtime.Dockerfile
build_image mistral-vibe-sandbox-proxy proxy.Dockerfile

echo "== done =="
echo
echo "Recent builds (${BUILDS_LOG}):"
tail -n 4 "$BUILDS_LOG"
echo
podman images | grep -E 'mistral-vibe-sandbox' || true
