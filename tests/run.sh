#!/usr/bin/env bash
# Regression tests. Nothing here touches the real system: scripts run against
# stand-in commands (systemctl, nmcli, curl...), a fixture of PIA's region list,
# and, for the killswitch and pia-nm, private mount/network namespaces.
#
# Usage: tests/run.sh
# Needs bash and python3. Optional, skipped when absent: node (fuzzy search,
# polkit rule), jq and sudo (pia-nm in a namespace), nft and sudo (killswitch).
# NFT=/path/to/nft and JQ=/path/to/jq override which binaries are used.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
FIX=$ROOT/tests/fixtures
WORK=$(mktemp -d)
# The namespace tests mount tmpfs on these, but the mount points themselves
# are made on the real filesystem: remove the ones that were not there before.
MOUNT_POINTS=()
for d in /etc/pia /run/pia /run/netns; do [[ -e $d ]] || MOUNT_POINTS+=("$d"); done
cleanup() {
  rm -rf "$WORK"
  if (( ${#MOUNT_POINTS[@]} )); then sudo -n rmdir "${MOUNT_POINTS[@]}" 2>/dev/null || true; fi
}
trap cleanup EXIT

pass=0 fail=0 skip=0
ok()   { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; [[ -n ${2:-} ]] && printf '        %s\n' "$2"; }
skp()  { skip=$((skip+1)); printf '  skip  %s (%s)\n' "$1" "$2"; }
check() { if eval "$2"; then ok "$1"; else bad "$1" "${3:-}"; fi; }
section() { printf '\n%s\n' "$1"; }

# A directory of stand-in commands put first on PATH. Each records its
# arguments in $WORK/calls.
stub() {  # stub <dir> <name> <shell body>
  mkdir -p "$1"
  printf '#!/bin/sh\necho "%s $*" >> %s/calls\n%s\n' "$2" "$WORK" "$3" > "$1/$2"
  chmod +x "$1/$2"
}
can_sudo() { sudo -n true 2>/dev/null; }

# ---------------------------------------------------------------------------
section "syntax"
for f in pia-nm pia-killswitch pia-toggle install.sh tests/run.sh; do
  check "bash -n $f" "bash -n $f"
done
check "manifest.json is valid JSON" "python3 -I -m json.tool manifest.json >/dev/null"
check "manifest has the 8 marketplace fields" "python3 -I -c '
import json; m=json.load(open(\"manifest.json\"))
assert all(m.get(k) for k in [\"schemaVersion\",\"id\",\"name\",\"version\",\"author\",\"description\",\"kinds\",\"entryPoints\"])
assert m[\"entryPoints\"][\"barWidget\"] == \"Panel.qml\"'"
check "no QML property bound twice" "python3 -I tools/check-qml.py Panel.qml"
check "Panel.qml ids match the manifest" "python3 -I -c '
import json; i=json.load(open(\"manifest.json\"))[\"id\"]; q=open(\"Panel.qml\").read()
assert \"moduleName: \\\"%s\\\"\" % i in q and \"ipcTarget: \\\"%s\\\"\" % i in q'"

check "every Text in Panel.qml is plain text (PIA's names are never rich text)" "python3 -I -c '
import re; q=open(\"Panel.qml\").read()
blocks=re.findall(r\"(?m)^([ \\t]*)Text \\{\\n(.*?)^\\1\\}\", q, re.S)
assert blocks and all(\"textFormat: Text.PlainText\" in b for _, b in blocks), len(blocks)'"
# Started directly, a missing pia-toggle never starts and never exits, so the
# panel would sit at "loading…" instead of saying the VPN is not installed.
check "Panel.qml runs pia-toggle through env, so a missing one exits 127" \
  "grep -q '\"/usr/bin/env\", toggleCmd' Panel.qml && ! grep -qE 'command: \\[root.toggleCmd|= \\[toggleCmd' Panel.qml && grep -q 'exitCode === 127' Panel.qml"
check "pia-vpn takes the tunnel down after any stop, even of an unfinished start" \
  "grep -qx 'ExecStopPost=/usr/local/bin/pia-nm --down' pia-vpn.service && ! grep -q '^ExecStop=' pia-vpn.service"
check "install.sh installs the shipped CA certificate" "grep -q '^install -m 644 ca.rsa.4096.crt /etc/pia/ca.rsa.4096.crt' install.sh"

# ---------------------------------------------------------------------------
section "pia-toggle"
T=$WORK/toggle
stub "$T" notify-send 'echo "NOTIFY $*" >> '"$WORK"'/notes'
stub "$T" pkill 'exit 0'
stub "$T" ip 'exit 1'
# PIA_TOGGLE_NO_WAIT: skip the background wait for the tunnel, which would
# otherwise poll the stand-in systemctl for two minutes after each test.
run_toggle() { : > "$WORK/calls"; : > "$WORK/notes"; PIA_TOGGLE_NO_WAIT=1 PATH=$T:$PATH "$ROOT/pia-toggle" "$@"; }

stub "$T" systemctl 'case "$1" in is-active) echo inactive; exit 3;; esac; exit 0'
out=$(run_toggle --status)
check "status prints valid JSON" "python3 -I -c 'import json,sys; json.loads(sys.argv[1])' '$out'"
check "status says off when nothing runs" "[[ '$out' == *'\"class\":\"off\"'* ]]"

run_toggle on --quiet
check "on starts pia-vpn" "grep -q 'systemctl start --no-block pia-vpn.service' $WORK/calls"
check "--quiet sends no success toast" "! grep -q 'VPN connecting' $WORK/notes"

stub "$T" systemctl 'case "$1" in is-active) echo active;; stop) exit 0;; esac; exit 0'
run_toggle off >/dev/null 2>&1
check "off stops the VPN and killswitch one unit per call" \
  "grep -qx 'systemctl stop pia-vpn.service' $WORK/calls && grep -qx 'systemctl stop pia-killswitch.service' $WORK/calls"
check "off reports a killswitch that stayed up" "grep -q 'VPN still on' $WORK/notes"

stub "$T" systemctl 'case "$1" in is-active) echo active;; stop) echo "Access denied" >&2; exit 4;; esac'
run_toggle off --quiet >/dev/null 2>&1; rc=$?
check "a refused stop exits non-zero" "[[ $rc != 0 ]]"
check "a refused stop notifies even with --quiet" "grep -q 'Could not turn the VPN off' $WORK/notes && grep -q 'Access denied' $WORK/notes"
run_toggle off >/dev/null 2>&1
check "a refused stop never shows the success toast" "! grep -q 'Normal connection, no killswitch' $WORK/notes"

stub "$T" systemctl 'case "$1" in is-active) echo inactive; exit 3;; esac; exit 0'
run_toggle region 'x;rm -rf /' --quiet >/dev/null 2>&1; rc=$?
check "region refuses a malformed id" "[[ $rc != 0 ]] && ! grep -q 'pia-region@' $WORK/calls"
run_toggle region uk --quiet
check "region starts pia-region@<id>" "grep -qx 'systemctl start pia-region@uk.service' $WORK/calls"
check "region connects when the VPN was off" "grep -q 'systemctl start --no-block pia-vpn.service' $WORK/calls"

# A killswitch that failed to load (a broken pia.env) is an error, not "off".
stub "$T" systemctl 'case "$1 $2" in "is-active pia-killswitch.service") echo failed; exit 3;; is-active*) echo inactive; exit 3;; esac; exit 0'
out=$(run_toggle --status)
check "status says error when the killswitch failed" "[[ '$out' == *'\"class\":\"error\"'* && '$out' == *journalctl* ]]" "$out"
# pia-vpn gave up while the killswitch blocks: an error, not "connecting".
stub "$T" systemctl 'case "$1 $2" in "is-active pia-killswitch.service") echo active;; is-active*) echo failed; exit 3;; esac; exit 0'
out=$(run_toggle --status)
check "status says error when pia-vpn gave up under the killswitch" "[[ '$out' == *'\"class\":\"error\"'* && '$out' == *'install.sh --credentials'* ]]" "$out"
# A tunnel left up without pia-vpn: an error, and "off" closes it.
# ip shows the tunnel while $WORK/tunnel exists; nmcli "down" removes it.
stub "$T" ip '[ -e '"$WORK"'/tunnel ] && echo "9: pia: <POINTOPOINT,NOARP,UP,LOWER_UP> mtu 1420"'
stub "$T" nmcli 'rm -f '"$WORK"'/tunnel'
touch "$WORK/tunnel"
stub "$T" systemctl 'case "$1" in is-active) echo inactive; exit 3;; esac; exit 0'
out=$(run_toggle --status)
check "status says error for a tunnel up without pia-vpn" "[[ '$out' == *'\"class\":\"error\"'* && '$out' == *'without pia-vpn'* ]]" "$out"
check "status is still valid JSON" "python3 -I -c 'import json,sys; json.loads(sys.argv[1])' '$out'"
run_toggle off --quiet >/dev/null 2>&1; rc=$?
check "off closes a tunnel that outlived pia-vpn" "[[ $rc == 0 ]] && grep -qx 'nmcli connection down pia' $WORK/calls && [[ ! -e $WORK/tunnel ]]"
# NetworkManager refuses (no active session) and nmcli still exits 0.
touch "$WORK/tunnel"
stub "$T" nmcli 'echo "Connection pia deactivation failed: Not authorized to deactivate connections" >&2; exit 0'
run_toggle off --quiet >/dev/null 2>&1; rc=$?
check "off fails loudly when the tunnel stays up despite nmcli's exit 0" \
  "[[ $rc != 0 ]] && grep -q 'Could not close the tunnel' $WORK/notes && grep -q 'Not authorized' $WORK/notes"
rm -f "$WORK/tunnel"
stub "$T" ip 'exit 1'
run_toggle off --quiet >/dev/null 2>&1
check "off leaves NetworkManager alone when no tunnel is up" "! grep -q 'nmcli' $WORK/calls"

# pick: the menu returns the line for UK London
mkdir -p "$WORK/home/run"
python3 -I -c '
import json,sys
for r in json.load(open(sys.argv[1]))["regions"]: print(r["id"], r["name"], r["country"], sep="\t")' \
  "$FIX/servers.json" > "$WORK/regions.tsv"
stub "$T" pia-nm "cat $WORK/regions.tsv"
# Every menu pick knows about gets the stand-in: pick uses the first one
# installed, and a real walker or rofi would open a window.
for menu in walker fuzzel wofi rofi; do stub "$T" "$menu" 'grep "(uk)"'; done
run_toggle pick --quiet
check "pick switches to the chosen region" "grep -qx 'systemctl start pia-region@uk.service' $WORK/calls"

# ---------------------------------------------------------------------------
section "fuzzy search (Fuzzy.js)"
if command -v node >/dev/null; then
  out=$(node - "$ROOT/Fuzzy.js" "$FIX/servers.json" <<'EOF'
const fs = require("fs")
const src = fs.readFileSync(process.argv[2], "utf8").replace(/^\.pragma library\s*/, "")
const F = new Function(src + "; return {prepare, filter};")()
const regions = JSON.parse(fs.readFileSync(process.argv[3])).regions
const E = F.prepare(regions)
const top = q => (F.filter(E, q)[0] || {}).name
const cases = [["lon", "UK London"], ["uk lon", "UK London"], ["uklon", "UK London"],
               ["frank", "DE Frankfurt"], ["tok", "JP Tokyo"], ["new york", "US New York"]]
for (const [q, want] of cases) console.log((top(q) === want ? "ok" : "FAIL") + "\t" + q + " -> " + top(q))
console.log((F.filter(E, "xyzzy").length === 0 ? "ok" : "FAIL") + "\tno match returns nothing")
console.log((F.filter(E, "").length === regions.length ? "ok" : "FAIL") + "\tempty query keeps every region")
for (let k = 0; k < 200; k++) F.filter(E, "uk lon")
let t = process.hrtime.bigint(); for (let k = 0; k < 2000; k++) F.filter(E, "streaming")
const ms = Number(process.hrtime.bigint() - t) / 1e6 / 2000
console.log((ms < 5 ? "ok" : "FAIL") + "\tunder 5 ms per keystroke (" + ms.toFixed(3) + " ms)")
EOF
)
  while IFS=$'\t' read -r verdict what; do
    [[ $verdict == ok ]] && ok "$what" || bad "$what"
  done <<<"$out"
else
  skp "fuzzy search" "node not installed"
fi

# ---------------------------------------------------------------------------
section "polkit rule (50-pia.rules)"
if command -v node >/dev/null; then
  out=$(sed 's/@USER@/alice/' 50-pia.rules | node -e '
let src = ""; process.stdin.on("data", d => src += d).on("end", () => {
  let rule; const polkit = {Result: {YES: "yes", NOT_HANDLED: "no"}, addRule: f => rule = f}
  new Function("polkit", src)(polkit)
  const M = "org.freedesktop.systemd1.manage-units"
  const cases = [
    ["alice", M, "pia-vpn.service", "stop", "yes"], ["alice", M, "pia-killswitch.service", "start", "yes"],
    ["alice", M, "pia-region@uk.service", "start", "yes"], ["alice", M, "pia-region@us_alaska-pf.service", "start", "yes"],
    ["alice", M, "pia-killswitch.service", "restart", "no"], ["alice", M, "pia-vpn.service", "restart", "no"],
    ["alice", M, "pia-region@uk.service", "stop", "no"], ["alice", M, "pia-region@../x.service", "start", "no"],
    ["alice", M, "sshd.service", "stop", "no"], ["alice", M, undefined, "stop", "no"],
    ["mallory", M, "pia-vpn.service", "stop", "no"], ["alice", "org.freedesktop.login1.reboot", "pia-vpn.service", "start", "no"]]
  for (const [user, id, unit, verb, want] of cases) {
    const got = rule({id, lookup: k => ({unit, verb})[k]}, {user}) || "no"
    console.log((got === want ? "ok" : "FAIL") + "\t" + user + " " + verb + " " + unit + " -> " + got)
  }
})')
  while IFS=$'\t' read -r verdict what; do
    [[ $verdict == ok ]] && ok "$what" || bad "$what"
  done <<<"$out"
else
  skp "polkit rule" "node not installed"
fi

# ---------------------------------------------------------------------------
section "installer checks (run before anything is changed)"
pre=$(sed -n '/^problems=0$/,/^if (( problems )); then echo "nothing installed"; exit 1; fi$/p' install.sh)
check "the check section is found in install.sh" "[[ -n \$pre ]]"
I=$WORK/inst
for c in curl jq wg nmcli nft column systemd-creds pacman; do stub "$I/all" "$c" 'exit 0'; done
stub "$I/all" systemctl 'case "$1" in --version) echo "systemd 256 (256.7)";; is-active) exit 0;; esac'
out=$(PATH=$I/all:$PATH bash -c "$pre"$'\necho PASSED' 2>&1)
check "passes when everything is there" "[[ \$out == PASSED ]]" "$out"
cp -r "$I/all" "$I/old"
stub "$I/old" systemctl 'case "$1" in --version) echo "systemd 249 (249.11)";; is-active) exit 3;; esac'
out=$(PATH=$I/old:$PATH bash -c "$pre"$'\necho PASSED' 2>&1)
check "stops on systemd 249" "[[ \$out == *'too old'* && \$out != *PASSED* ]]" "$out"
check "stops when NetworkManager is not running" "[[ \$out == *'not running'* ]]" "$out"
# A PATH of only stand-ins plus the few real tools the check uses, so a real
# wg elsewhere on the system cannot make this pass.
mkdir -p "$I/nowg"; cp "$I/all"/* "$I/nowg/"; rm "$I/nowg/wg"
for t in awk; do ln -sf "$(command -v $t)" "$I/nowg/$t"; done
out=$(PATH=$I/nowg "$BASH" -c "$pre"$'\necho PASSED' 2>&1)
check "names wireguard-tools when wg is missing" "[[ \$out == *wireguard-tools* && \$out == *'pacman -S'* && \$out != *PASSED* ]]" "$out"

eval "$(sed -n '/^ask_region()/,/^}/p' install.sh)"
if declare -F ask_region >/dev/null; then
  list=$(printf 'uk\tUK London\tGB\nus_chicago\tUS Chicago\tUS\n')
  got=$(printf 'uk london\nx;rm -rf /\nnowhere\nus_chicago\n' | ask_region "$list" 2>"$WORK/ask.err")
  check "region prompt asks again until an id from the list" \
    "[[ \$got == us_chicago ]] && [[ \$(grep -c 'not' $WORK/ask.err) == 3 ]]" "$got / $(cat "$WORK/ask.err")"
  got=$(printf 'Bad Id\nnew_region\n' | ask_region "" 2>/dev/null)
  check "without a list (offline) any well-formed id is taken" "[[ \$got == new_region ]]"
  printf 'uk london\n' | ask_region "$list" >/dev/null 2>&1; rc=$?
  check "the region prompt gives up at end of input" "[[ $rc == 1 ]]"
else
  bad "ask_region is defined in install.sh"
fi

# ---------------------------------------------------------------------------
section "pia-nm --set-region (private mount namespace)"
JQ=${JQ:-$(command -v jq || true)}
if can_sudo && [[ -n $JQ ]]; then
  N=$WORK/nm
  stub "$N" curl "cat $FIX/servers.json"
  stub "$N" systemctl 'case "$1" in is-active) exit 3;; esac; exit 0'
  stub "$N" nmcli 'exit 0'
  stub "$N" wg 'exit 0'
  printf '#!/bin/sh\nexec %q "$@"\n' "$JQ" > "$N/jq"; chmod +x "$N/jq"
  out=$(sudo unshare -m bash -c "
    mkdir -p /etc/pia /run/pia && mount -t tmpfs tmpfs /etc/pia && mount -t tmpfs tmpfs /run/pia
    printf 'REGION=aus\nPIHOLE=0\n' > /etc/pia/pia.env
    export PATH=$N:\$PATH
    ./pia-nm --set-region uk >/dev/null 2>&1; echo \"valid=\$? \$(grep ^REGION= /etc/pia/pia.env)\"
    ./pia-nm --set-region nowhere_land >/dev/null 2>&1; echo \"unknown=\$? \$(grep ^REGION= /etc/pia/pia.env)\"
    ./pia-nm --set-region '../x;rm' >/dev/null 2>&1; echo \"hostile=\$?\"
    echo \"cache=\$(wc -l < /run/pia/regions) \$(grep -P '^uk\t' /run/pia/regions | cut -f2,3 | tr '\t' '|')\"
    echo \"cachemode=\$(stat -c %a /run/pia/regions)\"
  " 2>&1)
  check "a valid region is saved" "grep -q 'valid=0 REGION=uk' <<<\"\$out\"" "$out"
  check "an unknown region is refused and nothing changes" "grep -q 'unknown=1 REGION=uk' <<<\"\$out\"" "$out"
  check "a malformed id is refused" "grep -q 'hostile=1' <<<\"\$out\"" "$out"
  check "the region list is cached with country codes" "grep -q 'cache=215 UK London|GB' <<<\"\$out\"" "$out"
  check "the cache is readable by the bar (644)" "grep -q 'cachemode=644' <<<\"\$out\"" "$out"
else
  skp "pia-nm --set-region" "needs passwordless sudo and jq"
fi

# ---------------------------------------------------------------------------
section "pia-nm connect and --check (private mount namespace)"
# Stand-ins for everything pia-nm talks to. What they answer is set per test
# through files in $WORK: servers-now.json (PIA's server list), addkey.json
# (the key API's answer) and ks (present = the killswitch is on).
if can_sudo && [[ -n $JQ ]]; then
  C=$WORK/connect
  stub "$C" curl 'case "$*" in
  *serverlist*) cat '"$WORK"'/servers-now.json ;;
  *addKey*) cat > '"$WORK"'/addkey.stdin; cat '"$WORK"'/addkey.json ;;
  */token*) cat > '"$WORK"'/token.stdin
    if [ -e '"$WORK"'/login-401 ]; then printf "{\"message\":\"Unauthorized\"}\n401"
    else printf "{\"token\":\"TOKEN-s3cret\"}\n200"; fi ;;
esac
exit 0'
  stub "$C" wg 'case "$1" in genkey) echo PRIVKEY;; pubkey) cat >/dev/null; echo PUBKEY;;
  show) echo "K $(date +%s)";; esac'
  stub "$C" nmcli 'case "$*" in *IP4.DNS*) printf "192.168.1.1 | 9.9.9.9\n\n";; esac; exit 0'
  stub "$C" nft '[ -e '"$WORK"'/ks ] || exit 1'
  stub "$C" getent 'echo "192.0.2.80      STREAM $2"'
  stub "$C" systemctl 'exit 0'
  stub "$C" ip 'echo "9: pia: <POINTOPOINT,NOARP,UP,LOWER_UP> mtu 1420"'
  printf '#!/bin/sh\nexec %q "$@"\n' "$JQ" > "$C/jq"; chmod +x "$C/jq"
  GOOD_KEY='{"status":"OK","peer_ip":"10.1.2.3","server_key":"a2tra2tra2tra2tra2tra2tra2tra2tra2tra2tra2s=","server_port":1337,"dns_servers":["10.0.0.243"]}'

  # run_nm <ca file> <pia-nm args...>: runs pia-nm as root in a private mount
  # namespace; prints its output, "rc=<exit code>" and the files it wrote.
  # Set REGIONS_AGE (e.g. "7 hours ago") to start from a one-line region list.
  run_nm() {
    local ca=$1; shift
    : > "$WORK/calls"; : > "$WORK/token.stdin"; : > "$WORK/addkey.stdin"
    sudo env PIA_USER='user-x9' PIA_PASS='pass-x9 "q\u<o@te' unshare -m bash -c "
      mkdir -p /etc/pia /run/pia && mount -t tmpfs tmpfs /etc/pia && mount -t tmpfs tmpfs /run/pia
      printf 'REGION=uk\nPIHOLE=0\n' > /etc/pia/pia.env; cp $ca /etc/pia/ca.rsa.4096.crt
      if [[ -n '${REGIONS_AGE:-}' ]]; then
        printf 'old\tOld\tXX\n' > /run/pia/regions; touch -d '${REGIONS_AGE:-now}' /run/pia/regions
      fi
      export PATH=$C:\$PATH
      ./pia-nm $* </dev/null 2>&1; echo \"rc=\$?\"
      sed 's/^/status: /' /run/pia/status 2>/dev/null
      echo \"regions: \$(wc -l < /run/pia/regions 2>/dev/null)\"
      grep -P '^uk\t' /run/pia/regions 2>/dev/null | sed 's/^/uk: /'
    " 2>&1
  }
  # A copy of the fixture with one jq edit applied to it.
  servers_with() { "$JQ" -c "$1" "$FIX/servers.json" > "$WORK/servers-now.json"; }

  cp "$FIX/servers.json" "$WORK/servers-now.json"; echo "$GOOD_KEY" > "$WORK/addkey.json"; rm -f "$WORK/ks"
  out=$(run_nm "$ROOT/ca.rsa.4096.crt" connect)
  check "connect succeeds against the stand-ins" "grep -q 'rc=0' <<<\"\$out\" && grep -q 'status: SERVER=test-server' <<<\"\$out\"" "$out"
  # Every local user can read any process's arguments (ps, /proc/*/cmdline),
  # so the password and the token must reach curl on stdin.
  check "no curl argument holds the username, password or token" \
    "! grep -qE 'user-x9|pass-x9|TOKEN-s3cret' $WORK/calls" "$(grep -E 'user-x9|pass-x9|TOKEN' "$WORK/calls")"
  check "login reads username and password from stdin" \
    "grep -q 'user-x9' $WORK/token.stdin && grep -q 'pass-x9' $WORK/token.stdin"
  check "addKey reads the token from stdin" "grep -q 'TOKEN-s3cret' $WORK/addkey.stdin"
  check "PIA's DNS replaces the LAN's (dns-priority -1, search ~.)" \
    "grep -q 'nmcli connection modify pia ipv4.dns-priority -1 ipv4.dns-search ~.' $WORK/calls" "$(grep nmcli "$WORK/calls")"
  check "the CA certificate is never downloaded" "! grep -q 'githubusercontent' $WORK/calls"

  touch "$WORK/login-401"
  out=$(run_nm "$ROOT/ca.rsa.4096.crt" connect)
  check "a wrong password says so, instead of curl's HTTP error" \
    "grep -q 'rc=3' <<<\"\$out\" && grep -q 'login refused: check the PIA username and password' <<<\"\$out\" && ! grep -q addKey $WORK/calls" "$out"
  check "pia-vpn does not retry a refused login (exit 3)" "grep -qx 'RestartPreventExitStatus=3' pia-vpn.service"
  rm -f "$WORK/login-401"

  out=$(run_nm "$ROOT/ca.rsa.4096.crt" uk --pihole)
  check "--pihole connects and keeps the LAN's DNS" \
    "grep -q 'rc=0' <<<\"\$out\" && ! grep -q 'dns-priority' $WORK/calls" "$out"

  touch "$WORK/ks"
  out=$(run_nm "$ROOT/ca.rsa.4096.crt" connect)
  dns_line=$(grep -n 'nft add element inet pia_ks dns' "$WORK/calls" | head -1 | cut -d: -f1)
  api_line=$(grep -n 'nft add element inet pia_ks api' "$WORK/calls" | head -1 | cut -d: -f1)
  check "killswitch on: the network's DNS servers are let through first" \
    "grep -q 'nft add element inet pia_ks dns { .*192.168.1.1.*}' $WORK/calls && grep -q 'dns { .*9.9.9.9' $WORK/calls && (( ${dns_line:-99} < ${api_line:-0} ))" \
    "$(grep nft "$WORK/calls")"
  check "killswitch on: then PIA's API hosts and the chosen server" \
    "grep -q 'nft add element inet pia_ks api { 192.0.2.80 }' $WORK/calls && grep -q 'nft add element inet pia_ks servers { 192.0.2.10 }' $WORK/calls" \
    "$(grep nft "$WORK/calls")"

  echo "not PIA's CA" > "$WORK/fake-ca.crt"
  out=$(run_nm "$WORK/fake-ca.crt" connect)
  check "a CA certificate that is not PIA's stops the connect before any request" \
    "grep -q 'rc=1' <<<\"\$out\" && grep -q 'not PIA.s CA certificate' <<<\"\$out\" && ! grep -q '^curl' $WORK/calls" "$out"
  check "the shipped CA matches the hash pia-nm checks" \
    "[[ \$(sha256sum < ca.rsa.4096.crt | cut -d' ' -f1) == \$(sed -n 's/^CA_SHA256=//p' pia-nm) ]]"

  servers_with '(.regions[] | select(.id == "uk") | .servers.wg[0].ip) |= "192.0.2.10 }; add chain inet pia_ks injected"'
  out=$(run_nm "$ROOT/ca.rsa.4096.crt" connect)
  check "a server address that is not an IPv4 address is refused (nft injection)" \
    "grep -q 'rc=1' <<<\"\$out\" && grep -q 'unexpected server address' <<<\"\$out\" && ! grep -q 'add element inet pia_ks servers' $WORK/calls && ! grep -q addKey $WORK/calls" \
    "$out"
  servers_with '(.regions[] | select(.id == "uk") | .servers.wg[0].cn) |= "test-server:1/x?"'
  out=$(run_nm "$ROOT/ca.rsa.4096.crt" connect)
  check "a malformed server name is refused" "grep -q 'rc=1' <<<\"\$out\" && ! grep -q addKey $WORK/calls" "$out"
  rm -f "$WORK/ks"

  cp "$FIX/servers.json" "$WORK/servers-now.json"
  "$JQ" -c '.server_key = "a2tra2tra2tra2tra2tra2tra2tra2tra2tra2tra2s=\n[Peer]\nPublicKey = x"' <<<"$GOOD_KEY" > "$WORK/addkey.json"
  out=$(run_nm "$ROOT/ca.rsa.4096.crt" connect)
  check "an addKey answer that would add lines to the WireGuard config is refused" \
    "grep -q 'rc=1' <<<\"\$out\" && grep -q 'unexpected answer from addKey' <<<\"\$out\" && ! grep -q 'nmcli connection import' $WORK/calls" "$out"
  for bad in '.peer_ip = "10.1.2.3/8"' '.server_port = "1337\nx"' '.dns_servers = ["10.0.0.243; x"]'; do
    "$JQ" -c "$bad" <<<"$GOOD_KEY" > "$WORK/addkey.json"
    out=$(run_nm "$ROOT/ca.rsa.4096.crt" connect)
    check "addKey answer refused: $bad" "grep -q 'unexpected answer from addKey' <<<\"\$out\"" "$out"
  done
  echo "$GOOD_KEY" > "$WORK/addkey.json"

  # The bar would render markup in a name as rich text, and quotes break the
  # JSON pia-toggle prints for it.
  servers_with '(.regions[] | select(.id == "uk") | .name) |= "UK <img src=\"http://x/\">Lon&don\\\\ \"q\""'
  out=$(run_nm "$ROOT/ca.rsa.4096.crt" connect)
  bad_chars=$(grep -E '^status: NAME=' <<<"$out" | grep -c '[<>&"]')
  check "markup and quotes are dropped from the region name in the status file" \
    "grep -q 'rc=0' <<<\"\$out\" && grep -q 'status: NAME=' <<<\"\$out\" && [[ $bad_chars == 0 ]]" "$out"
  check "markup, quotes and backslashes are dropped from the region list" \
    "grep -qP '^uk: uk\tUK img src=http://x/London q\tGB$' <<<\"\$out\"" "$out"
  servers_with '.regions += [{"id": "../evil", "name": "Evil", "country": "XX", "servers": {"wg": [{"ip": "192.0.2.99", "cn": "e"}]}}]'
  out=$(run_nm "$ROOT/ca.rsa.4096.crt" --list)
  check "a malformed region id never reaches the region list" "! grep -q 'evil' <<<\"\$out\" && grep -q 'regions: 215' <<<\"\$out\"" "$out"

  # --check on a healthy tunnel refreshes the bar's region list when it is old.
  cp "$FIX/servers.json" "$WORK/servers-now.json"
  out=$(REGIONS_AGE="7 hours ago" run_nm "$ROOT/ca.rsa.4096.crt" --check)
  check "--check refreshes a region list older than 6 hours" "grep -q 'rc=0' <<<\"\$out\" && grep -q 'regions: 215' <<<\"\$out\"" "$out"
  out=$(REGIONS_AGE="1 hour ago" run_nm "$ROOT/ca.rsa.4096.crt" --check)
  check "--check leaves a recent region list alone" "grep -q 'rc=0' <<<\"\$out\" && grep -q 'regions: 1$' <<<\"\$out\" && ! grep -q serverlist $WORK/calls" "$out"
  out=$(run_nm "$ROOT/ca.rsa.4096.crt" --check)
  check "--check fetches a missing region list" "grep -q 'regions: 215' <<<\"\$out\"" "$out"
  stub "$C" curl 'case "$*" in *serverlist*) exit 7;; esac; exit 0'
  out=$(REGIONS_AGE="7 hours ago" run_nm "$ROOT/ca.rsa.4096.crt" --check)
  check "a failed refresh does not fail a healthy --check" "grep -q 'rc=0' <<<\"\$out\" && grep -q 'could not refresh' <<<\"\$out\"" "$out"
else
  skp "pia-nm connect and --check" "needs passwordless sudo and jq"
fi

# ---------------------------------------------------------------------------
# What pia-nm writes for curl must come back out exactly, whatever the password.
section "curl config quoting (real curl, local HTTP server)"
cat > "$WORK/echo-http.py" <<'PY'
import http.server, json, sys, threading, urllib.parse, email.parser, email.policy
seen = {}
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        seen.update(urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)); self.reply()
    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"]))
        msg = email.parser.BytesParser(policy=email.policy.HTTP).parsebytes(
            b"Content-Type: " + self.headers["Content-Type"].encode() + b"\r\n\r\n" + body)
        for part in msg.iter_parts():
            seen.setdefault(part.get_param("name", header="content-disposition"), []).append(
                part.get_payload(decode=True).decode())
        self.reply()
    def reply(self):
        self.send_response(200); self.end_headers(); self.wfile.write(b"{}")
srv = http.server.HTTPServer(("127.0.0.1", 0), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
print(srv.server_port, flush=True)
sys.stdin.readline()          # the shell says when its requests are done
print(json.dumps(seen), flush=True)
PY
eval "$(sed -n '/^curl_opt()/,/^}/p' pia-nm)"
if declare -F curl_opt >/dev/null; then
  coproc SRV { python3 -I "$WORK/echo-http.py"; }
  read -r port <&"${SRV[0]}"
  U='us"er\name' P=$'p\\a"s s\t\'<@;$(x)\nnext\r=%&+# '
  { curl_opt form-string "username=$U"; curl_opt form-string "password=$P"; } |
    curl -fsS -K - "http://127.0.0.1:$port/token" >/dev/null
  curl_opt data-urlencode "pt=$P" | curl -fsS -G -K - --data-urlencode "pubkey=PUB" \
    "http://127.0.0.1:$port/addKey" >/dev/null
  echo >&"${SRV[1]}"; read -r seen <&"${SRV[0]}"; wait "$SRV_PID" 2>/dev/null
  verdict=$(python3 -I -c '
import json, sys; s = json.loads(sys.argv[1]); u, p = sys.argv[2], sys.argv[3]
print("ok" if s.get("username") == [u] and s.get("password") == [p] else "FAIL")
print("ok" if s.get("pt") == [p] and s.get("pubkey") == ["PUB"] else "FAIL")' "$seen" "$U" "$P")
  check "form fields arrive byte for byte" "[[ \$(sed -n 1p <<<\"\$verdict\") == ok ]]" "$seen"
  check "url-encoded query arrives byte for byte" "[[ \$(sed -n 2p <<<\"\$verdict\") == ok ]]" "$seen"
else
  bad "curl_opt is defined in pia-nm"
fi

# ---------------------------------------------------------------------------
section "killswitch (private network namespace)"
# nft usually lives in /usr/sbin, which is not on every user's PATH.
NFT=${NFT:-$(PATH=$PATH:/usr/sbin:/sbin command -v nft || true)}
if can_sudo && [[ -n $NFT ]]; then
  out=$(sudo unshare -m -n bash -c "
    mkdir -p /etc/pia && mount -t tmpfs tmpfs /etc/pia
    ip link set lo up; ip link add d0 type dummy; ip addr add 10.20.0.5/16 dev d0; ip link set d0 up
    ip route add default dev d0
    probe() { ping -c1 -W1 \$1 2>&1 | grep -qiE 'not permitted|prohibited' && echo blocked || echo allowed; }
    echo \"control=\$(probe 198.51.100.1)\"
    echo 'LAN=\"192.168.50.0/24, 10.20.0.0/16\"' > /etc/pia/pia.env
    $NFT -f <(./pia-killswitch print) && echo loaded
    $NFT -f <(./pia-killswitch print) && echo reloaded
    echo \"lan=\$(probe 10.20.0.9) other=\$(probe 10.30.0.9) internet=\$(probe 198.51.100.1)\"
    echo 'LAN=' > /etc/pia/pia.env; $NFT -f <(./pia-killswitch print)
    echo \"default_private=\$(probe 10.30.0.9) default_internet=\$(probe 198.51.100.1)\"
    $NFT add element inet pia_ks servers '{ 198.51.100.1 }'
    echo \"server=\$(probe 198.51.100.1)\"
    ip link add pia type dummy; ip link set pia up; ip route replace default dev pia
    echo \"tunnel=\$(probe 203.0.113.1)\"
  " 2>&1)
  check "without the killswitch the internet is reachable (control)" "grep -q 'control=allowed' <<<\"\$out\"" "$out"
  check "rules load and reload" "grep -q loaded <<<\"\$out\" && grep -q reloaded <<<\"\$out\"" "$out"
  check "listed LANs reachable, others and internet blocked" \
    "grep -q 'lan=allowed other=blocked internet=blocked' <<<\"\$out\"" "$out"
  check "empty LAN allows private ranges only" \
    "grep -q 'default_private=allowed default_internet=blocked' <<<\"\$out\"" "$out"
  check "the chosen PIA server is reachable while connecting" "grep -q 'server=allowed' <<<\"\$out\"" "$out"
  check "traffic through the tunnel passes" "grep -q 'tunnel=allowed' <<<\"\$out\"" "$out"
else
  skp "killswitch" "needs passwordless sudo and nft (set NFT=)"
fi

# ---------------------------------------------------------------------------
section "killswitch: holes while connecting, and a broken pia.env (private network namespace)"
# sock-probe.py tcp|udp <ip> <port> <uid>: "allowed" if the packet left (a
# dummy interface never answers), "blocked" if the killswitch refused it.
cat > "$WORK/sock-probe.py" <<'PY'
import os, socket, sys
proto, ip, port, uid = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
os.setgid(uid); os.setuid(uid)
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM if proto == "tcp" else socket.SOCK_DGRAM)
s.settimeout(1)
try:
    s.connect((ip, port))
    if proto == "udp":
        s.send(b"x"); s.recv(64)
    print("allowed")
except socket.timeout:
    print("allowed")
except OSError as e:
    print("blocked" if e.errno in (1, 13, 111, 113) else "error-%d" % e.errno)
PY
if can_sudo && [[ -n $NFT ]]; then
  out=$(sudo unshare -m -n bash -c "
    export PATH=${NFT%/*}:\$PATH
    mkdir -p /etc/pia && mount -t tmpfs tmpfs /etc/pia
    ip link set lo up; ip link add d0 type dummy; ip addr add 10.20.0.5/16 dev d0; ip link set d0 up
    ip route add default dev d0
    p() { python3 -I $WORK/sock-probe.py \"\$@\"; }
    echo 'LAN=\"192.168.50.0/24\"' > /etc/pia/pia.env; ./pia-killswitch on >/dev/null
    nft add element inet pia_ks api '{ 198.51.100.7 }'; nft add element inet pia_ks dns '{ 198.51.100.9 }'
    echo \"api_root=\$(p tcp 198.51.100.7 443 0) api_user=\$(p tcp 198.51.100.7 443 65534) api_port80=\$(p tcp 198.51.100.7 80 0)\"
    echo \"dns_udp=\$(p udp 198.51.100.9 53 65534) dns_tcp=\$(p tcp 198.51.100.9 53 1000) dns_other_port=\$(p udp 198.51.100.9 54 0) other_dns=\$(p udp 198.51.100.10 53 0)\"
    echo \"api_timeout=\$(nft list set inet pia_ks api | grep -o 'timeout [0-9a-z]*' | head -1) dns_timeout=\$(nft list set inet pia_ks dns | grep -o 'timeout [0-9a-z]*' | head -1)\"
    # A typo in LAN= and an unquoted list: the killswitch still loads.
    echo 'LAN=\"192.168.50.0/24, not-a-network\"' > /etc/pia/pia.env
    ./pia-killswitch on 2>&1 | sed 's/^/typo: /'
    echo \"typo_status=\$(./pia-killswitch status) typo_private=\$(p udp 10.30.0.9 9 0) typo_internet=\$(p udp 198.51.100.1 9 0)\"
    ./pia-killswitch off >/dev/null
    printf 'REGION=uk\nLAN=192.168.50.0/24, 10.30.0.0/16\nKS_FORWARD=1\n' > /etc/pia/pia.env
    ./pia-killswitch on 2>&1 | sed 's/^/unquoted: /'
    echo \"unquoted_status=\$(./pia-killswitch status) unquoted_internet=\$(p udp 198.51.100.1 9 0)\"
  " 2>&1)
  check "PIA's API addresses are open to root on 443" "grep -q 'api_root=allowed' <<<\"\$out\"" "$out"
  check "PIA's API addresses stay closed to other users" "grep -q 'api_user=blocked' <<<\"\$out\"" "$out"
  check "PIA's API addresses are open on 443 only" "grep -q 'api_port80=blocked' <<<\"\$out\"" "$out"
  check "the network's DNS servers are reachable on port 53 (udp and tcp) while connecting" \
    "grep -q 'dns_udp=allowed dns_tcp=allowed' <<<\"\$out\"" "$out"
  check "only on port 53, and only the servers in the set" \
    "grep -q 'dns_other_port=blocked other_dns=blocked' <<<\"\$out\"" "$out"
  check "the DNS hole closes after 2 minutes, the API one after 10" \
    "grep -q 'api_timeout=timeout 10m dns_timeout=timeout 2m' <<<\"\$out\"" "$out"
  check "a typo in LAN= falls back to all private ranges, still blocking" \
    "grep -q 'typo: pia-killswitch: LAN=.*refused' <<<\"\$out\" && grep -q 'typo_status=on typo_private=allowed typo_internet=blocked' <<<\"\$out\"" "$out"
  check "an unquoted LAN list in pia.env still loads the killswitch" \
    "grep -q 'unquoted_status=on unquoted_internet=blocked' <<<\"\$out\"" "$out"
else
  skp "killswitch holes" "needs passwordless sudo and nft (set NFT=)"
fi

# ---------------------------------------------------------------------------
section "killswitch: forwarded VM/container traffic (private network namespaces)"
# A VM ("vm", behind podman9, an interface the killswitch does not list), an
# internet host ("inet") behind the physical uplink u0, and later a tunnel
# "pia" to the same host. conntrack is already running, as it is under ufw or
# Docker, so a flow opened before the killswitch counts as established.
cat > "$WORK/udp-echo.py" <<'PY'
# One socket per address, so each reply leaves from the address it was sent to.
import select, socket, sys
socks = []
for ip in sys.argv[1:]:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.bind((ip, 9999)); socks.append(s)
while True:
    for s in select.select(socks, [], [])[0]:
        d, a = s.recvfrom(64); s.sendto(d, a)
PY
cat > "$WORK/udp-send.py" <<'PY'
import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("0.0.0.0", int(sys.argv[2]))); s.settimeout(1)
s.sendto(b"x", (sys.argv[1], 9999))
try: s.recvfrom(64); print("reply")
except OSError: print("none")
PY
if can_sudo && [[ -n $NFT ]]; then
  out=$(sudo unshare -m -n bash -c "
    mkdir -p /etc/pia /run/netns && mount -t tmpfs tmpfs /etc/pia && mount -t tmpfs tmpfs /run/netns
    echo 'LAN=\"192.168.50.0/24\"' > /etc/pia/pia.env
    ip link set lo up; ip netns add vm; ip netns add inet
    ip link add podman9 type veth peer name eth0 netns vm
    ip link add u0 type veth peer name eth0 netns inet
    ip addr add 10.99.0.1/24 dev podman9; ip link set podman9 up
    ip addr add 198.51.100.254/24 dev u0; ip link set u0 up
    ip route add default via 198.51.100.1
    for n in vm inet; do ip -n \$n link set lo up; ip -n \$n link set eth0 up; done
    ip -n vm addr add 10.99.0.2/24 dev eth0; ip -n vm route add default via 10.99.0.1
    ip -n inet addr add 198.51.100.1/24 dev eth0; ip -n inet route add 10.99.0.0/24 via 198.51.100.254
    ip -n inet addr add 203.0.113.1/32 dev lo
    sysctl -qw net.ipv4.ip_forward=1
    $NFT -f - <<<'table inet other { chain other_forward { type filter hook forward priority 10; ct state established accept; }; }'
    ip netns exec inet python3 -I $WORK/udp-echo.py 198.51.100.1 203.0.113.1 & echo_pid=\$!; sleep 0.5
    send() { ip netns exec vm python3 -I $WORK/udp-send.py \$1 \$2; }
    echo \"before=\$(send 198.51.100.1 40000)\"
    $NFT -f <(./pia-killswitch print)
    echo \"established=\$(send 198.51.100.1 40000) new=\$(send 198.51.100.1 40001)\"
    ip link add pia type veth peer name eth1 netns inet
    ip addr add 10.200.0.2/30 dev pia; ip link set pia up
    # 203.0.113.1 is reachable only by the default route, so only through pia
    ip -n inet addr add 10.200.0.1/30 dev eth1
    ip -n inet link set eth1 up
    ip route replace default via 10.200.0.1 dev pia
    ip -n inet route replace 10.99.0.0/24 via 10.200.0.2
    echo \"tunnel=\$(send 203.0.113.1 40002)\"
    kill \$echo_pid
  " 2>&1)
  check "a VM reaches the internet without the killswitch (control)" "grep -q 'before=reply' <<<\"\$out\"" "$out"
  check "an established VM flow over the uplink is cut when the killswitch comes on" \
    "grep -q 'established=none' <<<\"\$out\"" "$out"
  check "a new VM flow over the uplink is blocked" "grep -q 'new=none' <<<\"\$out\"" "$out"
  check "a VM flow through the tunnel passes, replies included" "grep -q 'tunnel=reply' <<<\"\$out\"" "$out"
else
  skp "killswitch forwarding" "needs passwordless sudo and nft (set NFT=)"
fi

printf '\n%d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skip"
(( fail == 0 ))
