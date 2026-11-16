#!/bin/sh
# Called once by the LuCI updater only after the upstream installer succeeds.
set -eu
BASE=/etc/zm-local-ui
[ ! -f "$BASE/disabled" ] || exit 0
[ -f "$BASE/owner-zm-local-ui" ] || exit 0
if sh "$BASE/apply.sh" apply; then
    logger -t zm-local-ui 'Cleanup after Manager update completed.'
else
    logger -t zm-local-ui 'Cleanup after update deferred/failed; cron will retry. Run apply.sh check for details.'
    echo 'Local cleanup needs attention; see logread -e zm-local-ui. The Manager update itself has completed.' >&2
    exit 1
fi
