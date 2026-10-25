# How this was built

Every problem we hit on the way from "PIA config imported into NetworkManager"
to a working VPN with killswitch, watchdog and bar widget: what it looked
like, how we found the cause, and what fixed it. Built and tested on
an Omarchy "Quattro" laptop (Arch, Hyprland, NetworkManager, ufw, Docker,
libvirt) on a home network with its own firewall and local DNS.

The short version of what we learned:

- **PIA WireGuard configs expire.** A config that worked yesterday handshakes
  with nobody today. Register a fresh key on every connect.
- **Silence on the wire is the clue.** `0 B received` plus no
  `latest handshake` means the server never answered; a packet capture tells
  you whether that is your side or theirs.
- **Never report success you have not checked.** Two of our worst bugs were
  scripts saying "connected" or "VPN off" when the opposite was true.

---

## 1. The imported config came up at boot and killed the internet

**Symptom.** The PIA WireGuard profile, imported with
`nmcli connection import type wireguard`, activated on every boot. While it
was up nothing loaded.

**Why at boot:** `nmcli connection import` sets `autoconnect=yes`.
`nmcli connection modify pia connection.autoconnect no` stops that.

**Why no internet.** With the tunnel up:

```
transfer: 0 B received, 296 B sent
```

and no `latest handshake:` line. 296 bytes is exactly two WireGuard handshake
initiations (148 bytes each); not one byte came back. Routing (`ip rule`
showed NetworkManager's usual `fwmark 0xcab0` / table `51888` setup) and DNS
(`10.0.0.243` on the `pia` link) were correct, so everything was going into a
tunnel whose far end never answered.

**What we ruled out, and how:**

| Suspect | Test | Verdict |
|---|---|---|
| NetworkManager fighting iwd / systemd-networkd | `systemctl is-active NetworkManager systemd-networkd iwd` | Only NetworkManager running |
| Strict reverse-path filtering dropping replies | `sysctl net.ipv4.conf.{all,eth0}.rp_filter` gave 1 and 2 | The kernel uses the higher value per interface, so eth0 was loose; not it |
| ufw blocking outgoing UDP | `tcpdump -ni eth0 udp port 1337` while connecting | Three handshakes left eth0, 5 s apart; nothing came back. tcpdump sees packets before the firewall, so the laptop was not dropping replies |
| The router's firewall | (would have been next: its live log or a WAN capture) | Not needed, see below |

**Cause.** PIA's WireGuard keys are not permanent. Their API registers your
public key with one server for a limited time; after that the server silently
ignores it (WireGuard never answers an unknown key). A config imported once
works for a while and then dies.

**Fix.** `pia-nm`: log in, pick the region's WireGuard server, generate a key
pair, register it with the server's `addKey` API, write a fresh config,
import it and connect, every time. The first fresh-key connect handshaked
immediately, which confirmed the cause.

## 2. Choosing the client

- **PIA's official app** did not get along with Wayland/Hyprland and broke
  the desktop. Out.
- **PIA's `manual-connections` scripts** work, but use `wg-quick` outside
  NetworkManager and do not come back after a reboot.
- **Existing Omarchy/waybar WireGuard toggles** (omarchy-vpn, wg-toggle,
  Omawire) all bring a fixed profile up and down. With PIA that reintroduces
  the expired-key problem, and they would toggle the tunnel underneath the
  killswitch and watchdog.

So: our own `pia-nm` on NetworkManager, using the same API calls PIA's
scripts use.

## 3. Killswitch design

Goal: like Android's "Block connections without VPN". If the tunnel drops,
nothing leaks; turning the VPN off on purpose gives normal internet back.

Decisions:

- **Its own nftables table (`inet pia_ks`)**, not ufw rules. A packet has to
  pass every table's chains, so this table can only block, never open
  anything ufw, Docker or libvirt closed. Their rules stay untouched.
- **Not `nftables.service`.** Arch's default `/etc/nftables.conf` starts with
  `flush ruleset`, which would wipe ufw's and Docker's rules.
- **Loaded before the network** (`Before=network-pre.target`), so nothing
  leaks at boot.
- **Allowed:** loopback, the `pia` interface, the LAN (router, local DNS, printers),
  DHCP, multicast, VM and container bridges, and, while connecting, PIA's
  API hosts (an nft set with a 10-minute timeout that `pia-nm` fills with
  the addresses it resolves) and the chosen WireGuard server.
- **IPv6 blocked** except link-local and multicast: PIA's tunnel is IPv4
  only, so any IPv6 route would bypass it.
- **`reject`, not just drop**, so apps fail at once instead of hanging.
- **Forwarded traffic too** (`KS_FORWARD=1`): VMs and containers follow the
  same rule.
- **Separate units.** `pia-vpn.service` `Requires=` the killswitch, never the
  other way round. A failed connect does not run `ExecStop`, so the
  killswitch stays up and the service retries every 20 s.

Tested in an isolated network namespace before it went near the laptop:
traffic out of a normal interface refused, traffic via `pia` passed, reload
idempotent, set entries expiring.

## 4. Keeping the PIA password safe

The VPN must connect at boot and the watchdog must reconnect unattended, so
the password has to be stored; a password manager unlocked at login cannot
serve a service that starts before login.

First version: `/etc/pia/credentials`, root-only, plain text. Replaced with
**`systemd-creds`**: encrypted with a key bound to the machine (and its TPM if
present), decrypted by systemd into a private in-memory directory for
`pia-vpn` and the watchdog only (`LoadCredentialEncrypted=`). The installer
pipes what you type straight into the encryption, so the password never
touches the disk in plain text, and shreds any older plain copy.

Limits, stated plainly: root on the running machine can still decrypt it,
as the service does. The WireGuard private key NetworkManager stores is not
encrypted, but it is replaced on every connect.

## 5. The installer stopped halfway

**Symptom.**

```
curl: (7) Failed to connect to raw.githubusercontent.com:443 after 8 ms
Failed to enqueue jobs: Access denied
Warning: The unit file ... of pia-vpn.service changed on disk. Run 'systemctl daemon-reload'
```

**Cause.** The killswitch was already on from an earlier run, so the
installer's download of PIA's CA certificate was rejected (8 ms = a local
reject, not a network timeout). `set -e` stopped the installer right there,
before `systemctl daemon-reload` and before enabling the watchdog.

**Knock-on effect.** systemd kept running the old `pia-vpn.service`, which did
not load the encrypted credentials. The plain-text file had just been
shredded, so `pia-nm` had no login, could not prompt (no terminal), failed,
and retried every 20 s with all traffic blocked.

**Fix.** The installer no longer downloads anything: `pia-nm` fetches the CA
itself and opens the killswitch for exactly that host. After a
`daemon-reload` the service picked up the credentials.

## 6. "Connected", then failed anyway

**Symptom.**

```
pia-nm: connected to <region> (Server-NNNNN-Na)
/usr/local/bin/pia-nm: line 1: work: unbound variable
pia-vpn.service: Failed with result 'exit-code'.
```

**Cause.** The temp directory was a `local` variable inside `connect()`, but
the `EXIT` trap that deletes it runs after the function has returned. Under
`set -u` the variable no longer existed, so a successful connect exited 1.
systemd then restarted the service every 20 s, tearing down a working tunnel
each time. Each failed run also left a temp directory behind.

**Fix.** A global variable and `rm -rf "${work:-}"` in the trap. Reproduced
both versions under `set -u` before shipping.

## 7. The watchdog did not notice a dead tunnel

**Test.** `sudo ip link set pia down` to simulate a drop. The killswitch
blocked everything, as it should, but nothing reconnected and the status
still said "on".

**Cause.** The watchdog only checked that the interface *existed*, and the
last handshake was still under its 5-minute threshold. The status only
checked that the service was *running*.

**Fix.** The watchdog now reconnects when the interface is missing **or not
UP**, when the handshake is older than 5 minutes, **or** when two probes to
`1.1.1.1` through the tunnel fail (a server can keep handshaking yet pass
nothing). The status says "on" only when the service is active *and* the
link is UP. Retest: blocked at the first sample, back on 10 s later.

(One retest was misleading because a `# comment` pasted on the same line
swallowed `sleep 75`, so nothing waited. Loops with timestamps,
`date +%T` every 10 s, gave an unambiguous answer.)

## 8. The bar: Omarchy Quattro has no waybar

The first bar snippet targeted waybar. Omarchy Quattro puts the bar, panels
and everything else into one Quickshell-based shell with a plugin system
(`omarchy-plugin-*`, `omarchy-restart-shell`); there is no waybar and no
`omarchy-restart-waybar`.

The catalog had no VPN plugin. Omawire (`glafeara/omarchy-wireguard`) was
reviewed: clean code, no root, no network calls beyond a ping, but it toggles
profiles directly (problem 2). Its bar code showed the shell's building
blocks (`Panel`, `BarIconButton`, `KeyboardPanel`, `PanelHero`,
`ToggleSwitch`, `IpcHandler`), and the widget (`manifest.json`, `Panel.qml`,
`Fuzzy.js`, at the top level so `omarchy plugin add <repo url>` installs it)
is built from those.
Every action calls `pia-toggle`, so it cannot get out of step.

Gotcha copied from Omawire: inside `PanelHero`'s `iconComponent` and
`trailingControl`, `root` is the hero, not the panel. Panel state is reached
through a wrapper item (`header`).

## 9. Clicking "off" did nothing, but said "VPN off"

**Symptom.** Every click showed "VPN off — Normal connection, no killswitch",
yet the VPN stayed connected and the journal had no stop.

**Cause, in two parts:**

1. `pia-toggle off` stopped both units in one call:
   `systemctl stop pia-vpn.service pia-killswitch.service`. That was refused,
   `Failed to enqueue jobs: Access denied`, while single-unit starts were
   allowed. The polkit rule only approves requests naming these two units;
   the multi-unit stop evidently did not match it. "Jobs", plural, is the
   giveaway.
2. `pia-toggle` sent the "VPN off" notification without checking whether the
   stop worked, so the failure was invisible.

**Fix.** Stop one unit per call (the VPN first, so the killswitch holds while
the tunnel closes), check every `systemctl` call, and on failure send a
critical notification quoting systemd's error. Verified: `exit 0`, off, then
on with a fresh key on a new server.

**Red herring on the way:** a test mid-way through an OS update failed with
`libsystemd-shared-262.1-1.so: cannot open shared object file`: `systemctl`
itself, half-replaced by the update. Not ours, but don't reboot until an
interrupted systemd update has finished (`sudo pacman -Syu`).

## 10. Notifications covered the widget

The toasts appear in the same corner as the bar icon. `pia-toggle --quiet`
suppresses everything except failures; the widget always uses it, while the
keybinding and terminal keep their notifications.

---

## 11. Choosing a server without sudo

Switching meant editing root-owned `/etc/pia/pia.env` and restarting. A
user process cannot write that file, and polkit grants actions, not file
writes. So the root step became a templated unit, `pia-region@<id>.service`,
and the polkit rule allows starting exactly that, for ids matching
`[a-z0-9_-]+`. `pia-nm --set-region` checks the id again and confirms it is a
WireGuard region in PIA's live list before writing it. `%i` rather than `%I`
in the unit, because `%I` would unescape the `-` in ids like `de-frankfurt`
into `/`.

`pia-nm` caches the region list in `/run/pia/regions` whenever it reads PIA's
server list, so the picker works even while the killswitch blocks a live
fetch. The polkit rule was unit-tested in node: allowed for the PIA units and
valid region ids only; refused for other units, other users, other actions,
`stop` on a region unit and malformed ids.

## 12. Search and flags in the server list

PIA has about 200 WireGuard regions, too many to scroll. The panel's search
box uses fzf-style fuzzy matching (`Fuzzy.js`): the typed
characters must appear in order; word starts and runs score higher, gaps and
long names lower; space-separated words must all match. Entries are
lower-cased once, a linear subsequence scan rejects non-matches, and only
the rest get the dynamic-programming score, with reused buffers. Measured on
the real list: 0.1–0.25 ms per keystroke. (A first measurement said 7–24 ms;
that was Node's `vm` sandbox in the test harness, not the code.)

Flags come from each region's ISO country code as two regional-indicator
characters. The first list prefixed the current row with "● " and the others
with three spaces, which in a monospace font put that one name a character
out of line. Now the flag sits in a fixed-width column, there is no marker,
and the current server is simply white while the rest are grey; with a flag
shown, the redundant "UK " prefix is dropped from the name.

## 13. A widget the shell refused to load

Making the server names larger added a second `font.pixelSize:` to the name
`Text` instead of replacing the first. The shell skipped the widget entirely,
and only its log said why:

```
Plugin widget pia.vpn failed: Panel.qml:462:17: Property value set multiple times
```

`qmllint` without the shell's own modules does not report this, so
`tools/check-qml.py` does: it flags any property bound twice in one QML
object. Run it before every change to the widget. Checking the shell log is
the quickest way to see why a widget does not appear:

```sh
journalctl --user --since "10 min ago" | grep -iE 'pia|qml'
```

## 14. Two leaks found in review

The Omarchy plugin marketplace review found two:

- **The password on the command line.** `pia-nm` passed the PIA username and
  password to `curl` as `--form` arguments, and the login token as
  `--data-urlencode`. Any local user can read another process's arguments
  (`ps`, `/proc/*/cmdline`), so for the second or so each request took, they
  were in plain view. A test that hangs a stand-in `curl` shows it:

  ```
  root  /bin/sh .../curl -fsS ... --form username=user-x9 --form password=pass-x9 ...
  ```

  Now they go to `curl` as a config on stdin (`curl -K -`), quoted by
  `curl_opt`. `--form-string` replaces `--form` while at it: with `--form`, a
  password starting with `@` or `<` named a file to send instead. A test
  posts a password full of quotes, backslashes, tabs and newlines to a local
  server through the real `curl` and checks it arrives byte for byte.

- **Established flows skipped the forward killswitch.** The forward chain
  began with `ct state established,related accept`, before any check of
  where the packet was going. A VM or container connection opened before
  the killswitch came on (or while the tunnel was being replaced) went on
  leaving through the physical uplink. Now the outgoing interface is checked
  first, and only replies coming back through the tunnel are accepted for
  being established. The test builds a VM, an "internet" host and a tunnel
  out of network namespaces, with conntrack already running as it is under
  ufw or Docker: a UDP flow opened before the killswitch gets no further
  reply after it, and a new one through `pia` gets its reply.

## 15. A security audit, and everything it found

A second, independent audit of the whole repository found nothing critical,
four confirmed problems and five plausible ones. All are fixed, each with a
test that fails on the code before the fix (35 checks fail on the previous
version of the scripts):

- **PIA's API hole was open to every program.** While connecting, the
  killswitch let anything reach the API addresses on port 443 for ten
  minutes, and those addresses come from the network's own DNS. A hostile
  network could answer with addresses of its choice and have other programs'
  traffic leave in the clear. The rule now matches root only (`meta skuid 0`):
  `pia-nm` is the only program that needs it.
- **No VPN on a network other than the one at install.** `LAN=` is recorded
  at install, so elsewhere the killswitch also blocked the network's DNS
  server and `pia-nm` could not resolve PIA's hosts: blocked for good. Now
  `pia-nm` lets the network's DNS servers (from NetworkManager and
  resolv.conf) through on port 53 for two minutes before it resolves.
- **nft injection through the server list.** The server address went into
  `nft add element ... "{ $wg_ip }"`, where `}; add chain ...` runs as a
  second command. Every field from PIA (server address and name, the key
  API's address, key, port and DNS) is now checked against its exact format
  before use: a newline in the server key would otherwise have added lines of
  its own to the WireGuard config.
- **PIA's CA certificate was downloaded on first connect** and trusted from
  then on, including a half-downloaded copy. It is now in the repository
  (identical to the copy in PIA's OpenVPN bundle), installed by `install.sh`
  and checked against its SHA-256 before every connect.
- **polkit allowed restarting the killswitch**, which nothing uses and which
  drops it for a moment. Only start and stop now.
- **Stopping a connect half-way left the tunnel up.** systemd skips
  `ExecStop=` when a start is stopped before it finished; `ExecStopPost=`
  always runs. The bar also shows an error, and `pia-toggle off` closes the
  tunnel, if one is ever up without the service.
- **DNS could fall back to the LAN.** Without systemd-resolved, glibc tries
  every connection's DNS server in turn. The profile now has
  `ipv4.dns-priority -1`, which drops the others, and `ipv4.dns-search ~.`.
- **Region names were shown as rich text.** QML's `Text` renders anything
  that looks like markup, and rich text can load images from URLs. Names are
  stripped of markup, quotes and control characters where `pia-nm` writes
  them, and every `Text` in the panel is plain text.
- **A typo in `pia.env` turned the killswitch off.** `nft` refused the rules,
  the unit failed, and the VPN with it: plain internet, shown as "off". A
  refused `LAN=` now falls back to all private ranges, a line that does not
  parse is skipped, and a failed killswitch shows as an error.
- **The installer took any region id**, which then sat in a file root
  sources. It now asks until the id is one from PIA's list.

The bar's server list also could go stale: it was refreshed only on connect.
The watchdog now refreshes it when it is more than six hours old.

## 16. Testing in a real Omarchy

Unit tests and namespaces cannot show the widget in the shell, nor how
systemd, polkit and NetworkManager really behave. Omarchy publishes a
ready-installed VM image (4.0.6, stable) that boots under QEMU in seconds;
screenshots and clicks went through QEMU's QMP socket. It found five problems
the tests had not:

- **The "not installed" hint never showed.** The marketplace widget runs
  `/usr/local/bin/pia-toggle`, which does not exist before `install.sh`.
  Quickshell then logs "Process failed to start" every 5 seconds and never
  reports an exit, so the panel sat at "SERVERS (loading…)" forever. It now
  runs `pia-toggle` through `/usr/bin/env`, which exits 127 when it is
  missing; the hint shows, and goes away by itself after `install.sh`.
- **A stopped half-finished connect really did leave the tunnel up** (P1 of
  the audit): with `ExecStop=`, a `pia` tunnel brought up while `pia-vpn` was
  still starting survived `systemctl stop`; with `ExecStopPost=` it is gone.
- **`nmcli` exits 0 when NetworkManager refuses.** Closing a stray tunnel
  from an SSH session printed "Not authorized to deactivate connections" and
  `pia-toggle off` reported success. It now checks the interface afterwards
  and fails loudly. From the desktop session, the widget's switch closes it.
- **A wrong password was retried every 20 seconds, forever.** Within minutes
  PIA answered 429 (too many requests) to every login from that address. A
  refused login now exits 3, which `pia-vpn` does not retry; the killswitch
  stays up and the widget shows an error saying to fix the credentials. The
  log says "login refused" instead of `curl: (22) ... 401`.
- **The test suite left empty `/etc/pia`, `/run/pia` and `/run/netns`
  behind**: the mount points for its namespaces were made on the real
  filesystem. It now removes the ones it created.

Also confirmed there: Omarchy 4 uses NetworkManager (so the requirement
holds), `install.sh` stops on a missing `wireguard-tools` with the right
`pacman` command, `omarchy plugin validate` accepts the plugin, all tests pass
on Arch, the killswitch blocks with ufw active, the login request reaches PIA
through the killswitch's DNS and API holes, and polkit allows start and stop
without a password but refuses restart.

## Final checks (all passed)

| Check | Result |
|---|---|
| Fresh key on every connect | yes |
| Public IP is PIA's (same range as the connected server) | yes |
| IPv6 blocked | yes |
| DNS through PIA (`10.0.0.243`) | yes |
| Tunnel down: internet blocked, LAN reachable | yes |
| Watchdog reconnects with a new key | yes (10 s; at most about a minute) |
| Status "on" only with a live tunnel | yes |
| Toggle on/off without a password, failures reported | yes |
| Credentials encrypted, decrypted only for the services | yes |

## Debugging toolkit

```sh
sudo wg show pia                                   # handshake + bytes: is the far end answering?
sudo tcpdump -ni eth0 udp port 1337                # did it leave? did anything come back?
sysctl net.ipv4.conf.{all,eth0}.rp_filter          # strict reverse-path filtering?
ip rule; ip route show table all | grep -E 'default|wg|pia'
resolvectl status pia                              # which DNS while connected
sudo nft list table inet pia_ks                    # the killswitch as loaded
journalctl -u pia-vpn -u pia-watchdog -n 30 --no-pager
pia-toggle --status
```
