#!/bin/sh
set -eu
BASE=/etc/zm-local-ui
[ "$(id -u)" = 0 ] || exit 1
# Stop ONLY our scheduled job, preserving every other entry.
tmp=$(mktemp -d /tmp/zm-local-restore.XXXXXX)
trap 'rm -f "$tmp/old" "$tmp/new" "$tmp/now" "$tmp/list"; rmdir "$tmp" 2>/dev/null || true' EXIT
crontab -l > "$tmp/old"
grep -v ' # zm-local-ui$' "$tmp/old" > "$tmp/new" || true
crontab -l > "$tmp/now"
cmp -s "$tmp/old" "$tmp/now" || { echo 'Crontab changed; retry'; exit 1; }
crontab "$tmp/new"
: > "$BASE/disabled"
mkdir /var/lock/zm-ui-cleanup 2>/dev/null || { echo 'Auto-reapply disabled; UI cleanup is busy. Retry rollback.'; exit 1; }
trap 'rmdir /var/lock/zm-ui-cleanup 2>/dev/null || true; rm -f "$tmp/old" "$tmp/new" "$tmp/now" "$tmp/list"; rmdir "$tmp" 2>/dev/null || true' EXIT
[ -f "$BASE/before.tar.gz" ] && [ ! -L "$BASE/before.tar.gz" ] || { echo 'Auto-reapply disabled; no backup available'; exit 1; }
# Refuse to overwrite a newer manager version with an older UI backup.
actual=$({ for p in /usr/share/luci/menu.d/luci-app-zapret-manager.json /www/luci-static/resources/view/zapret-manager/style.css /www/luci-static/resources/view/zapret-manager/dashboard.js /www/luci-static/resources/view/zapret-manager/system.js /www/luci-static/resources/view/zapret-manager/thanks.js /www/zm/app.js /www/zm/app.css /www/zm-webui.html; do
 if [ -f "$p" ]; then sha256sum "$p"; else printf 'MISSING %s\n' "$p"; fi
 done
 sha256sum "$BASE/lite.css" "$BASE/transform.uc" "$BASE/fragments.json" "$BASE/credits-head.js" "$BASE/credits-tail.js"
} | sha256sum | cut -d' ' -f1)
[ "$actual" = "$(cat "$BASE/after.signature")" ] || { echo 'Auto-reapply disabled. UI changed since backup; no old files restored.'; exit 1; }
tar -tzf "$BASE/before.tar.gz" > "$tmp/list"
while IFS= read -r p; do
 case "$p" in usr/share/luci/menu.d/luci-app-zapret-manager.json|www/luci-static/resources/view/zapret-manager/style.css|www/luci-static/resources/view/zapret-manager/dashboard.js|www/luci-static/resources/view/zapret-manager/system.js|www/luci-static/resources/view/zapret-manager/thanks.js|www/zm/app.js|www/zm/app.css|www/zm-webui.html) ;;
 *) echo 'Unexpected backup member'; exit 1;; esac
 [ ! -L "/$p" ] || exit 1
done < "$tmp/list"
tar -xzf "$BASE/before.tar.gz" -C /
for p in /tmp/luci-indexcache* /tmp/luci-modulecache/*; do [ ! -f "$p" ] || [ -L "$p" ] || rm -f "$p" || true; done
echo 'Auto-reapply disabled. UI restored to immediately before the last cleanup. Ctrl+F5.'
