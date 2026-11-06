#!/usr/bin/env bash
# Verify the exit-node stack. Usage: scripts/verify.sh [wireguard|openvpn]
set -u

STACK="${1:-wireguard}"
case "$STACK" in
  wireguard|openvpn) ;;
  *) echo "Usage: $0 [wireguard|openvpn]" >&2; exit 2 ;;
esac

GLUETUN="$STACK"
TS="tailscale-$STACK"
ROUTEFIX="$TS-route-fix"
FAILED=0

# check STATUS MESSAGE
check() {
  printf '%-4s %s\n' "$1" "$2"
  [ "$1" = FAIL ] && FAILED=1
}

running() { [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = true ]; }

# 1. Containers running
for c in "$GLUETUN" "$TS"; do
  if running "$c"; then check PASS "container $c is running"
  else check FAIL "container $c is not running"; fi
done

# 2. Egress IP
info=$(docker exec "$GLUETUN" wget -qO- https://ipinfo.io/json 2>/dev/null)
if [ -z "$info" ]; then
  check FAIL "egress request from $GLUETUN failed"
else
  field() { printf '%s' "$info" | grep -o "\"$1\": *\"[^\"]*\"" | head -1 | sed 's/.*: *"\(.*\)"/\1/'; }
  cip=$(field ip)
  echo "     ip=$cip country=$(field country) org=$(field org)"
  hip=$(curl -s https://ipinfo.io/ip)
  if [ -n "$hip" ] && [ "$hip" = "$cip" ]; then
    check FAIL "container IP equals host IP ($hip): tunnel not in use"
  else
    check PASS "egress IP $cip differs from host IP ${hip:-unknown}"
  fi
fi

# 3. Tailscale state
ts_json=$(docker exec "$TS" tailscale status --json 2>/dev/null)
if printf '%s' "$ts_json" | grep -q '"BackendState": "Running"'; then
  check PASS "tailscale BackendState is Running"
else
  check FAIL "tailscale BackendState is not Running"
fi
if printf '%s' "$ts_json" | grep -q '"ExitNodeOption": true'; then
  check PASS "node advertises ExitNodeOption"
else
  check WARN "ExitNodeOption not true (approve exit node in admin console?)"
fi

# 4. Return route
route=$(docker exec "$TS" ip route get 100.64.0.1 2>&1)
if printf '%s' "$route" | grep -q 'dev tailscale0'; then
  check PASS "return route to 100.64.0.1 uses tailscale0"
elif printf '%s' "$route" | grep -q 'dev tun0'; then
  check FAIL "return route to 100.64.0.1 goes via tun0"
else
  check FAIL "unexpected route result: $route"
fi

# 5. Firewall backend
if ! docker exec "$TS" sh -c 'command -v iptables-nft' >/dev/null 2>&1; then
  check WARN "iptables-nft not found in $TS"
elif docker exec "$TS" iptables-nft -S FORWARD 2>/dev/null | grep -q ts-forward; then
  check PASS "ts-forward chain present in FORWARD"
else
  check FAIL "iptables-nft present but no ts-forward chain"
fi

# 6. Route-fix container
if running "$ROUTEFIX"; then check PASS "container $ROUTEFIX is running"
else check FAIL "container $ROUTEFIX is not running"; fi

exit "$FAILED"
