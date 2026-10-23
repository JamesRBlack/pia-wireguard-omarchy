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
trap 'rm -rf "$WORK"' EXIT

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

# pick: the menu returns the line for UK London
mkdir -p "$WORK/home/run"
python3 -I -c '
import json,sys
for r in json.load(open(sys.argv[1]))["regions"]: print(r["id"], r["name"], r["country"], sep="\t")' \
  "$FIX/servers.json" > "$WORK/regions.tsv"
stub "$T" pia-nm "cat $WORK/regions.tsv"
stub "$T" rofi 'grep "(uk)"'
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
cp -r "$I/all" "$I/nowg"; rm "$I/nowg/wg"
if command -v wg >/dev/null 2>&1 && [[ $(command -v wg) != "$I"/* ]]; then
  skp "names wireguard-tools when wg is missing" "a real wg is installed here"
else
  out=$(PATH=$I/nowg:/usr/bin:/bin bash -c "$pre"$'\necho PASSED' 2>&1)
  check "names wireguard-tools when wg is missing" "[[ \$out == *wireguard-tools* && \$out == *'pacman -S'* && \$out != *PASSED* ]]" "$out"
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
section "killswitch (private network namespace)"
NFT=${NFT:-$(command -v nft || true)}
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

printf '\n%d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skip"
(( fail == 0 ))
