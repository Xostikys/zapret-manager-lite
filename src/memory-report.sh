#!/bin/sh
# Read-only snapshot; do not drop caches, stop services or change nfqws limits.
echo '--- RAM snapshot (not a measurement of memory saved) ---'
awk '/^(MemTotal|MemAvailable|Shmem|SReclaimable):/ { print }' /proc/meminfo
echo 'Largest current process RSS (kB; shared memory can be counted more than once):'
awk 'FNR == 1 { name="" } /^Name:/ { name=$2 } /^VmRSS:/ { printf "%8d  %s\n", $2, name }' /proc/[0-9]*/status 2>/dev/null | sort -nr | head -n 6
if [ -f /opt/zapret-manager-luci/state/ui.ram ]; then
 printf 'Manager UI storage mode: '; cat /opt/zapret-manager-luci/state/ui.ram
else echo 'Manager UI storage: normal (no ui.ram flag)'; fi
if [ -f /opt/zapret-manager-luci/state/watch.off ]; then echo 'Manager background checks: disabled'
else echo 'Manager background checks: configured by original Manager'; fi
echo 'Forkozz/sing-box, nfqws, DNS and background-check settings were not modified.'
