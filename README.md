# Mistral Vibe Dev Container

A pre-configured development environment for [Mistral Vibe CLI](https://github.com/mistralai/mistral-vibe) that runs in a containerized VS Code workspace.

## Features

- **Python 3.12** (slim Bookworm base)
- **Non-root user** (`vscode:1000`) for security
- **Mistral Vibe CLI** pre-installed
- **Persistent state**: Vibe config, credentials, logs, and agents survive container rebuilds via a named Docker volume
- **Git** installed for repo status access
- **Sandbox hardening**: all Linux capabilities dropped, `no-new-privileges` set, and memory/CPU/PID limits applied so the container can only touch the bind-mounted project folder and can't starve the host
- **Network egress control**: the sandbox container sits on an internal-only Docker network with no direct route to the host, LAN, or internet. All traffic exits through a hardened Squid proxy (`ubuntu/squid`) that forwards to the public internet but denies any destination in private/reserved ranges — so web research and package installs work, but reaching your machine or local network is blocked

## Quick Start

1. Open this folder in **VS Code**
2. When prompted, click **"Reopen in Container"**
3. VS Code will build the container and start the environment
4. Verify with: `vibe --version`

## Manual Build (Optional)

The setup is compose-based; to run it outside VS Code:

```bash
docker compose -f .devcontainer/compose.yaml up -d --build
docker compose -f .devcontainer/compose.yaml exec vibe bash
```

## Configuration Files

| File | Description |
|------|-------------|
| `.devcontainer/Dockerfile` | Container image definition |
| `.devcontainer/devcontainer.json` | VS Code Dev Containers settings (compose wiring) |
| `.devcontainer/compose.yaml` | Services, mounts, resource limits, and networks |
| `.devcontainer/proxy/squid.conf` | Egress rules: internet allowed, private ranges denied |

## Notes

- The `.vibe` directory in the container home is persisted via a named Docker volume, independent of the workspace bind mount.
- The workspace is bind-mounted from your host machine, so file changes are immediate and persistent.
- Git identity is taken read-only from the host's `~/.gitconfig`; create it on the host (`git config --global user.name/user.email`) before the first build. With Docker, a missing file would be silently replaced by a directory; Podman refuses the mount instead.
- All container network traffic goes through the `proxy` service (`HTTP_PROXY`/`HTTPS_PROXY` env). Verify the egress rules from inside the container:
  - `curl -sS -o /dev/null -w '%{http_code}\n' https://example.com` → `200`
  - `curl -sS --max-time 5 http://host.docker.internal` → refused (403 from the proxy)
