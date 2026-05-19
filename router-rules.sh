#!/bin/sh
#
# Adds or removes iptables rules that turn this host into a subnet router
# for traffic between $LAN_IF and $TS_IF (the Tailscale interface).
#
# Idempotent — safe to call multiple times; "add" checks for existing rules
# before inserting, "remove" silently skips missing rules.
#
set -eu

ACTION="${1:-}"
LAN_IF="${2:?LAN interface required}"
TS_IF="${3:?Tailscale interface required}"
LAN_SUBNET="${4:?LAN subnet required}"

apply_filter() {
    iptables -C "$@" 2>/dev/null || iptables -I "$@"
}
remove_filter() {
    while iptables -C "$@" 2>/dev/null; do
        iptables -D "$@" || break
    done
}

apply_nat() {
    iptables -t nat -C "$@" 2>/dev/null || iptables -t nat -A "$@"
}
remove_nat() {
    while iptables -t nat -C "$@" 2>/dev/null; do
        iptables -t nat -D "$@" || break
    done
}

case "$ACTION" in
    add)
        # Forwarding LAN -> Tailscale
        apply_filter FORWARD -i "$LAN_IF" -o "$TS_IF" -j ACCEPT
        # Return traffic Tailscale -> LAN
        apply_filter FORWARD -i "$TS_IF" -o "$LAN_IF" \
            -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
        # MASQUERADE traffic from LAN subnet going out via Tailscale, so the
        # remote side sees this host's Tailscale IP as the source.
        apply_nat POSTROUTING -o "$TS_IF" -s "$LAN_SUBNET" -j MASQUERADE
        ;;
    remove)
        remove_filter FORWARD -i "$LAN_IF" -o "$TS_IF" -j ACCEPT
        remove_filter FORWARD -i "$TS_IF" -o "$LAN_IF" \
            -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
        remove_nat POSTROUTING -o "$TS_IF" -s "$LAN_SUBNET" -j MASQUERADE
        ;;
    *)
        echo "Usage: $0 {add|remove} <lan_if> <ts_if> <lan_subnet>" >&2
        exit 1
        ;;
esac
