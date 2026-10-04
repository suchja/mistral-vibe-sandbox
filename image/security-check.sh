#!/usr/bin/env bash
# Sandbox security posture check for the Mistral Vibe devcontainer.
#
# Ships INSIDE the runtime image as /usr/local/bin/sandbox-security-check
# and runs on EVERY container start (postStartCommand in devcontainer.json)
# - so every project using the sandbox gets the current check without
# copying files. Security properties that MUST hold are hard failures: if
# any fails, this script exits non-zero and VS Code surfaces an error -
# do not treat the sandbox as isolated until the failure is understood.
#
# Design notes:
# - Kernel-level properties (caps, routes, mounts, identity) are checked
#   exactly - they are deterministic per start.
# - The workspace is expected at the fixed path /workspaces/project: the
#   devcontainer template mounts every project there, which is what makes
#   it project-agnostic.
# - Resource limits are checked for EXISTENCE, not exact values, so
#   right-sizing compose.yaml does not break this script.
# - A dead/unreachable proxy is a WARNING, not a failure: the sandbox has
#   no default route, so a missing proxy means no egress at all
#   (fail-safe), never access to the host or LAN (fail-open).

set -u

PASS=0; FAIL=0; WARN=0

ok()   { PASS=$((PASS+1)); printf '  [ok]   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }
warn() { WARN=$((WARN+1)); printf '  [warn] %s\n' "$1"; }

WORKSPACE_DIR="/workspaces/project"

echo "== Mistral Vibe sandbox: security posture check =="

# --- Kernel and process properties (hard) ---

eff=$(awk '/^CapEff:/ {print $2}' /proc/1/status)
if [ "$eff" = "0000000000000000" ]; then
    ok "all Linux capabilities dropped (PID 1 CapEff is zero)"
else
    bad "PID 1 still holds capabilities (CapEff=$eff)"
fi

nnp=$(awk '/NoNewPrivs:/ {print $2}' /proc/1/status)
if [ "$nnp" = "1" ]; then
    ok "no-new-privileges active"
else
    bad "no-new-privileges NOT active (NoNewPrivs=$nnp)"
fi

if [ "$(id -u)" -eq 0 ]; then
    bad "running as root"
else
    ok "running as non-root user $(id -un) (uid $(id -u))"
fi

if [ -e /var/run/docker.sock ] || [ -e /run/podman.sock ]; then
    bad "a container engine socket is mounted into the sandbox"
else
    ok "no container engine socket mounted"
fi

# --- Network isolation (hard) ---

default_routes=$(ip route show default 2>/dev/null | wc -l)
if [ "$default_routes" -eq 0 ]; then
    ok "no default route: no direct path to host, LAN, or internet"
else
    bad "default route exists: $(ip route show default)"
fi

# --- Resource limits (hard: a limit must exist; actual value is reported) ---

mem=$(cat /sys/fs/cgroup/memory.max 2>/dev/null || echo max)
if [ "$mem" = "max" ]; then
    bad "no memory limit set"
else
    ok "memory limit: $((mem/1024/1024)) MiB"
fi

pids=$(cat /sys/fs/cgroup/pids.max 2>/dev/null || echo max)
if [ "$pids" = "max" ]; then
    bad "no PID limit set"
else
    ok "PID limit: $pids"
fi

cpu=$(cat /sys/fs/cgroup/cpu.max 2>/dev/null || echo "max 100000")
cpu_quota=${cpu%% *}
cpu_period=${cpu##* }
if [ "$cpu_quota" = "max" ]; then
    bad "no CPU limit set"
else
    ok "CPU limit: $((cpu_quota / cpu_period)) core(s)"
fi

# --- Mounts (hard) ---

mnt_opts=$(awk '$2=="/home/vscode/.gitconfig" {print $4}' /proc/mounts)
case "$mnt_opts" in
    ro,*) ok "git identity mounted read-only" ;;
    *)    bad "git identity not mounted read-only (opts: '${mnt_opts:-missing}')" ;;
esac

ws_opts=$(awk -v ws="$WORKSPACE_DIR" '$2==ws {print $4}' /proc/mounts)
case "$ws_opts" in
    rw,*) ok "workspace mounted read-write at $WORKSPACE_DIR (intended)" ;;
    *)    bad "workspace mount not found at $WORKSPACE_DIR" ;;
esac

vibe_opts=$(awk '$2=="/home/vscode/.vibe" {print $1}' /proc/mounts)
if [ -n "$vibe_opts" ]; then
    ok "vibe state on a named volume (device: $vibe_opts)"
else
    warn "vibe state volume not found - state will not survive rebuilds"
fi

# --- Egress proxy (reachable with retries; its security behavior is hard) ---

proxy_up=0
for _ in $(seq 1 10); do
    if curl -s -o /dev/null --max-time 2 "http://proxy:3128/"; then
        proxy_up=1
        break
    fi
    sleep 1
done

if [ "$proxy_up" -eq 1 ]; then
    ok "egress proxy reachable on the sandbox network (proxy:3128)"

    # Explicit -x: do not depend on ambient proxy env vars (curl only
    # honors lowercase http_proxy for plain HTTP, and the check should
    # exercise the proxy path deterministically, not trust the environment).
    code=$(curl -s -x http://proxy:3128 -o /dev/null -w '%{http_code}' --max-time 10 http://host.containers.internal)
    if [ "$code" = "403" ]; then
        ok "host access denied by the proxy (HTTP 403)"
    else
        bad "proxy did not deny host access (got HTTP ${code:-none}, want 403)"
    fi

    code=$(curl -s -x http://proxy:3128 -o /dev/null -w '%{http_code}' --max-time 10 https://example.com)
    if [ "$code" = "200" ]; then
        ok "public internet reachable via the proxy"
    else
        warn "internet check returned HTTP ${code:-none} - verify egress if you expect network"
    fi
else
    warn "egress proxy not reachable - sandbox has no internet until it starts"
    warn "isolation still holds (no default route): fail-safe, not fail-open"
fi

if curl -s --noproxy '*' --max-time 3 -o /dev/null http://host.containers.internal/ 2>/dev/null; then
    bad "DIRECT access to a private address succeeded - network isolation broken"
else
    ok "direct access to private ranges blocked at the routing layer"
fi

echo "== $PASS passed, $FAIL failed, $WARN warning(s) =="

if [ "$FAIL" -gt 0 ]; then
    echo "== SECURITY CHECK FAILED - do not treat this sandbox as isolated =="
    exit 1
fi
exit 0
