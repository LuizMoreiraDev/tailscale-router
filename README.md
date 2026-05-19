# tailscale-router

[![Docker Image Version](https://img.shields.io/docker/v/luizmoreiradev/tailscale-router?sort=semver)](https://hub.docker.com/r/luizmoreiradev/tailscale-router)
[![Docker Pulls](https://img.shields.io/docker/pulls/luizmoreiradev/tailscale-router)](https://hub.docker.com/r/luizmoreiradev/tailscale-router)
[![Build](https://github.com/LuizMoreiraDev/tailscale-router/actions/workflows/docker-publish.yml/badge.svg)](https://github.com/LuizMoreiraDev/tailscale-router/actions)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

A self-contained Tailscale subnet router in a Docker container. Wraps the official `tailscale/tailscale` image with the iptables, kernel-module, and forwarding setup needed to actually route traffic from your LAN into your tailnet — and tears it all down again when the container stops.

## Why this exists

The stock `tailscale/tailscale` image starts `tailscaled` and exposes it via the `tailscale0` interface, but it does **not** install the iptables `FORWARD` and `MASQUERADE` rules that turn the host into a working subnet router. On many systems (Alpine, minimal Debian, hosts without `iptables-save` orchestration) those rules end up being added by hand to the host and never removed, which contradicts the whole point of running Tailscale in a container.

`tailscale-router` handles that automatically:

- Loads the kernel modules required for NAT / connection tracking on startup
- Enables IPv4 forwarding (if possible from inside the container)
- Waits for `tailscale0` to come up, then applies the `FORWARD` + `MASQUERADE` rules
- On `SIGTERM`/`SIGINT`/`SIGQUIT`, removes the rules and stops `tailscaled` cleanly

If you `docker rm` the container, the host's iptables go back to exactly the state they were in before.

## Quick start

```bash
docker run -d \
  --name tailscale \
  --hostname pi4-home \
  --restart unless-stopped \
  --network host \
  --privileged \
  --device /dev/net/tun:/dev/net/tun \
  -v tailscale-state:/var/lib/tailscale \
  -v /lib/modules:/lib/modules:ro \
  -e TS_HOSTNAME=pi4-home \
  -e TS_ROUTES=192.168.1.0/24 \
  -e TS_EXTRA_ARGS="--accept-routes" \
  -e TS_USERSPACE=false \
  -e ROUTER_LAN_IF=eth0 \
  -e ROUTER_LAN_SUBNET=192.168.1.0/24 \
  luizmoreiradev/tailscale-router:latest
```

Or with Compose (`docker-compose.yml` included in the repo):

```bash
docker compose up -d
docker compose logs -f
```

On first run, the logs print a URL to authenticate the node. Visit it, log into Tailscale, and the device joins your tailnet.

After authentication, **approve the advertised route** in the Tailscale admin: <https://login.tailscale.com/admin/machines> → your node → Edit route settings → tick the LAN subnet.

## Configuration

### Tailscale (handled by upstream `containerboot`)

| Env var          | Description                                                       |
|------------------|-------------------------------------------------------------------|
| `TS_HOSTNAME`    | Hostname this node registers as in the tailnet                    |
| `TS_ROUTES`      | Comma-separated CIDRs to advertise (e.g. `192.168.1.0/24`)        |
| `TS_EXTRA_ARGS`  | Extra args passed to `tailscale up` (e.g. `--accept-routes`)      |
| `TS_AUTHKEY`     | Optional pre-auth key for non-interactive login                   |
| `TS_USERSPACE`   | Set to `false` to use the kernel networking stack (recommended)   |
| `TS_STATE_DIR`   | Where node state is persisted (default `/var/lib/tailscale`)      |

See the [official Tailscale Docker docs](https://tailscale.com/kb/1282/docker) for the full list.

### Router wrapper

| Env var                 | Default              | Description                                                 |
|-------------------------|----------------------|-------------------------------------------------------------|
| `ROUTER_LAN_IF`         | `eth0`               | Host interface facing the LAN                               |
| `ROUTER_TS_IF`          | `tailscale0`         | Tailscale interface name                                    |
| `ROUTER_LAN_SUBNET`     | `192.168.1.0/24`     | CIDR to MASQUERADE when sending traffic out via Tailscale   |
| `ROUTER_TS_IF_TIMEOUT`  | `60`                 | Seconds to wait for `tailscale0` to appear                  |
| `ROUTER_KERNEL_MODULES` | (sensible default)   | Space-separated modules to `modprobe` at startup            |

## What the container does to your host

When it starts:

1. `modprobe` against the host kernel for: `tun`, `iptable_filter`, `iptable_mangle`, `iptable_nat`, `nf_conntrack`, `nf_nat`, `xt_MASQUERADE`, `xt_conntrack`, `xt_connmark`. Modules that are already loaded or built-in are skipped.
2. Writes `1` to `/proc/sys/net/ipv4/ip_forward` if possible. With `--network host` this is often read-only from inside the container — if so, the container logs a warning and you should enable forwarding on the host yourself.
3. Adds three iptables rules in the host network namespace:
   - `FORWARD -i $LAN_IF -o $TS_IF -j ACCEPT`
   - `FORWARD -i $TS_IF -o $LAN_IF -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT`
   - `nat POSTROUTING -o $TS_IF -s $LAN_SUBNET -j MASQUERADE`

When it stops (graceful signal): the three iptables rules are removed.

The loaded kernel modules and the forwarding sysctl are **not** rolled back — they're harmless to leave loaded, and other workloads (e.g. another router container) may depend on them.

## Verifying it works

```bash
docker logs tailscale                            # look for "Router ACTIVE  ✓"
docker exec tailscale tailscale status           # see peers, accepted routes
ip route show table 52                           # Tailscale's policy-routing table
iptables -L FORWARD -n -v | grep tailscale0      # FORWARD rules present
iptables -t nat -L POSTROUTING -n -v | grep tailscale0   # MASQUERADE rule present
```

From a device on the LAN that's **not** running Tailscale, with a route to the remote subnet set via this host:

```bash
# On the LAN client, point traffic for the remote subnet through this host
sudo route -n add 10.0.0.0/24 <this-host-ip>     # macOS / BSD
sudo ip route add 10.0.0.0/24 via <this-host-ip> # Linux

# Then test
nc -zv 10.0.0.50 22
```

In a production setup, that static route lives on your home router (e.g. TP-Link Omada ER-series) rather than per device.

## Troubleshooting

**`tailscale0` never appears**
Make sure `/dev/net/tun` is passed in via `--device` and that the `tun` module is available on the host (`lsmod | grep tun`). The container will `modprobe` it but a missing kernel module on the host is unrecoverable.

**`Read-only file system` writing `/proc/sys/net/ipv4/ip_forward`**
Expected with `network_mode: host`. Enable forwarding on the host once: `sysctl -w net.ipv4.ip_forward=1` and persist with `/etc/sysctl.d/`.

**Remote peers reachable from inside the container but not from LAN clients**
Check that the LAN client has a route to the remote subnet via this host, that `FORWARD` rules are in place (`iptables -L FORWARD -n -v | grep tailscale0`), and that the remote side's subnet router has a return path for your `LAN_SUBNET` (or, as this container does, you MASQUERADE so the remote side sees this host's Tailscale IP instead).

**Container restarts when `tailscaled` dies**
By design — the entrypoint exits when `tailscaled` does, so Docker can restart it. Rules are removed cleanly on the way out.

## Building locally

```bash
docker buildx build \
  --platform linux/arm64,linux/amd64,linux/arm/v7 \
  --build-arg VERSION="$(git describe --tags --always)" \
  --build-arg BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --build-arg VCS_REF="$(git rev-parse --short HEAD)" \
  -t luizmoreiradev/tailscale-router:latest \
  --push .
```

Tagged releases are built and pushed by the GitHub Actions workflow in `.github/workflows/docker-publish.yml`.

## License

MIT — see [LICENSE](LICENSE).
