#!/bin/sh
set -eu
. "$(dirname "$0")/lib.sh"
MODE=${1:-apply}
case "$MODE" in auto|apply|check|restore|recover|disable) ;; *) fail 'Use apply, check, auto, restore, recover or disable';; esac
require_root
[ "$MODE" != auto ] || [ ! -f "$BASE/disabled" ] || exit 0
safe_path "$BASE/owner-zm-local-ui"
[ -f "$BASE/owner-zm-local-ui" ] || fail 'Addon is not installed'
private_dir "$BASE"
acquire
stage=''; pending=''; modified=0; committed=0; rollback_failed=0
was_pending=0; [ ! -f "$BACKUP/pending" ] || was_pending=1
cleanup() {
    rc=$?
    trap - EXIT HUP INT TERM
    [ -z "$pending" ] || rm -f "$pending"
    if [ "$modified" = 1 ] && [ "$committed" != 1 ]; then
        # Restore only files still equal to our write. Do not overwrite a newer
        # Manager update that raced us; keep the recovery journal in that case.
        while IFS= read -r rel; do
            safe_path "/$rel"
            current=$(file_value "/$rel") || { rollback_failed=1; continue; }
            old=$(record_value "$stage/before.state" "$rel")
            new=$(record_value "$stage/after.state" "$rel")
            [ "$current" != "$old" ] || continue
            if [ "$current" != "$new" ]; then rollback_failed=1; continue; fi
            if [ "$old" = MISSING ]; then rm -f "/$rel" || rollback_failed=1
            else put_file "$stage/before/$rel" "/$rel" || rollback_failed=1; fi
        done < "$stage/changed"
        reload_changed "$stage/changed" || rollback_failed=1
        if [ "$rollback_failed" = 0 ]; then
            [ "$was_pending" = 1 ] || rm -f "$BACKUP/pending"
            echo 'Operation failed; files restored to their previous contents.' >&2
        else echo 'Automatic recovery incomplete. Preserve backup-v3 and run apply.sh recover.' >&2; fi
    fi
    [ -z "$pending" ] || rm -f "$pending"
    if [ "$rc" != 0 ]; then
        if [ -z "$stage" ] || [ ! -f "$stage/input" ] || ! cmp -s "$stage/input" "$RUN/failed"; then
            logger -t zm-local-ui 'Local cleanup failed/skipped. Run sh /etc/zm-local-ui/apply.sh check for details.' || true
            [ -z "$stage" ] || [ ! -f "$stage/input" ] || cp "$stage/input" "$RUN/failed" || true
        fi
    fi
    [ -z "$stage" ] || tree_clear "$stage" || true
    release
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
stage=$(mktemp -d "$RUN/stage.XXXXXX")
printf '%s\n' "$stage" > "$RUN/lock/stage"

if [ "$MODE" = disable ]; then
    : > "$BASE/disabled"; cron_edit off "$stage"
    echo 'Local cleanup disabled; installed files unchanged.'; exit 0
fi
if [ "$MODE" = restore ] || [ "$MODE" = recover ]; then
    # Disable first, but never begin a partial restore before checking all files.
    : > "$BASE/disabled"; cron_edit off "$stage"
    [ -d "$BACKUP" ] && [ ! -L "$BACKUP" ] || fail 'No revision 3 backup; cleanup disabled'
    for f in paths changed before.state after.state before.tar.gz; do
        safe_path "$BACKUP/$f"; [ -f "$BACKUP/$f" ] || fail 'Incomplete backup'
        cp "$BACKUP/$f" "$stage/$f"
    done
    while IFS= read -r rel; do allowed "$rel" || fail 'Unexpected backup path'; safe_path "/$rel"; done < "$stage/paths"
    state '' "$stage/paths" "$stage/current.state"
    if [ "$MODE" = restore ]; then
        cmp -s "$stage/current.state" "$stage/after.state" || fail 'Manager changed after cleanup; no old version restored'
    else
        [ -f "$BACKUP/pending" ] || fail 'No interrupted transaction to recover'
        while read -r value rel; do
            old=$(record_value "$stage/before.state" "$rel")
            new=$(record_value "$stage/after.state" "$rel")
            [ "$value" = "$old" ] || [ "$value" = "$new" ] || fail 'Manager changed during interruption; manual recovery required'
        done < "$stage/current.state"
    fi
    # Validate archive member names AND types before extraction into a private tree.
    tar -tzf "$stage/before.tar.gz" > "$stage/members"
    tar -tvzf "$stage/before.tar.gz" > "$stage/types"
    awk 'substr($0,1,1) != "-" { bad=1 } END { exit bad }' "$stage/types" || fail 'Backup contains non-regular members'
    while IFS= read -r rel; do
        allowed "$rel" && grep -qxF "$rel" "$stage/changed" || fail 'Unexpected backup member'
    done < "$stage/members"
    mkdir "$stage/restore" "$stage/before" "$stage/after"
    tar -xzf "$stage/before.tar.gz" -C "$stage/restore"
    # The transaction below can also roll back a failed manual restore.
    cp "$stage/current.state" "$stage/before.state"
    cp "$BACKUP/before.state" "$stage/after.state"
    while IFS= read -r rel; do
        [ ! -f "/$rel" ] || copy_into "/$rel" "$stage/before/$rel"
        want=$(record_value "$stage/after.state" "$rel")
        if [ "$want" != MISSING ]; then
            safe_path "$stage/restore/$rel"
            [ "$(file_value "$stage/restore/$rel")" = "$want" ] || fail 'Backup content checksum mismatch'
            copy_into "$stage/restore/$rel" "$stage/after/$rel"
        fi
    done < "$stage/changed"
else
    [ ! -f "$BACKUP/pending" ] || fail 'Interrupted previous operation; run apply.sh recover first'
    paths | sort -u > "$stage/paths"
    state '' "$stage/paths" "$stage/before.state"
    sha256sum "$BASE/"*.sh "$BASE/"*.uc "$BASE/"*.json "$BASE/lite.css" "$BASE/credits-head.js" "$BASE/credits-tail.js" > "$stage/policy"
    cat "$stage/before.state" "$stage/policy" > "$stage/input"
    if cmp -s "$stage/input" "$RUN/applied"; then
        [ "$MODE" = auto ] || echo 'Already applied; no live files written.'
        exit 0
    fi
    if [ "$MODE" = auto ]; then
        now=$(date +%s)
        seen=$(cat "$RUN/observed-at" 2>/dev/null || echo 0)
        case "$seen" in ''|*[!0-9]*) seen=0;; esac
        if ! cmp -s "$stage/input" "$RUN/observed"; then
            cp "$stage/input" "$RUN/observed"; printf '%s\n' "$now" > "$RUN/observed-at"; exit 0
        fi
        [ "$((now - seen))" -ge 240 ] || exit 0
    fi
    # Defer while the Manager reports a running job. Do not stop that job.
    for job in /tmp/zapret-manager-luci/*.pid; do
        [ -f "$job" ] || continue
        case "${job##*/}" in versions.pid|sysinfo.pid|fk-guard.pid) continue;; esac
        jp=$(cat "$job")
        case "$jp" in ''|*[!0-9]*) continue;; esac
        if kill -0 "$jp" 2>/dev/null; then fail 'Manager has an active task; retry after it finishes'; fi
    done
    for rel in "$MENU" "$VIEW/style.css" "$VIEW/dashboard.js" "$VIEW/system.js" \
        opt/zapret-manager-luci/backend.sh usr/libexec/rpcd/zapret-manager \
        usr/share/rpcd/acl.d/luci-app-zapret-manager.json www/luci-static/resources/zapret-manager/common.js; do
        [ -s "/$rel" ] || fail "Required Manager component missing: $rel"
    done
    # Bounded temporary footprint. No caches are dropped, no service is stopped.
    used=0
    while IFS= read -r rel; do
        [ -f "/$rel" ] || continue
        size=$(wc -c < "/$rel"); [ "$size" -le 6291456 ] || fail 'Unexpectedly large component'
        used=$((used + size))
    done < "$stage/paths"
    [ "$used" -le 16777216 ] || fail 'Manager snapshot too large for this addon'
    free=$(df -kP "$RUN" | awk 'NR == 2 {print $4}')
    [ "$free" -ge "$((used / 1024 * 4 + 2048))" ] || fail 'Insufficient temporary storage; no files changed'
    available=$(awk '/^MemAvailable:/ {print $2; exit}' /proc/meminfo)
    if [ -n "$available" ]; then
        [ "$available" -ge "$((used / 1024 * 4 + 4096))" ] || fail 'Insufficient available RAM; no files changed'
    fi
    mkdir "$stage/before" "$stage/after" "$stage/ui" "$stage/ui/old" "$stage/ui/new" "$stage/components" "$stage/components/old" "$stage/components/new"
    while IFS= read -r rel; do [ ! -f "/$rel" ] || copy_into "/$rel" "$stage/before/$rel"; done < "$stage/paths"
    state "$stage/before" "$stage/paths" "$stage/copied.state"
    cmp -s "$stage/before.state" "$stage/copied.state" || fail 'Manager changed while taking snapshot'
    cp "$stage/before/$MENU" "$stage/ui/old/menu.json"
    for n in style.css dashboard.js system.js thanks.js; do
        [ ! -f "$stage/before/$VIEW/$n" ] || cp "$stage/before/$VIEW/$n" "$stage/ui/old/$n"
    done
    for n in fragments.json lite.css credits-head.js credits-tail.js; do cp "$BASE/$n" "$stage/ui/$n"; done
    (cd "$stage/ui"; ucode "$BASE/transform.uc")
    for f in "$stage/ui/new/"*; do
        n=${f##*/}; rel="$VIEW/$n"; [ "$n" != menu.json ] || rel=$MENU
        copy_into "$stage/before/$rel" "$stage/after/$rel"; cat "$f" > "$stage/after/$rel"
    done
    id=0; sep=''; printf '[' > "$stage/components/plan.json"
    : > "$stage/components/paths"
    while IFS= read -r rel; do
        case "$rel" in opt/zapret-manager-luci/backend.sh|opt/zapret-manager-luci/mod/system.sh|usr/libexec/rpcd/zapret-manager) kind=shell;;
            usr/share/rpcd/acl.d/luci-app-zapret-manager.json) kind=json;;
            www/luci-static/resources/*.js) kind=js;; *) continue;; esac
        [ -f "$stage/before/$rel" ] || continue
        id=$((id + 1)); printf '%s{"id":"%s","kind":"%s"}' "$sep" "$id" "$kind" >> "$stage/components/plan.json"; sep=,
        printf '%s\n' "$rel" >> "$stage/components/paths"
        src="$stage/before/$rel"; [ ! -f "$stage/after/$rel" ] || src="$stage/after/$rel"
        cp "$src" "$stage/components/old/$id"
    done < "$stage/paths"
    printf ']\n' >> "$stage/components/plan.json"
    cp "$BASE/known-functions.json" "$stage/components/known-functions.json"
    (cd "$stage/components"; ucode "$BASE/luci-only.uc")
    id=0
    while IFS= read -r rel; do
        id=$((id + 1))
        case "$rel" in opt/*|usr/libexec/*) sh -n "$stage/components/new/$id";; esac
        copy_into "$stage/before/$rel" "$stage/after/$rel"
        cat "$stage/components/new/$id" > "$stage/after/$rel"
    done < "$stage/components/paths"
    . "$BASE/listener.sh"
    prepare_listener
    : > "$stage/after.state"; : > "$stage/changed"
    while IFS= read -r rel; do
        case "$rel" in www/zm/*|www/zm-webui.html|opt/zapret-manager-luci/state/webui*) value=MISSING;;
        *) src="$stage/before/$rel"; [ ! -f "$stage/after/$rel" ] || src="$stage/after/$rel"; value=$(file_value "$src");; esac
        printf '%s  %s\n' "$value" "$rel" >> "$stage/after.state"
        [ "$value" = "$(record_value "$stage/before.state" "$rel")" ] || printf '%s\n' "$rel" >> "$stage/changed"
    done < "$stage/paths"
    if [ "$MODE" = check ]; then
        echo 'PASS preparation: templates, shell/JSON, server settings and paths. No live files changed.'
        printf 'Files that would change: '; wc -l < "$stage/changed"
        exit 0
    fi
    if [ ! -s "$stage/changed" ]; then
        cp "$stage/input" "$RUN/applied"; echo 'Already clean; no live files written.'; exit 0
    fi
    tree_clear "$BASE/backup-new"
    mkdir -m 700 "$BASE/backup-new"
    : > "$stage/existing"
    while IFS= read -r rel; do [ ! -f "$stage/before/$rel" ] || printf '%s\n' "$rel" >> "$stage/existing"; done < "$stage/changed"
    tar -czf "$BASE/backup-new/before.tar.gz" -C "$stage/before" -T "$stage/existing"
    tar -tzf "$BASE/backup-new/before.tar.gz" >/dev/null
    for f in paths changed before.state after.state; do cp "$stage/$f" "$BASE/backup-new/$f"; done
    tree_clear "$BASE/backup-old"
    [ ! -d "$BACKUP" ] || mv "$BACKUP" "$BASE/backup-old"
    mv "$BASE/backup-new" "$BACKUP"
fi

# All preparation is complete. Recheck the complete snapshot and staged UCI
# changes before the first live write, and each file immediately before its write.
state '' "$stage/paths" "$stage/current.state"
cmp -s "$stage/before.state" "$stage/current.state" || fail 'Concurrent Manager update; no files applied'
pc=$(uci -q changes uhttpd) || fail 'Cannot read uhttpd changes'
[ -z "$pc" ] || fail 'Concurrent server settings change; no files applied'
: > "$BACKUP/pending"
modified=1
while IFS= read -r rel; do
    safe_path "/$rel"
    [ "$(file_value "/$rel")" = "$(record_value "$stage/before.state" "$rel")" ] || fail 'Concurrent component write'
    want=$(record_value "$stage/after.state" "$rel")
    if [ "$want" = MISSING ]; then rm -f "/$rel"
    else put_file "$stage/after/$rel" "/$rel"; fi
done < "$stage/changed"
state '' "$stage/paths" "$stage/actual.state"
cmp -s "$stage/after.state" "$stage/actual.state" || fail 'Post-write verification failed'
reload_changed "$stage/changed" || fail 'Administrative service reload failed'
committed=1
rm -f "$BACKUP/pending" "$RUN/applied" "$RUN/observed" "$RUN/observed-at" "$RUN/failed"
tree_clear "$BASE/backup-old"
if [ "$MODE" = restore ] || [ "$MODE" = recover ]; then
    while IFS= read -r rel; do
        for orphan in "/$rel".zml.??????; do
            [ ! -f "$orphan" ] || [ -L "$orphan" ] || rm -f "$orphan"
        done
    done < "$stage/changed"
    echo 'Previous files restored; local automatic cleanup remains disabled.'
else
    cat "$stage/after.state" "$stage/policy" > "$RUN/applied"
    logger -t zm-local-ui 'LuCI cleanup committed; routing/engine configs unchanged.'
    echo 'DONE: cleanup applied. Backup: /etc/zm-local-ui/backup-v3. Refresh LuCI with Ctrl+F5.'
fi
