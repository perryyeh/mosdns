#!/bin/sh
# Restart mosdns container once if rule/promote jobs changed loaded matcher data.

set -e

CRONENV="/etc/mosdns/cron/cron.env"
[ -f "$CRONENV" ] && . "$CRONENV"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

OUT_DIR="${OUT_DIR:-/etc/mosdns/tmp}"
RELOAD_MARK="$OUT_DIR/reload-needed"

if [ "${MOSDNS_RELOAD_ENABLED:-1}" != "1" ]; then
    log "reload disabled"
    exit 0
fi

if [ ! -f "$RELOAD_MARK" ]; then
    log "reload not needed"
    exit 0
fi

method="${MOSDNS_RELOAD_METHOD:-restart}"
rm -f "$RELOAD_MARK"

case "$method" in
    restart)
        log "reload needed; terminating container PID 1, Docker restart policy will start it again"
        kill -TERM 1
        ;;
    none)
        log "reload marker consumed; method=none"
        ;;
    *)
        log "unsupported reload method: $method"
        exit 1
        ;;
esac
