# Mistral Vibe Dev Container

A pre-configured development environment for [Mistral Vibe CLI](https://github.com/mistralai/mistral-vibe) that runs in a containerized VS Code workspace.

## Features

- **Python 3.12** (slim Bookworm base)
- **Non-root user** (`vscode:1000`) for security
- **Mistral Vibe CLI** pre-installed
- **Persistent state**: Vibe config, credentials, logs, and agents survive container rebuilds via a named Docker volume
- **Git** installed for repo status access

## Quick Start

1. Open this folder in **VS Code**
2. When prompted, click **"Reopen in Container"**
3. VS Code will build the container and start the environment
4. Verify with: `vibe --version`

## Manual Build (Optional)

```bash
# Build the image
docker build -t mistral-vibe ./.devcontainer

# Run the container
docker run -it --rm \
  -v "$(pwd):/workspaces/mistral-vibe" \
  -v "mistral-vibe-home:/home/vscode/.vibe" \
  mistral-vibe
```

## Configuration Files

| File | Description |
|------|-------------|
| `.devcontainer/Dockerfile` | Container image definition |
| `.devcontainer/devcontainer.json` | VS Code Dev Containers settings |

## Notes

- The `.vibe` directory in the container home is persisted via a Docker volume, independent of the workspace bind mount.
- The workspace is bind-mounted from your host machine, so file changes are immediate and persistent.
