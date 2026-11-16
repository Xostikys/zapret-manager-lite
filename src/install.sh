#!/bin/sh
set -eu
cd "$(dirname "$0")"
[ "$(id -u)" = 0 ] || exit 1
sha256sum -c PACKAGE.sha256 >/dev/null
for c in ucode crontab sha256sum cmp tar xargs; do command -v "$c" >/dev/null || { echo "Missing $c; nothing installed"; exit 1; }; done
pidof crond >/dev/null || { echo 'System cron is stopped; enable Scheduled Tasks before installing. No changes applied.'; exit 1; }
BASE=/etc/zm-local-ui
[ ! -L "$BASE" ] || exit 1
if [ -e "$BASE" ] && [ ! -f "$BASE/owner-zm-local-ui" ]; then echo 'Installation directory already exists; no changes'; exit 1; fi
mkdir -p "$BASE"
umask 077
printf '%s\n' 'zm-local-ui v1' > "$BASE/owner-zm-local-ui"
for n in tick.sh transform.uc lite.css fragments.json credits-head.js credits-tail.js restore.sh memory-report.sh; do
 [ ! -L "$BASE/$n" ] || exit 1
 cp "$n" "$BASE/$n.new"; chmod 600 "$BASE/$n.new"; mv "$BASE/$n.new" "$BASE/$n"
done
rm -f "$BASE/disabled"
sh "$BASE/tick.sh" apply
tmp=$(mktemp -d /tmp/zm-local-cron.XXXXXX)
trap 'rm -f "$tmp/old" "$tmp/new" "$tmp/now"; rmdir "$tmp" 2>/dev/null || true' EXIT
if ! crontab -l > "$tmp/old" 2>/dev/null; then [ ! -e /etc/crontabs/root ] || exit 1; fi
grep -v ' # zm-local-ui$' "$tmp/old" > "$tmp/new" || true
printf '%s\n' '*/5 * * * * sh /etc/zm-local-ui/tick.sh auto >/dev/null 2>&1 # zm-local-ui' >> "$tmp/new"
if ! crontab -l > "$tmp/now" 2>/dev/null; then [ ! -e /etc/crontabs/root ] || exit 1; fi
cmp -s "$tmp/old" "$tmp/now" || { echo 'Crontab changed concurrently; UI applied but auto-reapply not installed. Retry installer.'; exit 1; }
crontab "$tmp/new"
echo 'Automatic reapply installed: every 5 minutes, after two matching observations (5-10 min after update).'
echo 'No resident watcher, no network-service restarts. Refresh LuCI with Ctrl+F5.'
echo 'Disable + rollback: sh /etc/zm-local-ui/restore.sh'
sh "$BASE/memory-report.sh"
