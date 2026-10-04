FROM python:3.12-slim-bookworm

# Non-root user, uid/gid 1000 to match the conventional devcontainer default.
RUN groupadd --gid 1000 vscode \
    && useradd --uid 1000 --gid 1000 -m -s /bin/bash vscode

# Tooling for the agent sandbox. Client utilities only - nothing that
# listens, nothing that elevates (sudo), nothing that talks to container
# engines. The sandbox boundary (mounts, caps, internal network, egress
# proxy) is enforced outside the container, so these add capability, not
# attack surface:
#   git        - Vibe reads repo status for context
#   curl       - network debugging, downloads, egress verification
#   ripgrep    - fast code search
#   jq         - JSON inspection for agent/vibe configs and logs
#   procps     - ps/top for process diagnostics
#   iproute2   - ip/ss for network diagnostics (cannot reconfigure - no caps)
RUN apt-get update \
    && apt-get install -y --no-install-recommends git curl ripgrep jq procps iproute2 \
    && rm -rf /var/lib/apt/lists/*

# Mistral Vibe CLI (https://github.com/mistralai/mistral-vibe) - installed
# system-wide; per-user state/config lives under $HOME/.vibe, which is
# mounted from a named volume by the devcontainer so it survives rebuilds.
RUN pip install --no-cache-dir mistral-vibe

# Ensure .vibe directory exists and has correct permissions
RUN mkdir -p /home/vscode/.vibe && chown vscode:vscode /home/vscode/.vibe

# Startup security posture check - shipped IN the image so every project
# using this sandbox gets the current check without copying files.
# Kept last: it changes more often than the layers above, so the build
# cache stays effective.
COPY security-check.sh /usr/local/bin/sandbox-security-check
RUN chmod 0755 /usr/local/bin/sandbox-security-check

USER vscode
