#!/bin/sh
#
# tailscale-router entrypoint wrapper.
#
# Wraps the official Tailscale containerboot with three additions:
#   1. Ensures required kernel modules are loaded on the host
#   2. Ensures IPv4 forwarding is enabled
#   3. Installs iptables FORWARD + MASQUERADE rules when tailscale0 is up,
#      and removes them on graceful shutdown.
#
set -eu

log() { printf '[%s] [router] %s\n' "$(date -Iseconds)" "$*"; }

LAN_IF="${ROUTER_LAN_IF:-eth0}"
TS_IF="${ROUTER_TS_IF:-tailscale0}"
LAN_SUBNET="${ROUTER_LAN_SUBNET:-192.168.1.0/24}"
TS_IF_TIMEOUT="${ROUTER_TS_IF_TIMEOUT:-60}"

# Kernel modules required for iptables NAT/MASQUERADE/conntrack + TUN device.
# Loaded against the host kernel because we mount /lib/modules from the host.
KERNEL_MODULES="${ROUTER_KERNEL_MODULES:-tun iptable_filter iptable_mangle iptable_nat nf_conntrack nf_nat xt_MASQUERADE xt_conntrack xt_connmark}"

ensure_modules() {
    log "Ensuring kernel modules are loaded..."
    for mod in $KERNEL_MODULES; do
        if lsmod 2>/dev/null | awk '{print $1}' | grep -qx "$mod"; then
            continue
        fi
        if modprobe "$mod" 2>/dev/null; then
            log "  loaded: $mod"
        else
            log "  WARNING: failed to load $mod (may already be built-in or unavailable)"
        fi
    done
}

ensure_forwarding() {
    for proto in ipv4 ipv6; do
        case "$proto" in
            ipv4) path="/proc/sys/net/ipv4/ip_forward" ;;
            ipv6) path="/proc/sys/net/ipv6/conf/all/forwarding" ;;
        esac
        if [ "$(cat "$path" 2>/dev/null || echo 0)" = "1" ]; then
            log "$proto forwarding already enabled on host"
            continue
        fi
        if echo 1 > "$path" 2>/dev/null; then
            log "$proto forwarding enabled"
        else
            log "WARNING: could not enable $proto forwarding from inside the container."
        fi
    done
}

wait_for_iface() {
    iface="$1"
    timeout="$2"
    i=0
    while [ "$i" -lt "$timeout" ]; do
        if ip link show "$iface" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
        i=$((i + 1))
    done
    return 1
}

TS_PID=""
RULES_APPLIED=0

cleanup() {
    log "Shutdown signal received."
    if [ "$RULES_APPLIED" = "1" ]; then
        log "Removing iptables rules..."
        /usr/local/bin/router-rules.sh remove "$LAN_IF" "$TS_IF" "$LAN_SUBNET" || true
    fi
    if [ -n "$TS_PID" ]; then
        log "Stopping tailscaled (pid=$TS_PID)..."
        kill -TERM "$TS_PID" 2>/dev/null || true
        wait "$TS_PID" 2>/dev/null || true
    fi
    log "Bye."
    exit 0
}
trap cleanup TERM INT QUIT

log "tailscale-router starting"
log "  LAN_IF=$LAN_IF  TS_IF=$TS_IF  LAN_SUBNET=$LAN_SUBNET"

ensure_modules
ensure_forwarding

log "Launching Tailscale containerboot in the background..."
/usr/local/bin/containerboot &
TS_PID=$!
log "tailscaled started (pid=$TS_PID)"

log "Waiting for $TS_IF to come up (timeout ${TS_IF_TIMEOUT}s)..."
if ! wait_for_iface "$TS_IF" "$TS_IF_TIMEOUT"; then
    log "ERROR: $TS_IF did not appear within ${TS_IF_TIMEOUT}s"
    cleanup
fi
log "$TS_IF is up"

log "Applying router iptables rules..."
/usr/local/bin/router-rules.sh add "$LAN_IF" "$TS_IF" "$LAN_SUBNET"
RULES_APPLIED=1
log "Router ACTIVE  ✓   ($LAN_IF <-> $TS_IF, masquerading $LAN_SUBNET)"

# Stay alive while tailscale0 exists; exit (and trigger cleanup) when it disappears.
# We don't wait on TS_PID because containerboot may exec or daemonize, making the
# original PID disappear even though tailscaled is still running.
log "Watchdog: monitoring $TS_IF presence..."
while ip link show "$TS_IF" >/dev/null 2>&1; do
    sleep 10
done
log "$TS_IF disappeared, shutting down"
cleanup
