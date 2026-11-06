#!/bin/sh
# Shared by the wireguard and openvpn stacks. Runs inside gluetun's network
# namespace (network_mode: service:<gluetun>) and keeps routing correct.
#
# 1. Return route (always on)
#    Gluetun's WireGuard mode installs an ip rule whose table only contains
#    "default dev tun0". It outranks tailscale's rule (priority 5270), so
#    replies to tailnet clients are pushed into the VPN instead of out
#    tailscale0. A more-specific route for the tailnet CGNAT range fixes it.
#    Gluetun rebuilds its routes on every reconnect, hence the loop. The table
#    is detected rather than hardcoded because WireGuard and OpenVPN differ.
#
# 2. Optional VPN bypass for tailscaled's own traffic (TS_BYPASS_VPN=on)
#    EXPERIMENTAL. Off by default. tailscaled marks the packets it originates
#    (control plane, DERP, direct peer UDP) with fwmark 0x80000. When enabled,
#    those packets are routed out the Docker bridge instead of the tunnel, so
#    direct peer connections work and DERP/control latency drops. Traffic that
#    tailscale *forwards* for exit-node clients is not marked and still goes
#    through the VPN.
#    Cost: Tailscale and its peers see this host's real IP, and the killswitch
#    no longer covers tailscaled's own traffic. IPv4 only.

BYPASS="${TS_BYPASS_VPN:-off}"
MARK="0x80000/0xff0000"
TABLE=200
PRIO=90
INTERVAL=20

# Use the same netfilter backend as gluetun (nft), falling back if absent.
IPT=$(command -v iptables-nft || command -v iptables)

log() { echo "route-fix: $*"; }

fix_return_route() {
  ip link show tailscale0 >/dev/null 2>&1 || return 0
  # shellcheck disable=SC2046  # word splitting of the table list is intended
  for t in main $(ip rule show | sed -n 's/.*lookup \([0-9][0-9]*\).*/\1/p' | sort -u); do
    if ip route show table "$t" 2>/dev/null | grep -q '^default .*dev tun0'; then
      ip route replace 100.64.0.0/10 dev tailscale0 table "$t" 2>/dev/null
    fi
  done
}

ensure_rule() { # args: iptables chain + rule spec; inserts only if missing
  "$IPT" -C "$@" 2>/dev/null || "$IPT" -I "$@"
}

fix_bypass() {
  gw=$(ip -4 route show table main | awk '/^default .*dev eth0/ {print $3; exit}')
  if [ -z "$gw" ]; then
    log "bypass: no default route via eth0 in main table, skipping"
    return 0
  fi

  ip route replace default via "$gw" dev eth0 table "$TABLE" 2>/dev/null
  ip rule show | grep -q "fwmark $MARK.*lookup $TABLE" ||
    ip rule add fwmark "$MARK" lookup "$TABLE" priority "$PRIO"

  # Gluetun's killswitch drops everything leaving eth0 except its own VPN
  # endpoint. Allow tailscaled's marked packets and their replies.
  ensure_rule OUTPUT -o eth0 -m mark --mark "$MARK" -j ACCEPT
  ensure_rule INPUT -i eth0 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
}

log "starting (bypass=$BYPASS)"
while :; do
  fix_return_route
  [ "$BYPASS" = "on" ] && ip link show tailscale0 >/dev/null 2>&1 && fix_bypass
  sleep "$INTERVAL"
done
