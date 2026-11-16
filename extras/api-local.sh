#!/bin/sh
# Optional, explicit restriction: preserve local API users, reject remote TCP 9090.
set -eu
. /etc/zm-local-ui/lib.sh
require_root
OWN=/etc/zm-api-local
RULE=/etc/nftables.d/95-zm-api-local.nft
MODE=${1:-install}
case "$MODE" in install|remove|status) ;; *) fail 'Use install, remove or status';; esac
if [ "$MODE" = status ]; then
    nft list chain inet fw4 zm_api_local
    exit 0
fi
for c in nft fw4 curl; do command -v "$c" >/dev/null || fail "Missing $c"; done
safe_path "$RULE"; safe_path "$OWN/owner"; safe_path "$OWN/control.sh"; safe_path "$OWN/live.txt"
if [ -d "$OWN" ] && [ ! -f "$OWN/owner" ]; then fail 'Unowned API restriction directory'; fi
acquire
stage=''; pending=''; changed=0; complete=0; existed=0; live_changed=0
cleanup_api() {
    rc=$?; trap - EXIT HUP INT TERM
    if [ "$changed" = 1 ] && [ "$complete" != 1 ]; then
        if [ "$existed" = 1 ]; then put_file "$stage/old.nft" "$RULE" || true
        else rm -f "$RULE"; fi
        # Restore only this dedicated chain, using a single nft transaction.
        if [ "$live_changed" = 1 ] && [ -f "$stage/rollback.nft" ]; then nft -f "$stage/rollback.nft" || echo 'API rule rollback failed' >&2; fi
    fi
    [ -z "$pending" ] || rm -f "$pending"
    [ -z "$stage" ] || tree_clear "$stage" || true
    release
    exit "$rc"
}
trap cleanup_api EXIT
trap 'exit 1' HUP INT TERM
stage=$(mktemp -d "$RUN/stage.XXXXXX")
printf '%s\n' "$stage" > "$RUN/lock/stage"
cat > "$stage/expected.nft" <<'NFT'
# Managed by zm-api-local: router-local API only, IPv4 and IPv6.
chain zm_api_local {
    type filter hook input priority -5; policy accept;
    iifname != "lo" tcp dport 9090 counter reject with tcp reset comment "zm-api-local"
}
NFT
has_chain=0
if nft list chain inet fw4 zm_api_local >/dev/null 2>&1; then has_chain=1; fi
if [ -f "$RULE" ]; then
    [ -f "$OWN/owner" ] && cmp -s "$RULE" "$stage/expected.nft" || fail 'Existing rule differs or has no owner; no changes'
    cp -p "$RULE" "$stage/old.nft"; existed=1
fi
if [ "$has_chain" = 1 ]; then
    [ "$existed" = 1 ] || fail 'Existing live chain has no matching managed file'
    # Refuse to overwrite a live chain whose policy was edited externally.
    nft -s list chain inet fw4 zm_api_local > "$stage/live.txt"
    cmp -s "$stage/live.txt" "$OWN/live.txt" || fail 'Live API rule was changed; no changes applied'
fi
printf '' > "$stage/rollback.nft"
if [ "$has_chain" = 1 ]; then
    printf '%s\n' 'flush chain inet fw4 zm_api_local' 'delete chain inet fw4 zm_api_local' > "$stage/rollback.nft"
    { printf '%s\n' 'table inet fw4 {'; cat "$stage/expected.nft"; printf '}\n'; } >> "$stage/rollback.nft"
fi
if [ "$MODE" = remove ]; then
    [ "$existed" = 1 ] || { echo 'No managed persistent restriction found.'; exit 0; }
    changed=1; rm -f "$RULE"
    fw4 check || fail 'Firewall validation failed; persistent file restored'
    if [ "$has_chain" = 1 ]; then
        printf '%s\n' 'flush chain inet fw4 zm_api_local' 'delete chain inet fw4 zm_api_local' > "$stage/remove.nft"
        nft -f "$stage/remove.nft"
    fi
    complete=1
    echo 'API restriction removed. Original listener settings retained.'
    exit 0
fi
nft list table inet fw4 >/dev/null || fail 'Active fw4 table is required'
lan=$(uci -q get network.lan.ipaddr || true); lan=${lan%%/*}
case "$lan" in ''|*[!0-9.]*) fail 'Cannot determine IPv4 LAN address for internal API check';; esac
code=$(curl --disable --noproxy '*' -s -o /dev/null -w '%{http_code}' --max-time 5 "http://$lan:9090/version") || fail 'Router-local API is not responding before change'
case "$code" in 200|401) ;; *) fail "Unexpected API status before change: $code";; esac
private_dir "$OWN"
printf '%s\n' zm-api-local > "$OWN/owner"
put_file "$0" "$OWN/control.sh"
put_file "$stage/expected.nft" "$RULE"
changed=1
fw4 check || fail 'Firewall validation failed; no live rule applied'
if [ "$has_chain" = 1 ]; then printf '%s\n' 'flush chain inet fw4 zm_api_local' 'delete chain inet fw4 zm_api_local' > "$stage/apply.nft"
else
    : > "$stage/apply.nft"
    printf '%s\n' 'flush chain inet fw4 zm_api_local' 'delete chain inet fw4 zm_api_local' > "$stage/rollback.nft"
fi
{ printf '%s\n' 'table inet fw4 {'; cat "$stage/expected.nft"; printf '}\n'; } >> "$stage/apply.nft"
nft -c -f "$stage/apply.nft" || fail 'nft syntax check failed'
nft -f "$stage/apply.nft"
live_changed=1
after=$(curl --disable --noproxy '*' -s -o /dev/null -w '%{http_code}' --max-time 5 "http://$lan:9090/version") || fail 'Internal API failed after change'
[ "$after" = "$code" ] || fail 'Internal API response changed; restoring rule'
nft -s list chain inet fw4 zm_api_local > "$OWN/live.txt"
printf '%s\n' zm-api-local > "$OWN/owner"
sync
complete=1
echo 'DONE: remote TCP 9090 blocked on all interfaces; router-local API verified.'
echo 'No sing-box, nfqws or network-service restart performed.'
echo 'Persistent across fw4 reloads and normal Manager updates.'
echo 'Undo: sh /etc/zm-api-local/control.sh remove'
