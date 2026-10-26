#!/usr/bin/env bash
#
# 00-verify-kernel.sh — check that this machine can run the demo, before installing anything.
# It stops only if BTF is missing or Docker does not work without sudo; everything else is a
# warning.

set -euo pipefail

# Load demo.env, which also confirms it exists.
# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

# Recommended minimums.
MIN_RAM_GIB=16
MIN_CORES=4
MIN_DISK_GIB=40   # free space where Docker stores images

WARN=0

log()  { printf '%s\n' "$*"; }
ok()   { printf 'OK    %s\n' "$*"; }
warn() { printf 'WARN  %s\n' "$*"; WARN=$((WARN + 1)); }
die()  { printf 'STOP  %s\n' "$*" >&2; exit 1; }

log "=== Machine check (00-verify-kernel.sh) ==="
log "Kernel: $(uname -sr)   Arch: $(uname -m)"
log "----------------------------------------"

# --- Check 1: BTF (stops if missing) ---------------------------------------------
log "[1/5] BTF for Falco's modern eBPF probe"
if [ -r /sys/kernel/btf/vmlinux ]; then
  ok "BTF present: /sys/kernel/btf/vmlinux ($(stat -c '%s bytes' /sys/kernel/btf/vmlinux))"
else
  die "BTF missing (/sys/kernel/btf/vmlinux not found/readable). Falco's modern eBPF probe
       requires it; on driver 'auto' Falco would fall back to the kernel-module driver (slow,
       brittle), and controls/falco/install.sh pins modern_ebpf so the Falco install would fail. Use a kernel built with CONFIG_DEBUG_INFO_BTF
       before proceeding. Not proceeding to tool install."
fi

# --- Check 2: Docker works without sudo (stops if not) ----------------------------
log "[2/5] Docker usable without sudo"
if ! command -v docker >/dev/null 2>&1; then
  die "docker CLI not found on PATH. Install Docker Engine and add this user to the 'docker'
       group (newgrp docker / re-login), then re-run."
fi
# If this fails, your user cannot reach Docker without sudo.
if server_ver="$(docker version --format '{{.Server.Version}}' 2>/dev/null)" && [ -n "$server_ver" ]; then
  ok "docker daemon reachable as $(id -un) without sudo (server ${server_ver})"
else
  die "cannot reach the Docker daemon as $(id -un) without sudo. Add this user to the
       'docker' group and re-login (id shows: $(id -Gn)). Running the demo under sudo is
       not supported (password prompts mid-run)."
fi
# Run a real container with the demo's pinned busybox image.
if docker run --rm "$SHELLTEST_IMAGE" true >/dev/null 2>&1; then
  ok "docker run ${SHELLTEST_IMAGE%%@*} succeeded (container execution works)"
else
  die "docker run ${SHELLTEST_IMAGE%%@*} failed. The daemon answered but could not run a container
       (storage/network/pull issue). Resolve before installing kind-dependent tooling."
fi

# --- Check 3: resources (warning only) -----------------------------------------------
log "[3/5] Resource headroom (recommended floors, not hard limits)"
ram_gib=$(awk '/MemTotal/ {printf "%d", $2/1024/1024}' /proc/meminfo)
if [ "$ram_gib" -ge "$MIN_RAM_GIB" ]; then
  ok "RAM ${ram_gib} GiB (>= ${MIN_RAM_GIB} GiB recommended)"
else
  warn "RAM ${ram_gib} GiB is below the ${MIN_RAM_GIB} GiB recommended for the full stack"
fi
cores=$(nproc)
if [ "$cores" -ge "$MIN_CORES" ]; then
  ok "CPU ${cores} vCPU (>= ${MIN_CORES} recommended)"
else
  warn "CPU ${cores} vCPU is below the ${MIN_CORES} recommended"
fi
# Free space where Docker stores its data.
docker_root="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo /var/lib/docker)"
disk_gib=$(df -BG --output=avail "$docker_root" 2>/dev/null | awk 'NR==2 {gsub("G",""); print $1}')
if [ -n "${disk_gib:-}" ] && [ "$disk_gib" -ge "$MIN_DISK_GIB" ]; then
  ok "Disk ${disk_gib} GiB free on ${docker_root} (>= ${MIN_DISK_GIB} GiB recommended)"
else
  warn "Only ${disk_gib:-?} GiB free on ${docker_root} (< ${MIN_DISK_GIB} GiB); pre-pulling
        images may fill the disk"
fi

# --- Check 4: nested virtualization (warning only) ----------------------------------
log "[4/5] Nested virtualization (informational — not required for kind + eBPF)"
if grep -qE '(^|[[:space:]])(vmx|svm)([[:space:]]|$)' /proc/cpuinfo; then
  ok "VT extensions present (vmx/svm) — nested virt available (not needed, nice to have)"
else
  warn "No vmx/svm flags: nested virtualization unavailable. This is FINE —
        kind runs containers (not nested VMs) and eBPF needs only the kernel + BTF above."
fi

# --- Check 5: cgroup v2, which kind expects on current kernels -----------------------
log "[5/5] cgroup v2 (kind reliability on modern kernels)"
if [ -f /sys/fs/cgroup/cgroup.controllers ]; then
  ok "unified cgroup v2 hierarchy present"
else
  warn "cgroup v2 unified hierarchy not detected; kind may need extra configuration"
fi

log "----------------------------------------"
if [ "$WARN" -eq 0 ]; then
  log "PASS — machine baseline verified, no warnings. Safe to run 01-install-tools.sh."
else
  log "PASS (with ${WARN} warning(s)) — BTF + Docker are good, so the demo can proceed."
  log "Review the WARN lines above; none is a hard blocker."
fi
exit 0
