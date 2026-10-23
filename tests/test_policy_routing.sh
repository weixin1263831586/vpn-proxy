#!/bin/bash
# Ownership and preference-allocation logic of the policy-routing layer,
# exercised against stub ip/nft binaries: no root and no real routing.
set -euo pipefail
source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf -- "$test_dir"' EXIT
S=$test_dir/net
bin=$test_dir/bin
mkdir -p "$S" "$bin" "$test_dir/firewall"
: > "$S/rules4"
: > "$S/rules6"
: > "$S/main4"
: > "$S/main6"
: > "$S/table4"
: > "$S/table6"

cat > "$bin/ip" <<'STUB'
#!/bin/bash
S=$FAKE_IP_STATE
family=4
if [[ ${1:-} == -4 || ${1:-} == -6 ]]; then family=${1#-}; shift; fi
cmd=${1:-}
shift || true
case "$cmd" in
    rule)
        sub=${1:-}
        shift || true
        case "$sub" in
            show) sort -t: -k1,1n "$S/rules$family" 2>/dev/null; exit 0 ;;
            add)
                if [[ -f "$S/fail_rule_add" ]]; then exit 1; fi
                pref='' to='' rest=''
                while [[ $# -gt 0 ]]; do
                    if [[ $1 == pref && -z "$pref" ]]; then pref=$2; shift 2
                    elif [[ $1 == to && -z "$to" ]]; then
                        to=$2
                        if [[ "$to" == *:* ]]; then to=${to%/128}; else to=${to%/32}; fi
                        shift 2
                    else rest+="$1 "; shift; fi
                done
                rest=${rest% }
                # Emit iproute2's canonical selector order: from, to, uidrange.
                if [[ -n "$to" ]]; then echo "$pref: from all to $to $rest" >> "$S/rules$family"
                else echo "$pref: from all $rest" >> "$S/rules$family"; fi
                exit 0 ;;
            del)
                pref='' rest=''
                while [[ $# -gt 0 ]]; do
                    if [[ $1 == pref && -z "$pref" ]]; then pref=$2; shift 2; else rest+="$1 "; shift; fi
                done
                rest=${rest% }
                tmp=$S/rules$family.tmp
                : > "$tmp"
                while IFS= read -r line; do
                    p=${line%%:*}
                    r=${line#*: }
                    # Real ip deletes by selector subset; unspecified parts
                    # of the rule act as wildcards.
                    if [[ $p == "$pref" && ( -z "$rest" || "$r" == "$rest" || " $r " == *" $rest "* ) ]]; then continue; fi
                    printf '%s\n' "$line" >> "$tmp"
                done < "$S/rules$family"
                mv "$tmp" "$S/rules$family"
                exit 0 ;;
        esac
        exit 1 ;;
    route)
        sub=${1:-}
        shift || true
        if [[ "$sub" == show ]]; then
            if [[ ${1:-} == table ]]; then cat "$S/table$family" 2>/dev/null; exit 0; fi
            if [[ ${1:-} == default && ${2:-} == dev ]]; then
                grep '^default ' "$S/main$family" 2>/dev/null | grep -F "dev ${3:-}" || true
                exit 0
            fi
            cat "$S/main$family" 2>/dev/null
            exit 0
        fi
        words=("$@")
        table=$S/table$family
        if [[ ${#words[@]} -ge 2 && ${words[-1]} =~ ^[0-9]+$ && ${words[-2]} == table ]]; then
            unset "words[$(( ${#words[@]} - 1 ))]" "words[$(( ${#words[@]} - 2 ))]"
        fi
        line="${words[*]}"
        case "$sub" in
            replace)
                tmp=$table.tmp
                grep -v "^${words[0]} " "$table" 2>/dev/null > "$tmp" || true
                printf '%s\n' "$line" >> "$tmp"
                mv "$tmp" "$table"
                exit 0 ;;
            add) printf '%s\n' "$line" >> "$table"; exit 0 ;;
            del)
                tmp=$table.tmp
                grep -vF "$line" "$table" 2>/dev/null > "$tmp" || true
                mv "$tmp" "$table"
                exit 0 ;;
        esac
        exit 1 ;;
esac
exit 1
STUB

cat > "$bin/nft" <<'STUB'
#!/bin/bash
S=$FAKE_NFT_STATE
echo "nft $*" >> "$S/log"
args=" $* "
if [[ "$args" == *"--stateless --numeric list table inet rk_vpn_proxy"* || "$args" == *" list table inet rk_vpn_proxy"* ]]; then
    if [[ "$args" != *"--stateless"* && "$args" == *" delete "* ]]; then exit 0; fi
    [[ -f "$S/table" ]] && { cat "$S/table"; exit 0; }
    exit 1
fi
if [[ "$args" == *"delete table inet rk_vpn_proxy"* ]]; then
    rm -f "$S/table"
    exit 0
fi
if [[ "$1" == --check || "$1" == -c ]]; then exit 0; fi
if [[ "$1" == --file || "$1" == -f ]]; then
    rm -f "$S/table"
    echo 'table inet rk_vpn_proxy {}' > "$S/table"
fi
exit 0
STUB

printf '#!/bin/bash\necho 149\n' > "$bin/id"
cat > "$bin/sleep" <<'STUB'
#!/bin/bash
# Sample the enforced marker from inside the watch loop; the daemon's EXIT
# trap legitimately clears it when the (bounded) loop ends.
if [[ -f "$FAKE_FW_STATE/enforced" ]]; then echo 1 >> "$FAKE_IP_STATE/marker_log"; else echo 0 >> "$FAKE_IP_STATE/marker_log"; fi
if [[ -f "$FAKE_IP_STATE/mutate_once" && ! -f "$FAKE_IP_STATE/mutated" ]]; then
    touch "$FAKE_IP_STATE/mutated"
    bash "$FAKE_IP_STATE/mutate_once"
fi
exit 0
STUB
chmod +x "$bin/ip" "$bin/nft" "$bin/id" "$bin/sleep"
export FAKE_IP_STATE=$S
export FAKE_NFT_STATE=$S
export FAKE_FW_STATE=$test_dir/firewall

runtime=$test_dir/runtime.env
write_runtime() {
    printf 'VPN_INTERFACE=vpn0\nPROXY_PORT=17890\nHEALTH_PORT=17891\nALLOWED_CLIENTS="%s"\n' "$1" > "$runtime"
}
fw() {
    env PATH="$bin:$PATH" RK_VPN_RUNTIME="$runtime" RK_VPN_FIREWALL_STATE="$test_dir/firewall" \
        bash "$source_dir/scripts/firewall.sh" "$@"
}
fail() { echo "FAIL: $*" >&2; exit 1; }
our_rules() { grep -F 'uidrange 149-149' "$S/rules4" 2>/dev/null || true; }
base_pref() { our_rules | grep -F 'lookup 240' | cut -d: -f1; }
client_prefs() { our_rules | grep -F 'lookup main' | cut -d: -f1 | sort -n; }
assert_invariants() {
    local expected=$1 base p max=0
    base=$(base_pref)
    [[ -n "$base" ]] || fail 'no egress (base) rule present'
    local prefs
    prefs=$(client_prefs)
    [[ $(wc -l <<<"$prefs") -eq "$expected" ]] || fail "expected $expected client rules, got $(wc -l <<<"$prefs")"
    for p in $prefs; do
        (( p < base )) || fail "client pref $p does not sort before egress rule pref $base"
        (( p > max )) && max=$p
    done
    [[ $(uniq <<<"$prefs" | wc -l) -eq "$expected" ]] || fail 'duplicate client preferences'
}
seed_vpn() {
    printf 'default via 203.0.113.1 dev vpn0 metric 50\n' > "$S/main4"
}

echo '== apply allocates preferences that skip foreign rules =='
seed_vpn
echo '91: from 10.0.0.0/8 lookup 50' >> "$S/rules4"
write_runtime '10.1.0.0/24 10.2.0.0/24'
fw --apply
assert_invariants 2
grep -qxF '90: from all to 10.1.0.0/24 uidrange 149-149 lookup main' "$S/rules4" || fail 'first client not at 90'
grep -qxF '92: from all to 10.2.0.0/24 uidrange 149-149 lookup main' "$S/rules4" || fail 'second client did not skip foreign pref 91'
grep -qxF '93: from all uidrange 149-149 lookup 240' "$S/rules4" || fail 'egress rule not behind both clients'
grep -qxF '91: from 10.0.0.0/8 lookup 50' "$S/rules4" || fail 'foreign rule was modified'
grep -qxF 'default via 203.0.113.1 dev vpn0 metric 100' "$S/table4" || fail 'VPN default not mirrored'
grep -qxF 'unreachable default metric 200' "$S/table4" || fail 'unreachable fallback missing'
grep -qF 'uidrange 149-149 lookup 240' "$S/rules6" || fail 'IPv6 egress rule missing'
grep -qxF 'unreachable default metric 200' "$S/table6" || fail 'IPv6 unreachable fallback missing'
echo 'PASS: preferences skip foreign rules and keep clients before the egress rule.'

echo '== 11 and 20 client networks never collide with the egress rule =='
for count in 11 20; do
    : > "$S/rules4"; : > "$S/rules6"; : > "$S/table4"; : > "$S/table6"
    rm -f "$FAKE_NFT_STATE/table"
    seed_vpn
    networks=''
    for index in $(seq 1 "$count"); do networks+="198.18.$(( index - 1 )).0/24 "; done
    write_runtime "$networks"
    fw --apply
    assert_invariants "$count"
done
grep -qxF '110: from all uidrange 149-149 lookup 240' "$S/rules4" || fail '20-client egress rule expected at 110'
echo 'PASS: 11 and 20 client networks keep distinct, ordered preferences.'

echo '== precheck refuses routing resources the project does not own =='
state_before_rules=$(cat "$S/rules4")
state_before_table=$(cat "$S/table4")
printf '10.99.0.0/16 via 192.0.2.1\n' >> "$S/table4"
if fw --precheck; then fail 'precheck accepted a foreign route in table 240'; fi
sed -i '\|10.99.0.0/16 via 192.0.2.1|d' "$S/table4"
echo '120: from all lookup 240' >> "$S/rules4"
if fw --precheck; then fail 'precheck accepted a foreign lookup rule'; fi
sed -i '/from all lookup 240/d' "$S/rules4"
echo '150: uidrange 149-149 prohibit' >> "$S/rules4"
if fw --precheck; then fail 'precheck accepted an unknown rule using the proxy UID'; fi
sed -i '/uidrange 149-149 prohibit/d' "$S/rules4"
fw --precheck
[[ "$(cat "$S/rules4")" == "$state_before_rules" && "$(cat "$S/table4")" == "$state_before_table" ]] ||
    fail 'precheck modified routing state'
if fw --validate; then
    [[ "$(cat "$S/rules4")" == "$state_before_rules" ]] || fail '--validate touched live rules'
else
    fail '--validate rejected an owned-only state'
fi
echo 'PASS: precheck refuses foreign resources; validate stays read-only.'

echo '== cleanup removes only project-owned policy routing =='
write_runtime '10.1.0.0/24 10.2.0.0/24'
fw --apply
echo '150: uidrange 149-149 prohibit' >> "$S/rules4"
echo '120: from all lookup 240' >> "$S/rules4"
printf '10.99.0.0/16 via 192.0.2.1\n' >> "$S/table4"
# Real kernels render the IPv6 fallback with a device and pref suffix.
printf 'unreachable default dev lo metric 200 pref medium\n' >> "$S/table6"
printf 'default via fe80::1 dev vpn0 metric 100 linkdown\n' >> "$S/table6"
fw --cleanup-routing
[[ -z "$(our_rules | grep -E ' lookup (main|240)$')" ]] || fail 'owned rules survived cleanup'
grep -qxF '150: uidrange 149-149 prohibit' "$S/rules4" || fail 'cleanup deleted a foreign UID rule'
grep -qxF '120: from all lookup 240' "$S/rules4" || fail 'cleanup deleted a foreign lookup rule'
grep -qxF '10.99.0.0/16 via 192.0.2.1' "$S/table4" || fail 'cleanup deleted a foreign route'
grep -qxF 'unreachable default metric 200' "$S/table4" && fail 'owned fallback survived cleanup'
[[ -z "$(grep -F 'uidrange' "$S/rules6" || true)" ]] || fail 'IPv6 rules survived cleanup'
[[ -z "$(cat "$S/table6")" ]] || fail 'IPv6 fallback survived cleanup'
fw --cleanup
[[ ! -f "$FAKE_NFT_STATE/table" ]] || fail 'full cleanup left the nftables table'
echo 'PASS: cleanup keeps foreign rules and routes, removes owned ones.'

echo '== watch heals a deleted rule and relocates a buried egress rule =='
: > "$S/rules4"; : > "$S/rules6"; : > "$S/table4"; : > "$S/table6"
rm -f "$FAKE_NFT_STATE/table" "$FAKE_IP_STATE/mutated" "$FAKE_IP_STATE/fail_rule_add" "$S/marker_log"
seed_vpn
write_runtime '10.1.0.0/24 10.2.0.0/24'
# During iteration 1's sleep: delete one client rule and occupy the low
# slots so the healed rule must land above the egress rule, forcing the
# daemon to relocate it behind the clients. Later sleeps only sample the
# enforced marker (1 = present).
cat > "$S/mutate_once" <<'MUTATE'
set -e
rules4="${FAKE_IP_STATE}/rules4"
sed -i '/to 10.2.0.0\/24 uidrange 149-149 lookup main/d' "$rules4"
echo '91: from 192.0.2.0/24 lookup 50' >> "$rules4"
echo '93: from 192.0.2.0/24 lookup 51' >> "$rules4"
echo '94: from 192.0.2.0/24 lookup 52' >> "$rules4"
MUTATE
RK_VPN_WATCH_ITERATIONS=3 fw --watch
assert_invariants 2
grep -qxF '90: from all to 10.1.0.0/24 uidrange 149-149 lookup main' "$S/rules4" || fail 'untouched client rule changed'
healed=$(our_rules | grep -F 'to 10.2.0.0/24 uidrange 149-149 lookup main')
healed_pref=${healed%%:*}
base=$(base_pref)
(( healed_pref > 94 )) || fail "healed rule allocated at occupied low pref $healed_pref"
(( base > healed_pref )) || fail "egress rule $base not relocated behind healed rule $healed_pref"
[[ "$(cat "$S/marker_log" | tr -d '\n')" == 111 ]] || fail "enforced marker not held throughout healing: $(cat "$S/marker_log")"
[[ ! -f "$test_dir/firewall/enforced" ]] || fail 'enforced marker survived daemon exit'
echo "PASS: watch heals deleted rules (pref $healed_pref) and relocates the egress rule (pref $base)."

echo '== persistent repair failure clears the enforced marker =='
rm -f "$S/mutated" "$S/mutate_once" "$S/marker_log" "$S/fail_rule_add"
# Break the second layer only after a healthy startup: delete a client rule
# during the first sleep and make all subsequent rule additions fail.
cat > "$S/mutate_once" <<'MUTATE'
set -e
sed -i '/to 10.2.0.0\/24 uidrange 149-149 lookup main/d' "${FAKE_IP_STATE}/rules4"
touch "${FAKE_IP_STATE}/fail_rule_add"
MUTATE
watch_output=$(RK_VPN_WATCH_ITERATIONS=2 fw --watch 2>&1 || true)
[[ "$(cat "$S/marker_log" | tr -d '\n')" == 10 ]] || fail "marker not cleared while repair fails: $(cat "$S/marker_log" 2>/dev/null)"
grep -qF 'policy routing incomplete' <<<"$watch_output" || fail 'no degradation message logged'
rm -f "$S/mutated" "$S/mutate_once" "$S/marker_log" "$S/fail_rule_add"
RK_VPN_WATCH_ITERATIONS=2 fw --watch
[[ "$(cat "$S/marker_log" | tr -d '\n')" == 11 ]] || fail 'marker not restored after repair succeeds: $(cat "$S/marker_log")'
assert_invariants 2
echo 'PASS: persistent repair failure clears FIREWALL_ENFORCED; recovery restores it.'

echo '== check rejects out-of-order and stale client rules =='
rm -f "$S/mutated" "$S/marker_log"
RK_VPN_WATCH_ITERATIONS=1 fw --watch
assert_invariants 2
echo '210: from all to 10.3.0.0/24 uidrange 149-149 lookup main' >> "$S/rules4"
if fw --check; then fail 'check accepted a client rule outside the configuration'; fi
# The daemon must drop the stale return rule on its own and pass again.
rm -f "$S/marker_log"
RK_VPN_WATCH_ITERATIONS=1 fw --watch
assert_invariants 2
grep -qF 'to 10.3.0.0/24 uidrange 149-149 lookup main' "$S/rules4" && fail 'stale client rule survived watch'
fw --check
echo 'PASS: check verifies preference order and configuration match; watch drops stale rules.'

echo '== host selectors and per-family ordering =='
write_runtime '10.10.10.206/32 fd00::1/128 fd01::/32'
RK_VPN_WATCH_ITERATIONS=1 fw --watch
fw --check
grep -qF 'to 10.10.10.206 uidrange 149-149 lookup main' "$S/rules4" || fail 'IPv4 host selector missing'
grep -qF 'to fd00::1 uidrange 149-149 lookup main' "$S/rules6" || fail 'IPv6 host selector missing'
grep -qF 'to fd01::/32 uidrange 149-149 lookup main' "$S/rules6" || fail 'IPv6 /32 was shortened'
sed -i 's/^[0-9]*: from all uidrange 149-149 lookup 240/89: from all uidrange 149-149 lookup 240/' "$S/rules6"
if fw --check; then fail 'check accepted IPv6 egress before client rules'; fi
echo 'PASS: host selectors normalize; IPv6 ordering checked independently.'

echo '== ownership matches complete UID and lookup tokens =='
fw --cleanup-routing
printf '81: from all uidrange 149-1490 lookup main\n82: from all lookup 2400\n' > "$S/rules4"
fw --precheck
fw --cleanup-routing
grep -qxF '81: from all uidrange 149-1490 lookup main' "$S/rules4" || fail 'deleted another UID range'
grep -qxF '82: from all lookup 2400' "$S/rules4" || fail 'deleted another table lookup'
echo 'PASS: similarly prefixed UID ranges and table numbers are preserved.'

echo 'ALL POLICY-ROUTING STUB TESTS PASSED'
