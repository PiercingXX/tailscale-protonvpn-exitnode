# tailscale-protonvpn-exitnode

Docker Compose stacks that turn a container into a **Tailscale exit node whose
traffic leaves through ProtonVPN**. Anything on your tailnet — laptop, phone,
another server — can select this node and have its traffic egress from the
ProtonVPN country you picked, without installing a VPN client on the device.

Gluetun holds the ProtonVPN tunnel; the Tailscale container shares gluetun's
network namespace, so every packet Tailscale forwards is already inside the
VPN. If the tunnel drops, gluetun's killswitch drops the traffic with it.

A third, tiny container (`tailscale-route-fix`, script in `common/route-fix.sh`) keeps one route in place.
Gluetun and Tailscale each manage the namespace's routing and firewall without
knowing about each other, and two of their defaults collide in ways that
silently break exit-node forwarding — see
[Why the third container exists](#why-the-third-container-exists).

## 🔧 Features

- 🔐 Secure outbound traffic via ProtonVPN (WireGuard or OpenVPN).
- 📦 Fully containerized setup using Docker Compose or Portainer.
- 🧩 Suitable for cloud instances, home labs, or headless environments.
- ⚙️ Easily customizable and extensible for other VPN providers (with some modifications).
- 🛡️ Ideal for privacy-conscious developers and DevOps professionals.

## 📁 Contents

| Path | Description |
| --- | --- |
| `wireguard/` | ProtonVPN over **WireGuard**. Faster, fewer moving parts — **start here**. |
| `openvpn/` | ProtonVPN over **OpenVPN**. Use when WireGuard/UDP is blocked on your network. |
| `*/compose.yaml` | Gluetun + Tailscale + route-fix service definitions. |
| `common/route-fix.sh` | The route-fix logic, shared by both stacks. |
| `scripts/verify.sh` | Post-install health check. |
| `*/.env.example` | Template for your credentials. Copy to `.env`. |

The two stacks are independent and use separate Docker volumes, so you can run
both at once as two distinct exit nodes.

## 💡 Use Cases

- Remote development over Tailscale with ProtonVPN routing.
- Building self-hosted solutions with reliable encrypted traffic.
- Bypassing geo-restrictions while maintaining full privacy.

## 🚀 Installation

### 🧰 Prerequisites

- Docker Engine and the Compose plugin (or Portainer)
- A Linux host with `/dev/net/tun` available
- Active accounts for ProtonVPN and Tailscale

### 🔑 Step 1: Prepare ProtonVPN credentials

*WireGuard:* go to the ProtonVPN dashboard → **Downloads** → **WireGuard
configuration**, pick a server, and download it. You only need the
`PrivateKey` line — gluetun resolves the server address and public key from
its own server list.

> Do not copy the `PublicKey` or `Address` from that file into the compose
> file. Pinning them breaks the handshake as soon as gluetun rotates to
> another server in the country you selected.

*OpenVPN:* go to **Account** → **OpenVPN / IKEv2 username** and copy that
username and password. These are **not** your ProtonVPN account login.

### 🏷️ Step 2: Add the tag to your ACL

The stacks authenticate with `--advertise-tags=tag:vpn`. Tagged credentials
require that tag to already exist in your tailnet policy file, otherwise
`tailscale up` fails with a tag ownership error.

Open the [access controls editor](https://login.tailscale.com/admin/acls) and
add:

```jsonc
{
  "tagOwners": {
    "tag:vpn": ["autogroup:admin"],
  },
  "autoApprovers": {
    // Approves the exit node automatically, so you can skip Step 6.
    "exitNode": ["tag:vpn"],
  },
}
```

### 🌐 Step 3: Create a Tailscale auth key

Do this *after* Step 2 — `tag:vpn` has to exist before it can be selected.

Go to <https://login.tailscale.com/admin/settings/keys>, select **Generate auth
key**, and under **Tags** choose `tag:vpn`. Leave **Ephemeral** off, or the node
is deleted every time it goes offline. The key is shown once; copy it now.

An OAuth client secret from the
[trust credentials](https://login.tailscale.com/admin/settings/trust-credentials)
page works too, if you prefer one that doesn't expire — it needs the
`auth_keys` scope and the same tag.

### ⚙️ Step 4: Configure

```bash
git clone https://github.com/PiercingXX/tailscale-protonvpn-exitnode.git
cd tailscale-protonvpn-exitnode/wireguard   # or openvpn/

cp .env.example .env
$EDITOR .env
```

`.env` is gitignored. Keep your keys there — not in `compose.yaml`.

### ▶️ Step 5: Start the services

```bash
docker compose up -d
docker compose logs -f
```

Tailscale waits for gluetun to report healthy before it starts, so the first
boot takes a few extra seconds.

### 🌍 Step 6: Activate the exit node

If you added the `autoApprovers` block in Step 2, this already happened —
skip ahead to verification.

Otherwise go to <https://login.tailscale.com/admin/machines>, open the machine
matching your `TS_HOSTNAME`, find **Exit Node** under Routing Settings, click
**Edit**, enable **Use as exit node**, and save.

## ✅ Verify it works

```bash
# 1. Traffic is leaving through ProtonVPN — expect an IP in your chosen country.
docker exec wireguard wget -qO- https://ipinfo.io/json

# 2. Tailscale is up and advertising.
docker exec tailscale-wireguard tailscale status
```

For the OpenVPN stack, the container names are `openvpn` and `tailscale-openvpn`.

Or run every check at once (egress IP, Tailscale state, return route, firewall
backend, route-fix container):

```bash
scripts/verify.sh wireguard   # or: openvpn
```

Then, from another device on your tailnet, select the node as your exit node
and confirm your public IP matches the one above.

## ⚠️ Known limitation, and the optional bypass

Because Tailscale shares gluetun's network namespace, all of Tailscale's own
traffic (control plane, DERP, and direct peer WireGuard UDP) is also sent through
the ProtonVPN tunnel. Consequences:

- Extra latency.
- Double-tunnel MTU pressure.
- Direct peer connections usually can't be established, so traffic falls back to
  DERP relays.

By default this is deliberate: it keeps the killswitch complete and never
exposes the host's real IP.

**Experimental opt-in:** set `TS_BYPASS_VPN=on` in `.env` and run
`docker compose up -d`. `tailscaled` marks its own packets (fwmark `0x80000`);
the route-fix container then routes only those out the Docker bridge instead of
the tunnel. Traffic forwarded for exit-node clients is not marked and still
leaves through ProtonVPN.

> **Cost:** Tailscale and its peers will see this host's real IP, and the
> killswitch no longer covers `tailscaled`'s own traffic. IPv4 only. This has
> not been tested against every gluetun release; if `docker logs
> <stack>-route-fix` shows `bypass: ... skipping`, no change was made. Tracked
> in [issue #2](https://github.com/PiercingXX/tailscale-protonvpn-exitnode/issues/2).

## 🩺 Troubleshooting

| Symptom | Cause |
| --- | --- |
| Node appears in the console but no traffic flows through it | `TS_USERSPACE=false` missing, or IP forwarding sysctls not applied. Both are set in the shipped compose files — check you didn't remove them. |
| Client selects the exit node, pages never load, DNS may still work | Either `TS_DEBUG_FIREWALL_MODE=nftables` is missing or the `tailscale-route-fix` container isn't running. See [below](#why-the-third-container-exists). |
| Traffic goes out but nothing comes back | The tailnet return route is missing. Check `docker exec tailscale-wireguard ip route get <client-tailscale-ip>` — it must say `dev tailscale0`, not `dev tun0`. |
| `requested tags [tag:vpn] are invalid or not permitted` | `tag:vpn` isn't in your ACL, or the credential doesn't own it. See Step 2. |
| Container exits with `sysctl ... not found` or permission denied | Your Docker daemon runs with IPv6 disabled. Remove the `net.ipv6.conf.all.forwarding` line. |
| WireGuard handshake never completes | A stale `WIREGUARD_PUBLIC_KEY`/`WIREGUARD_ADDRESSES` is set. Remove them and let gluetun choose. |
| Gluetun never becomes healthy | Wrong credentials, or `SERVER_COUNTRIES` doesn't match a real country name. Check `docker compose logs wireguard`. |
| Node re-registers as a new machine on every restart | The `tsstate` volume was removed. `TS_STATE_DIR` must persist. |

## 🧠 Why the third container exists

Gluetun and Tailscale both manage netfilter and routing inside the shared
namespace, independently. Two of their defaults collide, and both failures look
identical from the admin console: the node registers, advertises itself, and
reports healthy while carrying nothing.

**1. They write firewall rules to different backends.** Gluetun uses
iptables-**nft**, where the `FORWARD` policy is `DROP`. `tailscaled` defaults to
iptables-**legacy**, so its `ts-forward … ACCEPT` rules land in a table
gluetun's policy never consults. Both backends hook the same netfilter chain and
a `DROP` in either wins, so every forwarded packet is discarded.
`TS_DEBUG_FIREWALL_MODE=nftables` puts them in the same backend.

**2. Gluetun's routing rule outranks Tailscale's.** Gluetun installs an ip rule
at priority ~101 pointing at a table containing only `default dev tun0`.
Tailscale's peer routes live in table 52 at priority 5270. Anything addressed to
`100.64.0.0/10` matches gluetun's rule first, so replies to tailnet clients get
pushed *into* the ProtonVPN tunnel instead of back out `tailscale0`. Outbound
traffic works; nothing returns.

The fix is a more-specific route for the CGNAT range. It needs a loop rather
than a one-shot because gluetun rebuilds its routing table on every reconnect,
which silently reverts it.

Problem 1 affects **both** stacks. Problem 2 affects only **WireGuard**:
gluetun's OpenVPN mode redirects traffic with the conventional
`0.0.0.0/1` + `128.0.0.0/1` pair and installs no competing ip rule, so
Tailscale's table 52 is consulted first and the return path is already correct.
The route-fix container detects this and does nothing there — it is kept in both
stacks as a safety net, since it is a no-op wherever the collision is absent.

> Gluetun's `FIREWALL_OUTBOUND_SUBNETS=100.64.0.0/10` does **not** solve this.
> It routes the range via the Docker bridge (`dev eth0`), which is a different
> wrong answer.

Because these containers share a network namespace, restarting gluetun alone
tears down networking for the others. Restart the whole stack
(`docker compose restart`) rather than an individual service.

## 🔄 Updating

Images are pinned to a minor series (`gluetun:v3.41`, `tailscale:v1.98`) so you
get patch fixes without surprise major upgrades:

```bash
docker compose pull && docker compose up -d
```

Bump the tags in `compose.yaml` when you want a new minor version.

## 📜 License

[GPL-3.0](LICENSE).
