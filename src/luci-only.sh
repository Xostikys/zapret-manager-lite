#!/bin/sh
set -eu
BASE=/etc/zm-local-ui
[ ! -f "$BASE/disabled" ] || exit 0
mkdir /var/lock/zm-ui-cleanup 2>/dev/null || exit 0
umask 077
stage=$(mktemp -d /tmp/zm-luci-only.XXXXXX)
changed=0
done_ok=0
pending=''
fingerprint=unknown
cleanup() {
 rc=$?
 if [ "$rc" != 0 ] && [ "$(cat /tmp/zm-luci-only.failed 2>/dev/null || true)" != "$fingerprint" ]; then
  logger -t zm-local-ui 'Component migration skipped/failed; run sh /etc/zm-local-ui/luci-only.sh for details.'
  printf '%s\n' "$fingerprint" > /tmp/zm-luci-only.failed
 fi
 [ -z "$pending" ] || rm -f "$pending"
 if [ "$changed" = 1 ] && [ "$done_ok" != 1 ]; then
  tar -xzf "$stage/before.tar.gz" -C / || echo 'Component restore failed' >&2
 fi
 rm -f "$stage/old/"* "$stage/new/"* "$stage/plan.json" "$stage/paths" "$stage/checks" "$stage/before.tar.gz"
 rmdir "$stage/old" "$stage/new" "$stage" 2>/dev/null || true
 rmdir /var/lock/zm-ui-cleanup 2>/dev/null || true
 exit "$rc"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
mkdir "$stage/old" "$stage/new"
for p in /opt/zapret-manager-luci /opt/zapret-manager-luci/mod /www/luci-static/resources/view/zapret-manager /www/luci-static/resources/zapret-manager; do
 [ ! -L "$p" ] || { echo "Unsupported component directory symlink: $p"; exit 1; }
done
printf '[' > "$stage/plan.json"
id=0; sep=''
for p in /opt/zapret-manager-luci/backend.sh /opt/zapret-manager-luci/mod/system.sh /usr/libexec/rpcd/zapret-manager /usr/share/rpcd/acl.d/luci-app-zapret-manager.json /www/luci-static/resources/zapret-manager/common.js /www/luci-static/resources/view/zapret-manager/*.js; do
 [ -f "$p" ] || continue
 [ ! -L "$p" ] || { echo "Unsupported component symlink: $p"; exit 1; }
 case "$p" in /opt/*|/usr/libexec/*) kind=shell;; *.json) kind=json;; *) kind=js;; esac
 id=$((id + 1))
 printf '%s{"id":"%s","kind":"%s","path":"%s"}' "$sep" "$id" "$kind" "$p" >> "$stage/plan.json"
 sep=,
 printf '%s\n' "${p#/}" >> "$stage/paths"
 cp "$p" "$stage/old/$id"
done
printf ']\n' >> "$stage/plan.json"
if [ -f "$BASE/components-after.sha256" ] && cmp -s "$stage/paths" "$BASE/components-paths" && (cd /; sha256sum -c "$BASE/components-after.sha256") >/dev/null 2>&1; then
 done_ok=1; exit 0
fi
(cd /; xargs sha256sum < "$stage/paths") > "$stage/checks"
fingerprint=$(sha256sum "$stage/checks" | cut -d' ' -f1)
if [ "${1:-apply}" = auto ] && [ "$fingerprint" != "$(cat /tmp/zm-luci-only.pending 2>/dev/null || true)" ]; then
 printf '%s\n' "$fingerprint" > /tmp/zm-luci-only.pending
 done_ok=1; exit 0
fi
(cd "$stage"; ucode "$BASE/luci-only.uc")
id=0; dirty=0; rpc_changed=0
while IFS= read -r rel; do
 id=$((id + 1)); p="/$rel"
 case "$p" in /opt/*|/usr/libexec/*) sh -n "$stage/new/$id";; esac
 if ! cmp -s "$stage/old/$id" "$stage/new/$id"; then
  dirty=1
  case "$p" in /usr/libexec/rpcd/*|/usr/share/rpcd/*) rpc_changed=1;; esac
 fi
done < "$stage/paths"
# Separate listener must already be off: never change the shared LuCI server
# configuration through an unreviewed whole-file rewrite.
if uci -q get uhttpd.zmweb >/dev/null; then
 echo 'Disable the separate listener in the original manager first, then repeat.'; exit 1
fi
if [ "$dirty" = 1 ]; then
 tar -czf "$stage/before.tar.gz" -C / -T "$stage/paths"
 (cd /; sha256sum -c "$stage/checks") >/dev/null
 cp "$stage/before.tar.gz" "$BASE/components-before.tar.gz"
 changed=1; id=0
 while IFS= read -r rel; do
  id=$((id + 1)); p="/$rel"
  cmp -s "$stage/old/$id" "$stage/new/$id" && continue
  # Preserve mode and ownership of shell entrypoints and RPC executables.
  pending="$p.luci-only-new"
  [ ! -e "$pending" ] && [ ! -L "$pending" ] || exit 1
  cp -p "$p" "$pending"; cat "$stage/new/$id" > "$pending"; mv "$pending" "$p"
  pending=''
 done < "$stage/paths"
fi
for p in /www/zm-webui.html /www/zm/app.js /www/zm/app.css /www/zm/theme.txt /www/zm/look.json /www/zm/https.txt /opt/zapret-manager-luci/state/webui /opt/zapret-manager-luci/state/webui.html; do
 [ ! -L "$p" ] || exit 1
 rm -f "$p"
done
rmdir /www/zm 2>/dev/null || true
done_ok=1
(cd /; xargs sha256sum < "$stage/paths") > "$BASE/components-after.sha256"
cp "$stage/paths" "$BASE/components-paths"
rm -f /tmp/zm-luci-only.pending /tmp/zm-luci-only.failed
if [ "$rpc_changed" = 1 ]; then /etc/init.d/rpcd reload; fi
echo 'LuCI-only components applied. Refresh LuCI with Ctrl+F5.'
