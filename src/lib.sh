#!/bin/sh
# Local addon only. Never source configuration or code from the Manager.
BASE=/etc/zm-local-ui
RUN=/tmp/zm-local-ui-run
VIEW=www/luci-static/resources/view/zapret-manager
MENU=usr/share/luci/menu.d/luci-app-zapret-manager.json
BACKUP=$BASE/backup-v3
umask 077
export LC_ALL=C
fail() { echo "ERROR: $*" >&2; exit 1; }
require_root() { [ "$(id -u)" = 0 ] || fail 'Run as root'; }
safe_path() {
    # Check every ancestor, including dangling links. RAM/USB symlink layouts
    # deliberately require a separate implementation.
    sp=$1
    case "$sp" in /*) ;; *) fail "Not an absolute path: $sp";; esac
    while [ "$sp" != / ]; do
        [ ! -L "$sp" ] || fail "Symlink layout is unsupported: $sp"
        sp=${sp%/*}; [ -n "$sp" ] || sp=/
    done
    [ ! -e "$1" ] || [ -f "$1" ] || fail "Not a regular file: $1"
}
private_dir() {
    pd=$1
    [ ! -L "$pd" ] || fail "Symlink directory: $pd"
    [ -d "$pd" ] || mkdir -m 700 "$pd"
    # Minimal OpenWrt builds may omit stat entirely. Numeric ls is a BusyBox
    # baseline; inspect only metadata fields, never parse the filename.
    metadata=$(ls -nd "$pd") || fail "Cannot read directory metadata: $pd"
    printf '%s\n' "$metadata" | awk '
      NR != 1 { bad=1 }
      NR == 1 {
        if ($3 != "0" || substr($1,1,1) != "d" || length($1) < 10 ||
            substr($1,6,1) != "-" || substr($1,9,1) != "-") bad=1
      }
      END { exit (bad || NR != 1) }
    ' || fail "Directory must belong to root and deny writes to other users: $pd"
    case "$metadata" in drwx------\ *) ;; *) chmod 700 "$pd";; esac
}
acquire() {
    require_root
    private_dir "$RUN"
    if ! mkdir "$RUN/lock" 2>/dev/null; then
        lp=$(cat "$RUN/lock/pid" 2>/dev/null || true)
        case "$lp" in ''|*[!0-9]*) fail 'Cleanup lock is incomplete; retry or reboot';; esac
        if kill -0 "$lp" 2>/dev/null; then fail 'Another local cleanup is running'; fi
        orphan=$(cat "$RUN/lock/stage" 2>/dev/null || true)
        [ -z "$orphan" ] || tree_clear "$orphan" || fail 'Unexpected orphan staging directory'
        rm -f "$RUN/lock/pid" "$RUN/lock/stage"; rmdir "$RUN/lock" || fail 'Invalid lock directory'
        mkdir "$RUN/lock" || fail 'Cleanup lock is busy'
    fi
    printf '%s\n' "$$" > "$RUN/lock/pid"
}
release() { rm -f "$RUN/lock/pid" "$RUN/lock/stage"; rmdir "$RUN/lock" 2>/dev/null || true; }
allowed() {
    case "$1" in
        etc/config/uhttpd|usr/share/luci/menu.d/luci-app-zapret-manager.json|\
        opt/zapret-manager-luci/backend.sh|opt/zapret-manager-luci/mod/system.sh|\
        usr/libexec/rpcd/zapret-manager|usr/share/rpcd/acl.d/luci-app-zapret-manager.json|\
        www/luci-static/resources/zapret-manager/common.js|\
        www/luci-static/resources/view/zapret-manager/style.css|\
        www/zm-webui.html|www/zm/app.js|www/zm/app.css|www/zm/theme.txt|www/zm/look.json|www/zm/https.txt|\
        opt/zapret-manager-luci/state/webui|opt/zapret-manager-luci/state/webui.html) return 0;;
        www/luci-static/resources/view/zapret-manager/*.js)
            an=${1##*/}
            case "$an" in ''|*[!a-zA-Z0-9_.-]*) return 1;; esac
            [ "$1" = "$VIEW/$an" ] && return 0;;
    esac
    return 1
}
paths() {
    printf '%s\n' "$MENU" "$VIEW/style.css" \
      opt/zapret-manager-luci/backend.sh opt/zapret-manager-luci/mod/system.sh \
      usr/libexec/rpcd/zapret-manager usr/share/rpcd/acl.d/luci-app-zapret-manager.json \
      www/luci-static/resources/zapret-manager/common.js etc/config/uhttpd \
      www/zm-webui.html www/zm/app.js www/zm/app.css www/zm/theme.txt www/zm/look.json www/zm/https.txt \
      opt/zapret-manager-luci/state/webui opt/zapret-manager-luci/state/webui.html
    for pp in /www/luci-static/resources/view/zapret-manager/*.js; do
        [ ! -e "$pp" ] && [ ! -L "$pp" ] && continue
        printf '%s\n' "${pp#/}"
    done
}
state() {
    # Stable sorted state also records absent files. Hash failures propagate.
    state_root=$1; state_paths=$2; state_out=$3
    : > "$state_out"
    while IFS= read -r rel; do
        allowed "$rel" || fail "Unexpected managed path: $rel"
        safe_path "$state_root/$rel"
        if [ -f "$state_root/$rel" ]; then
            shash=$(sha256sum "$state_root/$rel") || return 1
            printf '%s  %s\n' "${shash%% *}" "$rel" >> "$state_out"
        else printf 'MISSING  %s\n' "$rel" >> "$state_out"; fi
    done < "$state_paths"
}
file_value() {
    if [ -f "$1" ]; then fv=$(sha256sum "$1") || return 1; printf '%s\n' "${fv%% *}"
    else printf '%s\n' MISSING; fi
}
record_value() { awk -v p="$2" '$2 == p { print $1; found=1; exit } END { if (!found) exit 1 }' "$1"; }
copy_into() {
    ci_src=$1; ci_dest=$2
    mkdir -p "${ci_dest%/*}"
    cp -p "$ci_src" "$ci_dest"
}
put_file() {
    # pending is handled by the caller's EXIT trap.
    pf_src=$1; pf_dest=$2
    safe_path "$pf_dest"
    [ -d "${pf_dest%/*}" ] || mkdir -p "${pf_dest%/*}"
    pending=$(mktemp "$pf_dest.zml.XXXXXX") || return 1
    cp -p "$pf_src" "$pending" || return 1
    mv -f "$pending" "$pf_dest" || return 1
    pending=''
}
tree_clear() {
    # Only our freshly created private tree. Never call against a live tree.
    case "$1" in "$RUN"/stage.??????|"$BASE"/backup-new|"$BASE"/backup-old|"$BASE"/first-snapshot-new) ;; *) return 1;; esac
    [ ! -L "$1" ] || return 1
    [ ! -d "$1" ] || { find "$1" -type f -exec rm -f '{}' \; && find "$1" -depth -type d -exec rmdir '{}' \;; }
}
clear_cache() {
    for cc in /tmp/luci-indexcache* /tmp/luci-modulecache/*; do
        [ ! -f "$cc" ] || [ -L "$cc" ] || rm -f "$cc" || true
    done
}
reload_changed() {
    # These are administrative UI processes, never nfqws/sing-box/DNS/firewall.
    if grep -qx 'etc/config/uhttpd' "$1"; then /etc/init.d/uhttpd reload || return 1; fi
    if grep -qE '^usr/(libexec/rpcd/|share/rpcd/acl.d/)' "$1"; then /etc/init.d/rpcd reload || return 1; fi
    clear_cache
}
cron_read() {
    if ! crontab -l > "$1" 2>/dev/null; then
        [ ! -e /etc/crontabs/root ] || return 1
        : > "$1"
    fi
}
cron_edit() {
    ce_mode=$1; ce_dir=$2
    cron_read "$ce_dir/cron.before" || return 1
    grep -v ' # zm-local-ui$' "$ce_dir/cron.before" > "$ce_dir/cron.after" || [ "$?" = 1 ]
    if [ "$ce_mode" = on ]; then
        printf '%s\n' '*/5 * * * * sh /etc/zm-local-ui/apply.sh auto >/dev/null 2>&1 # zm-local-ui' >> "$ce_dir/cron.after"
    fi
    cron_read "$ce_dir/cron.now" || return 1
    cmp -s "$ce_dir/cron.before" "$ce_dir/cron.now" || fail 'Scheduled tasks changed concurrently; retry'
    cmp -s "$ce_dir/cron.before" "$ce_dir/cron.after" || crontab "$ce_dir/cron.after"
}
