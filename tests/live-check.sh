#!/usr/bin/env bash
# Live check of an installed PIA VPN, for pasting back into a review. Run it
# from your own account in this repository, after ./install.sh from the same
# branch:
#
#   tests/live-check.sh           read-only: what is installed, the tunnel,
#                                 DNS, IPv6, the killswitch rules (~20 s)
#   tests/live-check.sh --full    also live tests that change state for a
#                                 few minutes: a reconnect watched for
#                                 credentials on command lines, a dropped
#                                 tunnel, a region switch and back, off and on
#
# The report (printed and saved as ~/pia-live-check-<time>.txt) never holds
# the password, the token, any key, or your real IP address: a public IP is
# only looked up while the tunnel is up (PIA's exit) and its last part is
# masked. Asks for sudo once (wg, nft and journalctl need root).
set -uo pipefail
cd "$(dirname "$0")/.."
REPO=$PWD
FULL=0
[[ ${1:-} == --full ]] && FULL=1
[[ $EUID != 0 ]] || { echo "run it as yourself, not root: it tests what your account can reach" >&2; exit 2; }

OUT=~/pia-live-check-$(date +%Y%m%d-%H%M%S).txt
exec > >(tee "$OUT") 2>&1

pass=0 fail=0 note=0
ok()   { pass=$((pass+1)); printf '  ok    %s\n' "$*"; }
bad()  { fail=$((fail+1)); printf '  FAIL  %s\n' "$*"; }
info() { note=$((note+1)); printf '  info  %s\n' "$*"; }
section() { printf '\n== %s\n' "$*"; }
# Masks the last octet of every IPv4 address.
mask_ip() { sed -E 's/\b([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.)[0-9]{1,3}\b/\1*/g'; }
# A final safety net over anything quoted from tools: WireGuard keys and
# anything that looks like a token or password field.
scrub() { sed -E 's#[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=#<key>#g; s#(token|password|pt)=[^ &"]*#\1=<redacted>#gI'; }
tunnel_up() { ip -o link show pia 2>/dev/null | grep -q '[<,]UP[,>]'; }
internet() { curl -4 -s -o /dev/null --max-time 6 -w '%{http_code}' https://example.com 2>/dev/null; }
public_ip() { curl -4 -s --max-time 6 https://ifconfig.me 2>/dev/null | mask_ip; }
# Journal lines as "HH:MM:SS unit[pid]: message", without the host name,
# and without systemd's start/finish lines for the watchdog every minute.
log_lines() {
  sed -E 's/^[0-9-]+T([0-9:]+)[^ ]* [^ ]+ /\1 /' | grep -v '^-- ' |
    grep -vE 'systemd\[1\]: (Starting|Finished) Reconnect PIA|pia-watchdog.service: Deactivated successfully' |
    scrub | mask_ip | sed 's/^/    /'
}
status_field() { (eval "$(grep "^$1=" /run/pia/status 2>/dev/null)"; printf '%s' "${!1:-}"); }
wait_for() {  # wait_for <seconds> <command...>: polls every second
  local t=$1 i; shift
  for (( i = 0; i < t; i++ )); do "$@" && return 0; sleep 1; done
  return 1
}

echo "PIA live check, $(date -u '+%Y-%m-%d %H:%M UTC'), mode: $([[ $FULL == 1 ]] && echo full || echo read-only)"
echo "No password, token, key or real IP address is included in this report."
sudo true || { echo "sudo is needed for wg, nft and journalctl"; exit 1; }
( while sleep 50; do sudo -n true 2>/dev/null || exit; done ) & KEEPALIVE=$!
trap 'kill $KEEPALIVE 2>/dev/null' EXIT

# A connect in progress would be caught half-way (an old profile, no tunnel
# yet): wait for it to finish first.
if [[ $(systemctl is-active pia-vpn) == activating ]]; then
  echo "pia-vpn is connecting; waiting for it to finish (up to 2 minutes)..."
  wait_for 120 bash -c '[[ $(systemctl is-active pia-vpn) != activating ]]'
  sleep 2
fi

# ---------------------------------------------------------------------------
section "system"
echo "  kernel $(uname -r); $(systemctl --version | head -1); $(nft --version 2>/dev/null)"
echo "  $(nmcli --version 2>/dev/null); $(curl --version | head -1 | cut -d' ' -f1-2); $(wg --version 2>/dev/null | cut -d' ' -f1-2)"
command -v omarchy-version >/dev/null && echo "  omarchy $(omarchy-version 2>/dev/null)"
for s in NetworkManager systemd-resolved ufw docker libvirtd; do
  printf '  %-17s %s\n' "$s" "$(systemctl is-active "$s" 2>/dev/null)"
done

# ---------------------------------------------------------------------------
section "installed code matches this branch"
echo "  branch $(git branch --show-current 2>/dev/null) at $(git rev-parse --short HEAD 2>/dev/null)$(git diff --quiet 2>/dev/null || echo ' (with local changes)')"
stale=0
for f in pia-nm pia-killswitch pia-toggle; do
  if cmp -s "$f" "/usr/local/bin/$f"; then ok "/usr/local/bin/$f"; else bad "/usr/local/bin/$f differs from the repository"; stale=1; fi
done
for f in pia-killswitch.service pia-vpn.service pia-watchdog.service pia-watchdog.timer pia-region@.service; do
  if cmp -s "$f" "/etc/systemd/system/$f"; then ok "/etc/systemd/system/$f"; else bad "/etc/systemd/system/$f differs"; stale=1; fi
done
# sudo cat, not sudo cmp: sudo closes the descriptor of a <(...) argument.
if cmp -s <(sed "s/@USER@/$USER/" 50-pia.rules) <(sudo cat /etc/polkit-1/rules.d/50-pia.rules 2>/dev/null); then ok "polkit rule"; else bad "polkit rule differs"; stale=1; fi
if [[ $(sha256sum /etc/pia/ca.rsa.4096.crt 2>/dev/null | cut -d' ' -f1) == "$(sed -n 's/^CA_SHA256=//p' pia-nm)" ]]; then
  ok "PIA's CA certificate installed and matching"
else bad "PIA's CA certificate missing or different"; stale=1; fi
[[ $stale == 0 ]] || info "run ./install.sh from this branch first, then this check again"
if [[ -f ~/.config/omarchy/plugins/jamesrblack.pia/Panel.qml ]]; then
  if cmp -s Panel.qml ~/.config/omarchy/plugins/jamesrblack.pia/Panel.qml; then ok "bar widget matches"
  else info "bar widget is another version (it updates from the published repository, not this branch)"; fi
fi

# ---------------------------------------------------------------------------
section "settings and credentials (names and modes only)"
sudo ls -l /etc/pia | tail -n +2 | awk '{print "  " $1, $3, $NF}'
grep -E '^(REGION|PIHOLE|LAN|KS_FORWARD)=' /etc/pia/pia.env 2>/dev/null | sed 's/^/  /'
if sudo test -f /etc/pia/credentials.cred && [[ $(sudo stat -c %a /etc/pia/credentials.cred) == 600 ]]; then
  ok "credentials only encrypted, root-only (600)"
else bad "no encrypted credentials at 600"; fi
if sudo test -e /etc/pia/credentials; then bad "a plain-text /etc/pia/credentials exists"; else ok "no plain-text credentials file"; fi

# ---------------------------------------------------------------------------
section "services"
for u in pia-killswitch.service pia-vpn.service pia-watchdog.timer; do
  printf '  %-23s %-10s %s\n' "$u" "$(systemctl is-active $u 2>/dev/null)" "$(systemctl is-enabled $u 2>/dev/null)"
done
[[ $(systemctl show pia-vpn -p ExecStopPost --value) == *pia-nm* ]] && ok "pia-vpn takes the tunnel down on any stop (ExecStopPost)" || bad "no ExecStopPost on pia-vpn"
[[ $(systemctl show pia-vpn -p RestartPreventExitStatus --value) == *3* ]] && ok "a refused login is not retried" || bad "RestartPreventExitStatus=3 missing"
echo "  pia-toggle --status: $(pia-toggle --status 2>&1)"
if [[ -s /run/pia/status ]]; then
  echo "  connected: region $(status_field REGION) ($(status_field NAME)), server $(status_field SERVER) $(status_field ENDPOINT), since $(status_field SINCE)"
fi
if [[ -s /run/pia/regions ]]; then
  echo "  region list: $(wc -l < /run/pia/regions) regions, $(( ($(date +%s) - $(stat -c %Y /run/pia/regions)) / 60 )) min old"
fi
echo "  recent log (pia-vpn, watchdog, killswitch):"
sudo journalctl -u pia-vpn -u pia-watchdog -u pia-killswitch --since -2h --no-pager -o short-iso 2>/dev/null | log_lines | tail -25

# ---------------------------------------------------------------------------
section "tunnel"
if tunnel_up; then
  ok "pia interface is up ($(ip -4 -o addr show pia | awk '{print $4}'))"
  hs=$(sudo wg show pia latest-handshakes 2>/dev/null | awk '{print $2}')
  [[ -n $hs && $hs != 0 ]] && age=$(( $(date +%s) - hs )) || age=-1
  if (( age >= 0 && age < 300 )); then ok "last handshake ${age}s ago"; else bad "no recent handshake ($age)"; fi
  sudo wg show pia transfer 2>/dev/null | awk '{printf "  transfer: %.1f MB received, %.1f MB sent\n", $2/1e6, $3/1e6}'
  echo "  endpoint: $(sudo wg show pia endpoints 2>/dev/null | awk '{print $2}')"
  [[ $(ip route get 1.1.1.1 2>/dev/null) == *"dev pia"* ]] && ok "internet routes through pia" || bad "internet does not route through pia: $(ip route get 1.1.1.1 | head -1 | mask_ip)"
  code=$(internet); [[ $code == 200 ]] && ok "internet reachable through the tunnel" || bad "internet not reachable (HTTP $code)"
  echo "  public IP (PIA's exit, masked): $(public_ip)"
else
  info "the tunnel is not up: tunnel, DNS and --full checks need the VPN on (pia-toggle on)"
fi
if [[ $(curl -6 -s -o /dev/null --max-time 5 -w '%{http_code}' https://ifconfig.co 2>/dev/null) == 200 ]]; then
  [[ $(systemctl is-active pia-killswitch) == active ]] && bad "IPv6 reaches the internet with the killswitch on" || info "IPv6 works (killswitch off)"
else
  ok "no IPv6 to the internet"
fi

# ---------------------------------------------------------------------------
section "DNS"
if nmcli -t connection show pia >/dev/null 2>&1; then
  echo "  pia profile: $(nmcli -g ipv4.dns,ipv4.dns-priority,ipv4.dns-search,connection.autoconnect,ipv6.method connection show pia | paste -sd' ' -) (dns, priority, search, autoconnect, ipv6)"
  pihole=$(sed -n 's/^PIHOLE=//p' /etc/pia/pia.env)
  if [[ $pihole != 1 ]]; then
    [[ $(nmcli -g ipv4.dns-priority connection show pia) == -1 ]] && ok "PIA's DNS replaces the others (priority -1)" || bad "pia profile lacks dns-priority -1"
  fi
fi
if systemctl is-active --quiet systemd-resolved; then
  resolvectl dns 2>/dev/null | sed 's/^/  dns    /'
  resolvectl domain 2>/dev/null | sed 's/^/  domain /'
  q=$(resolvectl query --cache=no example.com 2>&1)
  link=$(sed -n 's/.*-- link: \([^ ]*\).*/\1/p' <<<"$q" | head -1)
  if tunnel_up; then
    [[ $link == pia ]] && ok "a lookup is answered over pia" || bad "a lookup went over '${link:-?}', not pia"
  fi
else
  grep '^nameserver' /etc/resolv.conf | sed 's/^/  /'
fi

# ---------------------------------------------------------------------------
section "killswitch"
if sudo nft list table inet pia_ks >/dev/null 2>&1; then
  ok "table inet pia_ks loaded"
  rules=$(sudo nft list table inet pia_ks)
  grep -q 'meta skuid 0' <<<"$rules" && ok "PIA's API hole is root-only" || bad "API hole not limited to root"
  grep -q '@dns' <<<"$rules" && ok "DNS hole for connecting present" || bad "no DNS set"
  if grep -q 'chain forward' <<<"$rules"; then
    fwd=$(sed -n '/chain forward/,/}/p' <<<"$rules")
    head -4 <<<"$fwd" | grep -q 'ct state established' && bad "forward chain accepts established flows first" || ok "forward chain checks the interface before established flows"
  fi
  echo "  rules:"; mask_ip <<<"$rules" | sed 's/^/    /'
else
  info "killswitch not loaded"
fi

# ---------------------------------------------------------------------------
if [[ $FULL == 1 ]]; then
  section "live tests (--full)"
  if ! tunnel_up || [[ $(systemctl is-active pia-vpn) != active ]]; then
    info "skipped: turn the VPN on first (pia-toggle on), then run this again"
  else
    echo "  This reconnects, drops the tunnel, switches region and back, and turns"
    echo "  the VPN off and on: about 3 minutes, traffic blocked for parts of it."
    read -rp "  Go ahead? [y/N] " go </dev/tty
    if [[ $go == [yY]* ]]; then
      region=$(status_field REGION)
      # If anything below leaves the VPN half-way, put it back.
      # (PIA_TOGGLE_NO_WAIT throughout: its background wait would hold this
      # report open for two minutes.)
      export PIA_TOGGLE_NO_WAIT=1
      trap 'kill $KEEPALIVE 2>/dev/null; if ! tunnel_up; then echo "  restoring the tunnel"; pia-toggle region "$region" --quiet; fi' EXIT

      # 1. Reconnect while sampling every curl process's arguments, as any
      #    local user could. Only counts are kept: no argument text is stored.
      echo "  1/5 reconnect, watching curl's arguments for credentials"
      stop=$(mktemp -u); counts=$(mktemp)
      python3 -I - "$stop" "$counts" <<'PY' & watcher=$!
import os, re, sys, time
stop, out = sys.argv[1], sys.argv[2]
secret = re.compile(rb"(password|username)=|(^|[ =])pt=|--form ")
seen, hits, end = set(), 0, time.time() + 90
while time.time() < end and not os.path.exists(stop):
    for pid in os.listdir("/proc"):
        if not pid.isdigit():
            continue
        try:
            argv = open(f"/proc/{pid}/cmdline", "rb").read().split(b"\0")
        except OSError:
            continue
        if argv and os.path.basename(argv[0]) == b"curl" and pid not in seen:
            seen.add(pid)
            hits += bool(secret.search(b" ".join(argv)))
open(out, "w").write(f"{len(seen)} {hits}\n")
PY
      sleep 1   # the sampler is running before the first curl starts
      before=$(stat -c %Y /run/pia/status 2>/dev/null)
      t0=$SECONDS
      sudo systemctl restart pia-vpn
      if wait_for 90 bash -c "[[ \$(stat -c %Y /run/pia/status 2>/dev/null) != '$before' ]] && ip -o link show pia | grep -q UP"; then
        ok "reconnected with a new key in $((SECONDS - t0))s"
      else bad "no reconnect within 90s"; fi
      touch "$stop"; wait $watcher
      read -r curls hits < "$counts"; rm -f "$stop" "$counts"
      if (( curls == 0 )); then info "the sampler saw no curl process (too quick to catch)"
      elif (( hits == 0 )); then ok "$curls curl calls seen during the reconnect, none with credentials or the token"
      else bad "$hits of $curls curl calls had credentials or the token in their arguments"; fi

      # 2. Drop the tunnel: everything blocked for this account, PIA's API
      #    reachable for root only, then the watchdog's check reconnects.
      echo "  2/5 dropping the tunnel"
      api_ip=$(sudo nft list set inet pia_ks api 2>/dev/null | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1)
      sudo ip link set pia down
      code=$(internet); [[ $code == 000 ]] && ok "tunnel down: internet blocked" || bad "tunnel down, yet the internet answered (HTTP $code)"
      if [[ -n $api_ip ]]; then
        u=$(curl -s -o /dev/null --max-time 5 -w '%{http_code}' --resolve "www.privateinternetaccess.com:443:$api_ip" https://www.privateinternetaccess.com/ 2>/dev/null)
        r=$(sudo curl -s -o /dev/null --max-time 8 -w '%{http_code}' --resolve "www.privateinternetaccess.com:443:$api_ip" https://www.privateinternetaccess.com/ 2>/dev/null)
        [[ $u == 000 ]] && ok "PIA's API closed to this account" || bad "PIA's API reachable for this account (HTTP $u)"
        [[ $r != 000 ]] && ok "PIA's API open to root while connecting (HTTP $r)" || info "root could not reach PIA's API (HTTP $r); the set may have expired"
      fi
      t0=$SECONDS
      # The watchdog's own unit: it has the decrypted credentials.
      sudo systemctl start pia-watchdog.service
      if wait_for 60 tunnel_up && [[ $(internet) == 200 ]]; then ok "watchdog check reconnected in $((SECONDS - t0))s"
      else bad "no reconnect after a dropped tunnel"; fi

      # 3. Switch region and back; the killswitch must hold throughout.
      other=$(awk -F'\t' -v r="$region" '$1 != r && $1 ~ /^(nl_amsterdam|de-frankfurt|uk|ca_toronto|swiss)$/ {print $1; exit}' /run/pia/regions)
      [[ -n $other ]] || other=$(awk -F'\t' -v r="$region" '$1 != r {print $1; exit}' /run/pia/regions)
      echo "  3/5 switching to $other and back to $region"
      ks_drops=0
      for target in "$other" "$region"; do
        t0=$SECONDS
        pia-toggle region "$target" --quiet
        for (( i = 0; i < 90; i++ )); do
          [[ $(systemctl is-active pia-killswitch) == active ]] || ks_drops=$((ks_drops+1))
          [[ $(status_field REGION) == "$target" ]] && tunnel_up && break
          sleep 1
        done
        [[ $(status_field REGION) == "$target" ]] && ok "switched to $target in $((SECONDS - t0))s" || bad "switch to $target did not finish in 90s"
      done
      [[ $ks_drops == 0 ]] && ok "killswitch stayed up through both switches" || bad "killswitch was down $ks_drops times during a switch"

      # 4. Off: normal internet, no killswitch. On: back in the tunnel.
      echo "  4/5 off and on"
      pia-toggle off --quiet
      [[ $(systemctl is-active pia-killswitch) != active ]] && ! tunnel_up && [[ $(internet) == 200 ]] &&
        ok "off: no tunnel, no killswitch, internet works" || bad "off did not leave a normal connection"
      t0=$SECONDS
      pia-toggle on --quiet
      if wait_for 90 bash -c '[[ $(systemctl is-active pia-vpn) == active ]] && ip -o link show pia | grep -q UP'; then
        ok "on: connected in $((SECONDS - t0))s"
      else bad "on: not connected within 90s"; fi

      # 5. The bar's status after all of it.
      echo "  5/5 final state"
      echo "  pia-toggle --status: $(pia-toggle --status 2>&1)"
      echo "  public IP (PIA's exit, masked): $(public_ip)"
      echo "  log of these tests:"
      sudo journalctl -u pia-vpn -u pia-watchdog -u 'pia-region@*' --since -6min --no-pager -o short-iso 2>/dev/null | log_lines
    else
      info "live tests skipped"
    fi
  fi
fi

printf '\n%d ok, %d failed, %d notes. Report saved to %s\n' "$pass" "$fail" "$note" "$OUT"
