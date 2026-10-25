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
# - The sandbox's own configuration (.devcontainer) must not be writable
#   (read-only shadow mount, or a read-only workspace), no competing
#   devcontainer.json may sit in the workspace
#   root, and every mount must be on the allowlist: the agent must not be
#   able to rewrite or bypass the sandbox definition.
# - Resource limits are checked for EXISTENCE, not exact values, so
#   right-sizing compose.yaml does not break this script.
# - A dead/unreachable proxy is a WARNING, not a failure: the sandbox has
#   no default route, so a missing proxy means no egress at all
#   (fail-safe), never access to the host or LAN (fail-open).
#
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

engine_sock=0
for sock in /var/run/docker.sock /run/podman.sock /run/containerd/containerd.sock /run/crio/crio.sock; do
    if [ -e "$sock" ]; then
        bad "a container engine socket is mounted into the sandbox ($sock)"
        engine_sock=1
    fi
done
if [ "$engine_sock" -eq 0 ]; then
    ok "no container engine socket mounted"
fi

# --- Network isolation (hard) ---

default_routes=$( (ip route show default; ip -6 route show default) 2>/dev/null | wc -l )
if [ "$default_routes" -eq 0 ]; then
    ok "no default route (IPv4 or IPv6): no direct path to host, LAN, or internet"
else
    bad "default route exists: ($( (ip route show default; ip -6 route show default) 2>/dev/null | tr '\n' ';' ))"
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

# The workspace may be read-write (toolkit default) or read-only (a
# per-project choice in compose.yaml: append :ro to the bind mount). Both
# are valid postures - the check accepts either and reports which, so
# right-sizing compose.yaml does not break this script.
ws_opts=$(awk -v ws="$WORKSPACE_DIR" '$2==ws {print $4}' /proc/mounts)
case "$ws_opts" in
    rw|rw,*) ok "workspace mounted read-write at $WORKSPACE_DIR" ;;
    ro|ro,*) ok "workspace mounted read-only at $WORKSPACE_DIR" ;;
    *)    bad "workspace mount not found or not a plain rw/ro bind at $WORKSPACE_DIR (opts: '${ws_opts:-missing}')" ;;
esac

vibe_opts=$(awk '$2=="/home/vscode/.vibe" {print $1}' /proc/mounts)
if [ -n "$vibe_opts" ]; then
    ok "vibe state on a named volume (device: $vibe_opts)"
else
    warn "vibe state volume not found - state will not survive rebuilds"
fi

# The sandbox's own configuration lives in the workspace: either it is
# shadow-mounted read-only, or the whole workspace is mounted read-only.
# Anything else and the agent could rewrite compose.yaml / devcontainer.json
# (add host mounts, remove this check from postStartCommand) and have the
# change applied on the next restart/rebuild.
tmpl_opts=$(awk '$2=="'"$WORKSPACE_DIR"'/.devcontainer" {print $4}' /proc/mounts)
case "$tmpl_opts" in
    ro|ro,*) ok "sandbox template (.devcontainer) mounted read-only" ;;
    rw|rw,*) bad "sandbox template (.devcontainer) mounted read-write (opts: '$tmpl_opts') - the agent could rewrite the sandbox configuration" ;;
    *)  # No shadow mount at all: safe only if the workspace is read-only.
        case "$ws_opts" in
            ro|ro,*) ok "sandbox template (.devcontainer) read-only via read-only workspace" ;;
            *)    bad "sandbox template (.devcontainer) not mounted read-only (opts: '${tmpl_opts:-missing}') - the agent could rewrite the sandbox configuration" ;;
        esac ;;
esac

# A devcontainer.json in the workspace ROOT would compete with the sandbox
# template. VS Code prefers .devcontainer/devcontainer.json, but only while
# it exists - and other tools (Codespaces, JetBrains, CLI) resolve
# differently. In a template-consumed project a root file is always wrong:
# fail on ambiguity rather than trust precedence.
rogue_found=0
for rogue in "$WORKSPACE_DIR/.devcontainer.json" "$WORKSPACE_DIR/.devcontainer.jsonc"; do
    if [ -e "$rogue" ]; then
        bad "competing devcontainer config at $rogue - delete it (the sandbox config is .devcontainer/devcontainer.json)"
        rogue_found=1
    fi
done
if [ "$rogue_found" -eq 0 ]; then
    ok "no competing devcontainer config in the workspace root"
fi

# Mount allowlist: every mount must be runtime infrastructure or one of the
# four expected mounts. A tampered compose.yaml could otherwise mount the
# host root (or a container engine socket) somewhere unnoticed - the checks
# above only assert the expected mounts exist, not that nothing else does.
# Filter out system/pseudo filesystems and podman/devcontainer
# infrastructure first; what remains must be on the allowlist.
is_expected_mount() {
    case "$1" in
        "$WORKSPACE_DIR"|"$WORKSPACE_DIR/.devcontainer"|\
/home/vscode/.gitconfig|/home/vscode/.vibe|/home/vscode/.vscode-server|\
/vscode|/etc/hosts|/etc/hostname|/etc/resolv.conf|/etc/localtime)
            return 0 ;;
        *)  return 1 ;;
    esac
}

unexpected=0
while IFS= read -r mnt; do
    [ -z "$mnt" ] && continue
    if ! is_expected_mount "$mnt"; then
        bad "unexpected mount: $mnt - a host filesystem may be exposed; verify compose.yaml against the template"
        unexpected=$((unexpected+1))
    fi
done < <(awk '
    {
        fs = $3; mnt = $2
        if (fs ~ /^(proc|sysfs|devpts|devtmpfs|tmpfs|mqueue|cgroup|cgroup2|overlay|squashfs)$/) next
        if (mnt == "/") next
        if (mnt ~ /^\/(dev|proc|sys|run)(\/|$)/) next
        print mnt
    }' /proc/mounts | sort -u)

if [ "$unexpected" -eq 0 ]; then
    ok "no unexpected mounts (allowlist: workspace, template, gitconfig, vibe volume, vscode-server volume)"
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

# Direct host access must be impossible. Probe with REAL TCP connects on
# common service ports and fail if ANY connect succeeds. A plain curl here
# would treat "reachable but nothing listening" (connection refused) as
# "blocked" and hide a porous boundary; a completed connect means a host
# service (e.g. sshd) is reachable - isolation broken.
#
# Two targets:
#   - host.containers.internal: the host as exposed by the container runtime
#   - the resolv.conf nameserver: the internal network's bridge/gateway IP.
#     The internal-only network still has an on-link gateway - on rootful
#     Linux podman that IP IS the host, so a host service bound to 0.0.0.0
#     (sshd, dev servers) would answer there. On podman machine it is only
#     the VM (nothing listens) and the probe passes.
# Unreachable ports fail instantly (no route); refused connects do not
# count as exposure (no service to talk to) - so this adds no start delay
# and no false positives in the healthy case.
probe_ips=$( { getent hosts host.containers.internal 2>/dev/null | awk '{print $1}';
               awk '/^nameserver/ {print $2}' /etc/resolv.conf; } | sort -u)
if [ -z "$probe_ips" ]; then
    warn "no host IPs to probe (host.containers.internal/nameserver unavailable) - cannot verify direct host access on this platform"
else
    PROBE_PORTS="22 80 443"
    direct_connects=0
    for ip in $probe_ips; do
        for port in $PROBE_PORTS; do
            if timeout 2 bash -c "exec 3<>/dev/tcp/${ip}/${port}" 2>/dev/null; then
                bad "direct TCP connect to ${ip}:${port} succeeded - host/gateway is reachable, network isolation broken"
                direct_connects=$((direct_connects+1))
            fi
        done
    done
    if [ "$direct_connects" -eq 0 ]; then
        ok "no direct TCP path to the host or network gateway (probed on ports $(echo $PROBE_PORTS | tr ' ' '/'))"
    fi
fi

echo "== $PASS passed, $FAIL failed, $WARN warning(s) =="

if [ "$FAIL" -gt 0 ]; then
    echo "== SECURITY CHECK FAILED - do not treat this sandbox as isolated =="
    exit 1
fi
exit 0
