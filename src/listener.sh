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
    if ! suci get uhttpd.zmweb >/dev/null; then return 0; fi
    [ "$(suci get uhttpd.zmweb)" = uhttpd ] && \
      [ "$(suci get uhttpd.zmweb.home)" = /www ] && \
      [ "$(suci get uhttpd.zmweb.index_page)" = zm-webui.html ] || fail 'Unknown separate listener; no files changed'
    [ "$(suci get uhttpd.main)" = uhttpd ] || fail 'Shared LuCI listener missing'
    suci delete uhttpd.zmweb
    suci commit uhttpd
    suci show uhttpd > "$stage/uci.after"
    sed '/^uhttpd\.zmweb[.=]/d' "$stage/uci.before" > "$stage/uci.expected"
    cmp -s "$stage/uci.expected" "$stage/uci.after" || fail 'Other server settings changed in staging'
    copy_into "$stage/uci/uhttpd" "$stage/after/etc/config/uhttpd"
}
