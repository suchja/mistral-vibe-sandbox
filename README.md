# Mistral Vibe Sandbox Toolkit

A hardened [Mistral Vibe CLI](https://github.com/mistralai/mistral-vibe) devcontainer sandbox: build the images once, then add the same security boundary to any project with two copyable files. The sandbox can only touch the project folder it is opened on - not the rest of your machine.

## What the sandbox enforces

- **Filesystem**: only the project folder is mounted (read-write); git identity comes from the host's `~/.gitconfig`, read-only; Vibe state lives on a per-project named volume
- **Kernel**: all Linux capabilities dropped, `no-new-privileges`, non-root user (`vscode`), memory/CPU/PID limits
- **Network**: the sandbox sits on an internal-only Docker network with no route to the host, the LAN, or the internet. All egress goes through a hardened Squid proxy that forwards to the public internet but denies any destination in private/reserved ranges
- **Startup verification**: a security posture check runs on every container start and fails the start loudly if any property is violated (see below)

## One-time setup on your machine

1. Clone this repo and build the images:
   ```bash
   ./build.sh
   ```
   This produces `mistral-vibe-sandbox` (runtime: Python 3.12, git, curl, ripgrep, jq, procps, iproute2, the Vibe CLI, and the security check) and `mistral-vibe-sandbox-proxy` (squid with the hardened config baked in), each tagged `:latest` plus a dated tag for rollback.
2. Make sure a host `~/.gitconfig` exists (identity for commits):
   ```bash
   git config --global user.name "Your Name"
   git config --global user.email "you@example.com"
   ```
   With Docker, a missing file would be silently replaced by a directory; Podman refuses the mount instead.
3. Configure VS Code to use podman if you have not already:
   ```json
   "dev.containers.dockerPath": "podman",
   "dev.containers.dockerComposePath": ["podman", "compose"]
   ```

## Use the sandbox in a project

Copy exactly two files from this repo's `.devcontainer/` into the project's `.devcontainer/` folder:

- `devcontainer.json`
- `compose.yaml`

Both are project-agnostic (the workspace is always mounted at `/workspaces/project`). Then open the project in VS Code and choose **Reopen in Container**.

This repo itself uses the same two files - every change to the template is validated here first.

## Updating the sandbox

- Changes to `image/security-check.sh` or `image/squid.conf` ship via `./build.sh`; all projects pick them up on their next container start. No per-project copying.
- Changes to `devcontainer.json` or `compose.yaml` (mounts, limits, wiring) are structural and rare; copy them into projects again when they change.
- To roll back an image change: retag the dated version back to `latest` and restart the containers:
  ```bash
  podman tag mistral-vibe-sandbox:2026-10-04 mistral-vibe-sandbox:latest
  ```

## Manual start (outside VS Code)

```bash
podman compose -f .devcontainer/compose.yaml up -d
podman compose -f .devcontainer/compose.yaml exec vibe bash
```

## Startup Security Check

On every container start, `/usr/local/bin/sandbox-security-check` (baked into the runtime image) runs via `postStartCommand` and verifies the sandbox posture: dropped capabilities, `no-new-privileges`, absence of a default route, presence of resource limits, read-only git identity, the workspace and volume mounts, proxy reachability, and that the proxy denies private destinations.

- A **hard failure** makes the start command exit non-zero - VS Code shows an error. Do not treat the sandbox as isolated until the failure is understood.
- A **warning** does not fail the start: a briefly unreachable proxy means no internet (fail-safe; the container has no route to the host or LAN either way).

You can also run it manually inside any sandbox:

```bash
sandbox-security-check
```

## Repository layout

| File | Description |
|------|-------------|
| `image/runtime.Dockerfile` | Runtime image: Python, tooling, Vibe CLI, security check |
| `image/proxy.Dockerfile` | Proxy image: stock squid plus baked-in hardened config |
| `image/squid.conf` | Egress rules: internet allowed, private ranges denied |
| `image/security-check.sh` | Startup security posture check (single source of truth) |
| `build.sh` | Builds and tags both images |
| `.devcontainer/devcontainer.json` | Template (copy into projects) |
| `.devcontainer/compose.yaml` | Template (copy into projects) |

## Notes

- The `.vibe` directory (Vibe state, credentials, agents) is persisted per project via a named volume derived from the compose project name. Concurrent project sandboxes do not share one credentials store; the cost is a one-time Vibe login per project.
- The proxy service intentionally keeps default capabilities: squid needs `setuid`/`setgid` to drop to its internal user, and dropping all capabilities makes it exit immediately. It is still contained - no published ports, reachable only from the sandbox network, config baked into the image read-only.
- With Podman, host/LAN verification inside the sandbox uses `host.containers.internal`.
- Resource limits (4g memory / 2 CPUs / 256 PIDs) are right-sized for a podman machine with 2+ GB. The security check asserts limits exist, not their exact values, so right-sizing does not break it.
