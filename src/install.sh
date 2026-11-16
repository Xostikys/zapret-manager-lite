#!/bin/sh
set -eu
cd "$(dirname "$0")"
[ "$(id -u)" = 0 ] || { echo 'Run as root'; exit 1; }
for c in ucode crontab sha256sum cmp tar xargs ls mktemp uci awk sort find sync; do
    command -v "$c" >/dev/null || { echo "Missing $c; nothing installed"; exit 1; }
done
sha256sum -c PACKAGE.sha256 >/dev/null
ucode -e 'import { readfile } from "fs"; assert(type(readfile("PACKAGE.sha256")) == "string");'
pidof crond >/dev/null || { echo 'Enable OpenWrt Scheduled Tasks first; no changes applied'; exit 1; }
. ./lib.sh
[ ! -d /var/lock/zm-ui-cleanup ] || fail 'Previous cleanup is running; retry after it finishes'
safe_path "$BASE/owner-zm-local-ui"
if [ -d "$BASE" ] && [ ! -f "$BASE/owner-zm-local-ui" ]; then fail 'Directory belongs to another installation'; fi
private_dir "$BASE"
acquire
tmp=''
finish() {
    rc=$?; trap - EXIT HUP INT TERM
    [ -z "$tmp" ] || tree_clear "$tmp" || true
    release
    exit "$rc"
}
trap finish EXIT
trap 'exit 1' HUP INT TERM
tmp=$(mktemp -d "$RUN/stage.XXXXXX")
printf '%s\n' "$tmp" > "$RUN/lock/stage"
# Disable the old three-command cron job before replacing any addon code.
cron_edit off "$tmp"
: > "$BASE/disabled"
printf '%s\n' 'zm-local-ui revision 4' > "$BASE/owner-zm-local-ui"
for n in lib.sh apply.sh listener.sh after-update.sh fetch-manager.sh security-report.sh tick.sh ensure-luci.sh luci-only.sh transform.uc luci-only.uc \
    lite.css fragments.json known-functions.json credits-head.js credits-tail.js restore.sh memory-report.sh; do
    safe_path "$BASE/$n"
    cp "$n" "$tmp/$n"; chmod 600 "$tmp/$n"; mv -f "$tmp/$n" "$BASE/$n"
done
release
# New scripts own the lock. Installer cleanup must not release somebody else's lock.
trap 'rc=$?; trap - EXIT; tree_clear "$tmp" || true; exit "$rc"' EXIT
sh "$BASE/apply.sh" check
sh "$BASE/apply.sh" apply
acquire
trap finish EXIT
cron_edit on "$tmp"
rm -f "$BASE/disabled"
echo 'Automatic reapply: one job every 5 minutes after a stable observation (normally 5-10 minutes).'
echo 'No resident watcher. UI servers reload only when their files/settings change.'
echo 'Check: sh /etc/zm-local-ui/apply.sh check'
echo 'Disable/rollback: sh /etc/zm-local-ui/restore.sh'
sh "$BASE/memory-report.sh"
