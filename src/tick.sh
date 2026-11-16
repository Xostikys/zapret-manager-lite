#!/bin/sh
set -eu
BASE=/etc/zm-local-ui
MODE=${1:-auto}
case "$MODE" in auto|apply) ;; *) echo 'Usage: tick.sh [auto|apply]'; exit 1;; esac
[ ! -f "$BASE/disabled" ] || exit 0
[ "$(id -u)" = 0 ] || exit 1
LOCK=/var/lock/zm-ui-cleanup
if ! mkdir "$LOCK" 2>/dev/null; then
 [ "$MODE" = auto ] && exit 0
 echo 'Another UI cleanup is running; retry when it finishes.'; exit 1
fi
umask 077
stage=''
pending_target=''
changed=0
success=0
fingerprint='unknown'
paths() {
 printf '%s\n' /usr/share/luci/menu.d/luci-app-zapret-manager.json \
 /www/luci-static/resources/view/zapret-manager/style.css \
 /www/luci-static/resources/view/zapret-manager/dashboard.js \
 /www/luci-static/resources/view/zapret-manager/system.js \
 /www/luci-static/resources/view/zapret-manager/thanks.js \
 /www/zm/app.js /www/zm/app.css /www/zm-webui.html
}
signature() {
 # Detect both content changes and appearance/disappearance of optional pages.
 { paths | while IFS= read -r p; do
   if [ -f "$p" ]; then sha256sum "$p"; else printf 'MISSING %s\n' "$p"; fi
  done
  sha256sum "$BASE/lite.css" "$BASE/transform.uc" "$BASE/fragments.json" "$BASE/credits-head.js" "$BASE/credits-tail.js"
 } | sha256sum | cut -d' ' -f1
}
cache_clear() {
 for p in /tmp/luci-indexcache* /tmp/luci-modulecache/*; do
  [ ! -f "$p" ] || [ -L "$p" ] || rm -f "$p" || true
 done
}
cleanup() {
 result=$?
 [ -z "$pending_target" ] || rm -f "$pending_target"
 if [ "$success" != 1 ] && [ "$changed" = 1 ]; then
  if tar -xzf "$stage/before.tar.gz" -C /; then cache_clear; else logger -t zm-local-ui 'ERROR: UI rollback failed; inspect /etc/zm-local-ui/before.tar.gz'; fi
 fi
 if [ "$result" != 0 ]; then
  if [ "$(cat /tmp/zm-local-ui.failed 2>/dev/null || true)" != "$fingerprint" ]; then
   logger -t zm-local-ui 'UI cleanup skipped/failed. Run sh /etc/zm-local-ui/tick.sh apply for details; network services unchanged.'
   printf '%s\n' "$fingerprint" > /tmp/zm-local-ui.failed
  fi
 fi
 if [ -n "$stage" ]; then
  rm -f "$stage/old/"* "$stage/new/"* "$stage/"*.json "$stage/"*.css "$stage/"*.js "$stage/before.sha256" "$stage/paths" "$stage/before.tar.gz"
  rmdir "$stage/old" "$stage/new" "$stage" 2>/dev/null || true
 fi
 rmdir "$LOCK" 2>/dev/null || true
 trap - EXIT
 exit "$result"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
fingerprint=$(signature)
if [ "$fingerprint" = "$(cat "$BASE/after.signature" 2>/dev/null || true)" ]; then
 [ "$MODE" = auto ] || echo 'Already applied; no UI writes needed.'
 success=1; exit 0
fi
if [ "$MODE" = auto ] && [ "$fingerprint" != "$(cat /tmp/zm-local-ui.pending 2>/dev/null || true)" ]; then
 printf '%s\n' "$fingerprint" > /tmp/zm-local-ui.pending
 success=1; exit 0
fi
# Require two consecutive scheduled observations and check the snapshot again
# before writes to avoid patching files during an update.
for p in /usr/share/luci/menu.d /www/luci-static/resources/view/zapret-manager /www/zm; do
 [ ! -L "$p" ] || { echo "UI in RAM/symlink detected: $p. Restore normal flash storage in Manager first."; exit 1; }
done
for p in /usr /usr/share /usr/share/luci /www /www/luci-static /www/luci-static/resources /www/luci-static/resources/view /etc "$BASE"; do
 [ -d "$p" ] && [ ! -L "$p" ] || { echo "Unexpected directory: $p"; exit 1; }
done
paths | while IFS= read -r p; do
 [ ! -L "$p" ] || { echo "Unexpected symlink: $p"; exit 1; }
 [ ! -e "$p" ] || [ -f "$p" ] || { echo "Unexpected file type: $p"; exit 1; }
done
[ -f /usr/share/luci/menu.d/luci-app-zapret-manager.json ] && [ -f /www/luci-static/resources/view/zapret-manager/style.css ] || { echo 'Manager menu/CSS missing; no edits'; exit 1; }
if uci -q get uhttpd.zmweb >/dev/null; then
 echo 'Standalone Web listener is enabled. Disable it in Manager before removing its assets.'; exit 1
fi
stage=$(mktemp -d /tmp/zm-local-ui.XXXXXX)
mkdir "$stage/old" "$stage/new"
paths | while IFS= read -r p; do [ ! -f "$p" ] || printf '%s\n' "${p#/}"; done > "$stage/paths"
(cd /; xargs sha256sum < "$stage/paths") > "$stage/before.sha256"
cp /usr/share/luci/menu.d/luci-app-zapret-manager.json "$stage/old/menu.json"
for n in style.css dashboard.js system.js thanks.js; do
 p="/www/luci-static/resources/view/zapret-manager/$n"
 [ ! -f "$p" ] || cp "$p" "$stage/old/$n"
done
for n in fragments.json lite.css credits-head.js credits-tail.js; do cp "$BASE/$n" "$stage/$n"; done
(cd "$stage"; ucode "$BASE/transform.uc")
dirty=0
for f in "$stage/new/"*; do
 name=${f##*/}
 if ! cmp -s "$f" "$stage/old/$name"; then dirty=1; fi
done
for p in /www/zm/app.js /www/zm/app.css /www/zm-webui.html; do [ ! -f "$p" ] || dirty=1; done
[ "$(signature)" = "$fingerprint" ] || { echo 'Manager changed during preparation; retry after update'; exit 1; }
if [ "$dirty" = 1 ]; then
 tar -czf "$stage/before.tar.gz" -C / -T "$stage/paths"
 tar -tzf "$stage/before.tar.gz" >/dev/null
 (cd /; sha256sum -c "$stage/before.sha256") >/dev/null
 for p in "$BASE/before.tar.gz" "$BASE/after.signature"; do [ ! -L "$p" ] || exit 1; done
 cp "$stage/before.tar.gz" "$BASE/before.tar.gz.new"
 mv "$BASE/before.tar.gz.new" "$BASE/before.tar.gz"
 changed=1
 for f in "$stage/new/"*; do
  n=${f##*/}
  if [ "$n" = menu.json ]; then dest=/usr/share/luci/menu.d/luci-app-zapret-manager.json
  else dest="/www/luci-static/resources/view/zapret-manager/$n"; fi
  cmp -s "$f" "$stage/old/$n" && continue
  # tempfile beside destination; rename keeps readers from seeing half a file.
  [ ! -e "$dest.zm-local-new" ] && [ ! -L "$dest.zm-local-new" ] || exit 1
  pending_target="$dest.zm-local-new"
  cp "$f" "$dest.zm-local-new"; chmod 644 "$dest.zm-local-new"; mv "$dest.zm-local-new" "$dest"
  pending_target=''
 done
 rm -f /www/zm/app.js /www/zm/app.css /www/zm-webui.html
 signature > "$BASE/after.signature"
 cache_clear
 logger -t zm-local-ui 'Local UI cleanup applied: no ads, native panel backgrounds, no CSS animations; network services unchanged.'
else
 signature > "$BASE/after.signature"
fi
rm -f /tmp/zm-local-ui.pending /tmp/zm-local-ui.failed
success=1
echo 'DONE: local UI cleanup active. Backup: /etc/zm-local-ui/before.tar.gz'
