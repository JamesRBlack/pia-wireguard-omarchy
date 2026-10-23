#!/usr/bin/env bash
# Installs the PIA VPN setup: pia-nm, the killswitch, the services, the
# watchdog timer and the polkit rule for pia-toggle. Run from this folder:
#   ./install.sh                 install (asks for your PIA login once)
#   ./install.sh --credentials   change the saved PIA login
# It does not turn the VPN on and does not enable it at boot.
set -euo pipefail
[[ $EUID == 0 ]] || exec sudo "$0" "$@"
user=${SUDO_USER:?run it from your own account, not a root shell}
cd "$(dirname "$0")"

# Everything is checked before anything is changed: a failed check leaves the
# system exactly as it was.
problems=0

# command:package, with package names per package manager (Arch / Debian+Ubuntu / Fedora).
missing=()
for c in curl:curl:curl:curl jq:jq:jq:jq wg:wireguard-tools:wireguard-tools:wireguard-tools \
         nmcli:networkmanager:network-manager:NetworkManager nft:nftables:nftables:nftables \
         column:util-linux:bsdextrautils:util-linux; do
  IFS=: read -r cmd arch deb fedora <<<"$c"
  command -v "$cmd" >/dev/null && continue
  if command -v pacman >/dev/null; then missing+=("$arch")
  elif command -v apt-get >/dev/null; then missing+=("$deb")
  elif command -v dnf >/dev/null; then missing+=("$fedora")
  else missing+=("$cmd"); fi
done
if (( ${#missing[@]} )); then
  echo "missing: ${missing[*]}"
  if command -v pacman >/dev/null; then echo "  install with: sudo pacman -S --needed ${missing[*]}"
  elif command -v apt-get >/dev/null; then echo "  install with: sudo apt install ${missing[*]}"
  elif command -v dnf >/dev/null; then echo "  install with: sudo dnf install ${missing[*]}"
  else echo "  install these with your package manager"; fi
  echo "  (do not enable nftables.service: its default config wipes ufw's and Docker's rules)"
  problems=1
fi

# systemd-creds (password encryption) and LoadCredentialEncrypted need systemd 250+.
sdver=$(systemctl --version 2>/dev/null | awk 'NR == 1 {print $2 + 0}')
if [[ ${sdver:-0} -lt 250 ]] || ! command -v systemd-creds >/dev/null; then
  echo "systemd ${sdver:-?} is too old: 250 or newer is needed for encrypted credentials"
  problems=1
fi

# The tunnel is a NetworkManager connection, so NetworkManager must be the
# service managing the network, not just installed.
if command -v nmcli >/dev/null && ! systemctl is-active --quiet NetworkManager; then
  echo "NetworkManager is installed but not running. This VPN is a NetworkManager"
  echo "  connection, so NetworkManager has to manage your network. If you use iwd or"
  echo "  systemd-networkd on their own, switching is a bigger change: follow your"
  echo "  distribution's guide rather than just enabling NetworkManager next to them."
  problems=1
fi

if (( problems )); then echo "nothing installed"; exit 1; fi

# pia-nm owns the NetworkManager profile "pia" and recreates it on every
# connect. On a first install, a profile of that name belongs to someone else:
# ask before it gets replaced.
if [[ ! -f /etc/pia/pia.env ]] && nmcli -t -f NAME connection show 2>/dev/null | grep -qx pia; then
  echo "A NetworkManager connection named \"pia\" already exists. pia-nm replaces it"
  echo "with its own on every connect. Export it first if you want to keep it:"
  echo "  nmcli connection export pia > ~/pia-backup.conf   (WireGuard/VPN profiles)"
  read -rp "Replace it when the VPN connects? [y/N] " answer
  [[ $answer == [yY]* ]] || { echo "nothing installed"; exit 1; }
fi

install -m 755 pia-nm pia-killswitch pia-toggle /usr/local/bin/
install -m 644 pia-killswitch.service pia-vpn.service pia-watchdog.service pia-watchdog.timer \
  pia-region@.service /etc/systemd/system/
sed "s/@USER@/$user/" 50-pia.rules > /etc/polkit-1/rules.d/50-pia.rules
chmod 644 /etc/polkit-1/rules.d/50-pia.rules

# pia.env holds no secrets and the bar reads REGION from it; the credentials
# file is 0600 on its own.
install -d -m 755 /etc/pia
if [[ ! -f /etc/pia/pia.env ]]; then
  install -m 644 pia.env /etc/pia/pia.env
  # The killswitch loads before the network is up, so the LAN it must keep
  # reachable is recorded now, from the interface that has the default route.
  dev=$(ip -4 route show default | awk '{for (i=1;i<NF;i++) if ($i=="dev") {print $(i+1); exit}}')
  lan=$(ip -4 route show dev "${dev:-none}" scope link 2>/dev/null | awk '$1 ~ /\// {print $1; exit}')
  if [[ -n $lan ]]; then
    sed -i "s|^LAN=.*|LAN=$lan|" /etc/pia/pia.env
    echo "local network: $lan (reachable with the killswitch on; LAN= in /etc/pia/pia.env)"
  else
    echo "could not detect your local network: all private ranges stay reachable (LAN= in /etc/pia/pia.env)"
  fi
  echo "PIA regions:"
  /usr/local/bin/pia-nm --list | column -t -s $'\t' | sed 's/^/  /' || true
  region=""
  until [[ -n $region ]]; do read -rp "Region id from the list above: " region; done
  sed -i "s|^REGION=.*|REGION=$region|" /etc/pia/pia.env
fi
chmod 644 /etc/pia/pia.env

# Credentials are encrypted with systemd-creds: a key bound to this machine
# (and its TPM, when it has one), decrypted only for pia-vpn and the watchdog.
# Typed credentials go straight into the encryption, never to disk in plain text.
CRED=/etc/pia/credentials.cred
encrypt() { ( umask 077; systemd-creds encrypt --name=pia "$1" "$CRED" ); }
[[ ${1:-} == --credentials ]] && rm -f "$CRED"
if [[ ! -f $CRED ]]; then
  plain=""
  # A plain-text file from an earlier version of this installer.
  [[ -f /etc/pia/credentials ]] && plain=/etc/pia/credentials
  if [[ -n $plain && ${1:-} != --credentials ]]; then
    encrypt "$plain"
    echo "encrypted $plain into $CRED"
  else
    read -rp "PIA username: " u; read -rsp "PIA password: " p; echo
    printf 'PIA_USER=%q\nPIA_PASS=%q\n' "$u" "$p" | encrypt -
    unset u p
  fi
  # Plain-text copies would defeat the point. shred cannot guarantee an SSD
  # forgets the old blocks; full-disk encryption covers that.
  if [[ -f /etc/pia/credentials ]]; then
    shred -u /etc/pia/credentials && echo "removed plain-text /etc/pia/credentials"
  fi
fi
systemctl daemon-reload
systemctl enable --now pia-watchdog.timer

echo
echo "installed. Settings: /etc/pia/pia.env"
echo "  pia-toggle            VPN + killswitch on/off"
echo "  sudo systemctl enable pia-killswitch pia-vpn    also at boot (strict)"
