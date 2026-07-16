FROM python:3.12-slim-bookworm

# Non-root user, uid/gid 1000 to match the conventional devcontainer default.
RUN groupadd --gid 1000 vscode \
    && useradd --uid 1000 --gid 1000 -m -s /bin/bash vscode

# git: Vibe reads repo status for context.
RUN apt-get update \
    && apt-get install -y --no-install-recommends git \
    && rm -rf /var/lib/apt/lists/*

# Mistral Vibe CLI (https://github.com/mistralai/mistral-vibe) - installed
# system-wide; per-user state/config lives under $HOME/.vibe, which is
# mounted from a named volume by devcontainer.json so it survives rebuilds.
RUN pip install --no-cache-dir mistral-vibe

# Ensure .vibe directory exists and has correct permissions
RUN mkdir -p /home/vscode/.vibe && chown vscode:vscode /home/vscode/.vibe

USER vscode
