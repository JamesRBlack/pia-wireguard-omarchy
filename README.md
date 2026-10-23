# PIA WireGuard for Omarchy and Linux

PIA (Private Internet Access) over WireGuard on Linux with NetworkManager and
systemd: a fresh key on every connect, a killswitch that holds from boot, a
watchdog that reconnects, and a one-command toggle. Includes a bar widget for
Omarchy and a waybar module for everyone else.

Written for Arch / Omarchy (Hyprland, ufw, Docker, libvirt all fine alongside
it); any distribution with NetworkManager, systemd 250+ and nftables should
work.

Unofficial: not affiliated with or endorsed by Private Internet Access. You
need your own PIA subscription.

## Is this your problem?

- You imported a PIA WireGuard `.conf` into NetworkManager (`nmcli connection
  import type wireguard`). It worked, then a day later it "connects" but
  nothing loads.
- `sudo wg show` says `0 B received` and there is no `latest handshake` line.
- The VPN comes up at boot and kills your internet.
- PIA's official app misbehaves on Wayland / Hyprland / Omarchy.
- You want a real killswitch on Linux, like Android's "Block connections
  without VPN", without breaking ufw, Docker or libvirt.

Then this is for you.

## Why it happens

PIA does not hand out permanent WireGuard configs: a registered key is
forgotten after a while, and a once-imported config then stops handshaking
(it "connects" but no traffic passes). `pia-nm` registers a fresh key on every
connect, so that never happens.

## What is in it

| File | What it does |
|---|---|
| `pia-nm` | Logs in to PIA, registers a fresh key, rebuilds the NetworkManager profile `pia` and connects; `--check` reconnects a dead or stale tunnel |
| `pia-killswitch` | An nftables table of its own: nothing leaves except through the tunnel, to the LAN, or to PIA's API while connecting. IPv6 is blocked (the tunnel is IPv4 only). ufw, Docker and libvirt rules are untouched |
| `pia-vpn.service` | Runs `pia-nm connect`; a failed connect leaves the killswitch on and retries |
| `pia-killswitch.service` | Loads the killswitch before the network comes up |
| `pia-region@.service` | Saves a region and reconnects; the only root step behind switching server without a password |
| `pia-watchdog.timer` | Every minute: reconnects with a new key if the tunnel is down, stale or passes no traffic |
| `pia-toggle` | VPN + killswitch on/off together, no password (polkit rule `50-pia.rules`); `--status` prints JSON for a bar |
| `manifest.json`, `Panel.qml`, `Fuzzy.js` | Omarchy bar widget `jamesrblack.pia`: status, server list with search and flags, click to toggle. At the top level so `omarchy plugin add` can install straight from this repo |

[docs/HOW-IT-WAS-BUILT.md](docs/HOW-IT-WAS-BUILT.md) records every problem hit
on the way (expiring keys, the killswitch design, a half-finished installer,
a watchdog that missed a dead tunnel, a polkit rule that refused "off") and how
each was found and fixed.

Credentials are encrypted with `systemd-creds` (bound to this machine and its
TPM when there is one) and decrypted only for `pia-vpn` and the watchdog.

## Install

Needs `curl jq wireguard-tools networkmanager nftables` (on Arch:
`sudo pacman -S --needed curl jq wireguard-tools networkmanager nftables`).
Do not enable `nftables.service`: its default config flushes ufw's and
Docker's rules.

```sh
git clone https://github.com/JamesRBlack/pia-wireguard-omarchy.git
cd pia-wireguard-omarchy
./install.sh                    # PIA login (once), region, detects your LAN
./install.sh --credentials      # change the saved login later
```

The installer records the network you are on as the LAN that stays reachable
with the killswitch on (`LAN=` in `/etc/pia/pia.env`; quote several:
`LAN="192.168.50.0/24, 10.20.0.0/16"`). It does not turn the VPN on or enable
it at boot.

### Bar: Omarchy (Quattro and later)

After `./install.sh`. The widget only displays and drives what the installer
sets up, so installing the widget alone (for example from the Omarchy plugin
marketplace) shows a "not installed" message until `./install.sh` has run.

```sh
omarchy plugin add https://github.com/JamesRBlack/pia-wireguard-omarchy.git --enable
omarchy-restart-shell
```

Updates later: `omarchy plugin update jamesrblack.pia`.

If the icon ever disappears, for example after restoring or resetting the
bar, the plugin is still installed but disabled. Turn it back on:

```sh
omarchy plugin enable jamesrblack.pia right
omarchy-restart-shell
```

Omarchy Quattro has no waybar: `omarchy-restart-shell` is the way to restart
the bar.

Left click opens the panel: region, server, the on/off switch and a server
list with country flags and fuzzy search: type `lon`, `uk lon` or `uklon`,
then Enter (or click). The current server is in bold white, the rest grey. Flags
need a colour-emoji font (`noto-fonts-emoji` on Arch). Right click toggles,
middle click refreshes. The icon is red while traffic is blocked. It toggles
quietly; failures still notify.

### Bar: waybar

`pia-toggle --status` prints waybar's JSON. In `~/.config/waybar/config.jsonc`
add `"custom/pia"` to a modules list and:

```jsonc
"custom/pia": {
  "exec": "pia-toggle --status",
  "return-type": "json",
  "interval": 10,
  "signal": 9,
  "on-click": "pia-toggle --quiet",
  "on-click-right": "pia-toggle pick"
}
```

Classes `on`, `blocked` and `off` are there for `style.css`, e.g.
`#custom-pia.blocked { color: #e06c75; }`.

### Keybinding (Hyprland)

```
bindd = SUPER ALT, V, Toggle PIA VPN, exec, pia-toggle
```

## Use

```sh
pia-toggle              # on <-> off
pia-toggle on | off
pia-toggle --status
```

Start at boot, with the killswitch up before the network:

```sh
sudo systemctl enable pia-killswitch pia-vpn
```

## Change server

No password needed; the killswitch stays up across the switch, and switching
while off connects.

- Omarchy: search or click a server in the widget's panel.
- Anywhere: `pia-toggle pick` opens a searchable menu (walker, fuzzel, wofi
  or rofi, whichever is installed). Bind it to a key or a bar right-click.
- Terminal: `pia-toggle --regions` lists ids, `pia-toggle region uk_london`
  switches.

Behind it, `pia-region@<id>.service` (root, allowed by the polkit rule) checks
the id against PIA's server list, saves it as `REGION=` in
`/etc/pia/pia.env` and restarts `pia-vpn`.

`PIHOLE=1` keeps your LAN DNS (e.g. a Pi-hole) instead of PIA's while
connected; queries then leave through your normal connection unless that DNS
server encrypts its upstream.
`KS_FORWARD=0` leaves VMs and containers out of the killswitch.

## Check it

```sh
sudo wg show pia | grep -E 'handshake|transfer'   # recent handshake, bytes received
curl -4 -s https://ifconfig.me; echo              # a PIA address
curl -6 -s --max-time 5 https://ifconfig.me || echo "ipv6 blocked"
sudo ip link set pia down                         # simulate a drop: traffic blocked,
curl -4 -s --max-time 5 https://ifconfig.me || echo BLOCKED   # watchdog reconnects within a minute
```

## Credits

The Omarchy panel follows the structure of
[Omawire](https://github.com/glafeara/omarchy-wireguard) (MIT), a general
WireGuard widget for the Omarchy bar. Use Omawire for ordinary WireGuard
tunnels; this repository exists because PIA's keys expire.

## Undo

```sh
pia-toggle off
omarchy plugin disable jamesrblack.pia
sudo systemctl disable --now pia-watchdog.timer pia-vpn pia-killswitch
sudo rm -f /usr/local/bin/pia-{nm,killswitch,toggle} /etc/systemd/system/pia-* \
  /etc/polkit-1/rules.d/50-pia.rules
sudo rm -rf /etc/pia
nmcli connection delete pia
```
