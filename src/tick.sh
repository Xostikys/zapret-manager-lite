#!/bin/sh
# Compatibility entrypoint: all stages share one transaction.
exec sh /etc/zm-local-ui/apply.sh "${1:-auto}"
