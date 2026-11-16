#!/bin/sh
# Called only inside apply.sh's preparation phase. No live UCI writes.
prepare_listener() {
    [ -f "$stage/before/etc/config/uhttpd" ] || fail 'Missing uhttpd config'
    pending_changes=$(uci -q changes uhttpd) || fail 'Cannot read pending uhttpd changes'
    [ -z "$pending_changes" ] || fail 'Save or discard pending uhttpd settings first'
    # -c alone does NOT isolate UCI's delta store. -t keeps all our writes private.
    mkdir "$stage/uci" "$stage/delta"
    cp -p "$stage/before/etc/config/uhttpd" "$stage/uci/uhttpd"
    suci() { uci -c "$stage/uci" -t "$stage/delta" -q "$@"; }
    suci show uhttpd > "$stage/uci.before" || fail 'Cannot parse uhttpd configuration'
    # Identify the exact application, not its port or one hardcoded section name.
    # A custom listener is removed only if its document root AND unique index match.
    awk -F= '$2 == "uhttpd" {sub(/^uhttpd\./,"",$1); print $1}' "$stage/uci.before" > "$stage/uci.sections"
    cp "$stage/uci.before" "$stage/uci.expected"
    removed=0
    while IFS= read -r section; do
        index_page=$(suci get "uhttpd.$section.index_page" 2>/dev/null || true)
        home=$(suci get "uhttpd.$section.home" 2>/dev/null || true)
        if [ "$index_page" != zm-webui.html ] || [ "$home" != /www ]; then
            [ "$section" != zmweb ] || fail 'Unknown separate listener; no files changed'
            continue
        fi
        [ "$section" != main ] || fail 'Legacy application occupies shared LuCI listener; manual review required'
        case "$section" in ''|*[!a-zA-Z0-9_]*) fail 'Anonymous/nonstandard legacy listener needs review';; esac
        [ "$(suci get uhttpd.main)" = uhttpd ] || fail 'Shared LuCI listener missing'
        suci delete "uhttpd.$section"
        awk -v s="uhttpd.$section" '$0 != s "=uhttpd" && index($0,s ".") != 1' "$stage/uci.expected" > "$stage/uci.expected.new"
        mv "$stage/uci.expected.new" "$stage/uci.expected"
        removed=1
    done < "$stage/uci.sections"
    [ "$removed" = 1 ] || return 0
    suci commit uhttpd
    suci show uhttpd > "$stage/uci.after"
    cmp -s "$stage/uci.expected" "$stage/uci.after" || fail 'Other server settings changed in staging'
    copy_into "$stage/uci/uhttpd" "$stage/after/etc/config/uhttpd"
}
