# Egress proxy image for the vibe sandbox.
#
# Stock ubuntu/squid plus our hardened squid.conf baked in, so consuming
# projects need no config files - only the compose wiring. Config changes
# ship via rebuilding this image (see build.sh in the repo root).
FROM ubuntu/squid:latest

COPY squid.conf /etc/squid/squid.conf
RUN chmod 0644 /etc/squid/squid.conf
