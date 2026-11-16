#!/bin/sh
# Read-only local report. No subscription URLs, configs or public addresses.
set -u
echo 'Zapret Manager Lite: local security inventory'
echo 'Versions:'
cat /etc/openwrt_release 2>/dev/null | grep -E '^DISTRIB_(RELEASE|REVISION|ARCH)=' || true
sed -n 's/^ZM_VERSION=/Manager version: /p' /opt/zapret-manager-luci/backend.sh 2>/dev/null | head -n 1
echo 'Installed package versions (for subsequent vulnerability review):'
if command -v apk >/dev/null; then apk list --installed 2>/dev/null
elif command -v opkg >/dev/null; then opkg list-installed 2>/dev/null; fi
echo 'Listening TCP/UDP ports (local exposure, not a WAN reachability test):'
if command -v ss >/dev/null; then ss -lntu
elif command -v netstat >/dev/null; then netstat -lntu; fi
echo 'Web server sections (selected non-secret settings):'
uci -q show uhttpd 2>/dev/null | grep -E '(=uhttpd$|\.(listen_http|listen_https|home|index_page|ubus_prefix)=)' || true
echo 'Firewall input defaults/zones (no address lists):'
uci -q show firewall 2>/dev/null | grep -E '(=(defaults|zone)$|\.(name|input|forward|output)=)' || true
echo 'Unrestricted ubus ACL patterns (filenames only; review needed, not proof of an exploit):'
for f in /usr/share/rpcd/acl.d/*.json; do
    [ -f "$f" ] || continue
    if grep -q '"\*"' "$f"; then echo "$f"; fi
done
echo 'Addon schedule:'
crontab -l 2>/dev/null | grep '# zm-local-ui$' || true
echo 'Addon latest events:'
logread -e zm-local-ui 2>/dev/null | tail -n 12
echo 'No external port scan or CVE database lookup performed by this script.'
