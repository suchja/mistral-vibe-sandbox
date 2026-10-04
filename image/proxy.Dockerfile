# Egress proxy image for the vibe sandbox.
#
# Stock ubuntu/squid plus our hardened squid.conf baked in, so consuming
# projects need no config files - only the compose wiring. Config changes
# ship via rebuilding this image (see build.sh in the repo root).
FROM ubuntu/squid:latest

LABEL org.opencontainers.image.title="mistral-vibe-sandbox-proxy" \
      org.opencontainers.image.description="Egress proxy (squid) for the Mistral Vibe devcontainer sandbox"

COPY --chmod=0644 squid.conf /etc/squid/squid.conf
