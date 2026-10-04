#!/usr/bin/env bash
# Build the sandbox images for the Mistral Vibe devcontainer toolkit.
#
# Produces:
#   mistral-vibe-sandbox         - the runtime image (python + tools + vibe CLI
#                                  + the startup security check)
#   mistral-vibe-sandbox-proxy   - the egress proxy image (squid + hardened config)
#
# Each image gets two tags: :latest (referenced by every project's
# compose.yaml) and a dated tag for rollback (roll back by retagging:
# podman tag mistral-vibe-sandbox:2026-10-04 mistral-vibe-sandbox:latest).

set -euo pipefail

cd "$(dirname "$0")"

DATE_TAG=$(date +%Y-%m-%d)

echo "== building runtime image =="
podman build \
    -t mistral-vibe-sandbox:latest \
    -t "mistral-vibe-sandbox:${DATE_TAG}" \
    -f image/runtime.Dockerfile \
    image/

echo "== building proxy image =="
podman build \
    -t mistral-vibe-sandbox-proxy:latest \
    -t "mistral-vibe-sandbox-proxy:${DATE_TAG}" \
    -f image/proxy.Dockerfile \
    image/

echo
echo "== done =="
podman images | grep -E 'mistral-vibe-sandbox' || true
