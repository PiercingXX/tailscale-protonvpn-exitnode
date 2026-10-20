# tailscale-protonvpn-exitnode

Docker Compose stacks that turn a container into a **Tailscale exit node whose
traffic leaves through ProtonVPN**. Anything on your tailnet — laptop, phone,
another server — can select this node and have its traffic egress from the
ProtonVPN country you picked, without installing a VPN client on the device.

Gluetun holds the ProtonVPN tunnel; the Tailscale container shares gluetun's
network namespace, so every packet Tailscale forwards is already inside the
VPN. If the tunnel drops, gluetun's killswitch drops the traffic with it.

A third, tiny container (`tailscale-route-fix`) keeps one route in place.
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
| `*/.env.example` | Template for your credentials. Copy to `.env`. |

The two stacks are independent and use separate Docker volumes, so you can run
both at once as two distinct exit nodes.

## 💡 Use Cases

- Remote development over Tailscale with ProtonVPN routing.
- Building self-hosted solutions with reliable encrypted traffic.
- Bypassing geo-restrictions while maintaining full privacy.

## 🚀 Installation

### 🧰 Prerequisites

- Docker Engine and the Compose plugin v2.17 or newer (or Portainer)
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

Before downloading, turn on **Moderate NAT** (paid plans). tailscaled sits
behind ProtonVPN's NAT, and under Proton's default strict NAT Tailscale often
can't establish direct connections, so traffic is relayed through Tailscale's
DERP servers instead, which is slower. **VPN Accelerator** is chosen here too,
if you want it. Both options belong to the key, so gluetun has no setting for
them — to change them, generate a new config.

*OpenVPN:* go to **Account** → **OpenVPN / IKEv2 username** and copy that
username and password. These are **not** your ProtonVPN account login. On a
paid plan, append `+nr` to the username (e.g. `abc123+nr`) to get Moderate NAT,
for the same reason.

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

If your policy restricts access (anything other than the default allow-all
rule), the people who will use the exit node also need access to
`autogroup:internet`:

```jsonc
"grants": [
  { "src": ["autogroup:member"], "dst": ["autogroup:internet"], "ip": ["*"] },
],
```

With legacy `acls`, the equivalent is
`{ "action": "accept", "src": ["autogroup:member"], "dst": ["autogroup:internet:*"] }`.

### 🌐 Step 3: Create a Tailscale auth key

Do this *after* Step 2 — `tag:vpn` has to exist before it can be selected.

Go to <https://login.tailscale.com/admin/settings/keys>, select **Generate auth
key**, and under **Tags** choose `tag:vpn`. Leave **Ephemeral** off, or the node
is deleted every time it goes offline. If your tailnet requires device
approval, also turn on **Pre-approved**. The key is shown once; copy it now.

An OAuth client secret from the
[trust credentials](https://login.tailscale.com/admin/settings/trust-credentials)
page works too, if you prefer one that doesn't expire — it needs the
`auth_keys` scope and the same tag. Append `?ephemeral=false&preauthorized=true`
to it: when an OAuth secret is used as an auth key, Tailscale defaults to an
ephemeral node that still needs device approval.

```
TS_AUTHKEY=tskey-client-xxxxx?ephemeral=false&preauthorized=true
```

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
# Run these from the stack directory. On the OpenVPN stack, use the
# service names openvpn and tailscale-openvpn instead.

# 1. Traffic is leaving through ProtonVPN — expect an IP in your chosen country.
docker compose exec wireguard wget -qO- https://ipinfo.io/json

# 2. Tailscale is up and advertising.
docker compose exec tailscale-wireguard tailscale status
```

Then, from another device on your tailnet, select the node as your exit node
and confirm your public IP matches the one above. `tailscale ping <TS_HOSTNAME>`
from that device shows whether the connection is direct or relayed through
DERP (see Moderate NAT in Step 1).

## 🩺 Troubleshooting

| Symptom | Cause |
| --- | --- |
| Node appears in the console but no traffic flows through it | `TS_USERSPACE=false` missing, or IP forwarding sysctls not applied. Both are set in the shipped compose files — check you didn't remove them. |
| Client selects the exit node, pages never load, DNS may still work | Either `TS_DEBUG_FIREWALL_MODE=nftables` is missing or the `tailscale-route-fix` container isn't running. See [below](#why-the-third-container-exists). |
| Traffic goes out but nothing comes back | The tailnet return route is missing. Check `docker compose exec tailscale-wireguard ip route get <client-tailscale-ip>` — it must say `dev tailscale0`, not `dev tun0`. `docker compose logs tailscale-route-fix` shows each time the route had to be restored. |
| Some users can't use the exit node | Your policy doesn't give them access to `autogroup:internet`. See Step 2. |
| Exit node works but is slow or high-latency | Tailscale is relaying through DERP. Run `tailscale ping <TS_HOSTNAME>` from the client — `via DERP(...)` means relayed. Turn on Moderate NAT (Step 1). |
| Everything stopped working after gluetun crashed and Docker restarted it | The other two containers are still attached to gluetun's old network namespace. Run `docker compose restart`. |
| `requested tags [tag:vpn] are invalid or not permitted` | `tag:vpn` isn't in your ACL, or the credential doesn't own it. See Step 2. |
| Container exits with `sysctl ... not found` or permission denied | IPv6 is disabled in the host kernel (e.g. booted with `ipv6.disable=1`). Remove the `net.ipv6.conf.all.forwarding` line. |
| WireGuard handshake never completes | A stale `WIREGUARD_PUBLIC_KEY`/`WIREGUARD_ADDRESSES` is set. Remove them and let gluetun choose. |
| Gluetun never becomes healthy | Wrong credentials, or `SERVER_COUNTRIES` doesn't match a real country name. Check `docker compose logs wireguard`. |
| Node re-registers as a new machine on every restart | The state volume (`tsstate` / `tsovstate`) was removed — `TS_STATE_DIR` must persist — or the node is ephemeral, e.g. an OAuth secret without `?ephemeral=false`. See Step 3. |

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

Because these containers share a network namespace, the other two lose
networking whenever gluetun's container restarts. `restart: true` on their
`depends_on` makes Compose restart them along with gluetun for anything Compose
does itself — `docker compose restart wireguard`, or recreating gluetun after a
`pull`. Compose can't see restarts Docker makes on its own after a crash; if
that happens, run `docker compose restart`.

## 🔄 Updating

Images are pinned to a minor series (`gluetun:v3.41`, `tailscale:v1.104`) so you
get patch fixes without surprise major upgrades:

```bash
docker compose pull && docker compose up -d
```

This also refreshes gluetun's ProtonVPN server list, which ships inside the
image. Gluetun's periodic updater is left off because for ProtonVPN it needs
your Proton account email and password (`UPDATER_PROTONVPN_EMAIL` /
`UPDATER_PROTONVPN_PASSWORD`); set those and `UPDATER_PERIOD` yourself if you
want it.

Bump the tags in `compose.yaml` when you want a new minor version.

## 📜 License

[GPL-3.0](LICENSE).
