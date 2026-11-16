#!/bin/sh
# Fast upstream updates, with no third-party mirror or downloaded-code execution.
set -eu
umask 077
[ "$(id -u)" = 0 ] || exit 1
dest=${1:-}
[ "$dest" = /tmp/zm_update_install.sh ] || { echo 'Unexpected updater destination'; exit 1; }
[ ! -L "$dest" ] || { echo 'Updater destination is a symlink'; exit 1; }
[ ! -e "$dest" ] || [ -f "$dest" ] || exit 1
command -v curl >/dev/null || { echo 'curl with TLS support is required for direct verified HTTPS updates'; exit 1; }
d=$(mktemp -d /tmp/zm-direct-update.XXXXXX)
trap 'rm -f "$d/installer"; rmdir "$d" 2>/dev/null || true' EXIT
trap 'exit 1' HUP INT TERM
url=https://raw.githubusercontent.com/StressOzz/Zapret-Manager/refs/heads/main/ZapretManager_LuCI.sh
# Fail closed: no -k, no mirrors, no non-HTTPS redirects, no proxy environment.
curl --disable --fail --silent --show-error --proto '=https' --proto-redir '=https' \
    --noproxy '*' --connect-timeout 10 --max-time 180 --max-filesize 12582912 \
    --output "$d/installer" "$url" || { echo 'Direct GitHub download failed; update cancelled'; exit 1; }
size=$(wc -c < "$d/installer")
[ "$size" -gt 1024 ] && [ "$size" -le 12582912 ] || { echo 'Unexpected installer size'; exit 1; }
head -n 1 "$d/installer" | grep -qx '#!/bin/sh' || exit 1
grep -q '^# Version: [0-9][0-9.]*$' "$d/installer" || exit 1
tail -n 5 "$d/installer" | grep -q 'Web UI:' || { echo 'Incomplete/unknown upstream installer'; exit 1; }
sh -n "$d/installer" || { echo 'Installer shell syntax rejected'; exit 1; }
logger -t zm-local-ui "Direct upstream installer SHA256: $(sha256sum "$d/installer" | cut -d' ' -f1)"
[ ! -L "$dest" ] || exit 1
mv -f "$d/installer" "$dest"
