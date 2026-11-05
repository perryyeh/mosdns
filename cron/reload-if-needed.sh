#!/bin/sh
# Restart mosdns once if rule or my jobs changed loaded matcher data.
# Slot "rules" is 00:30 and reloads every mode except mode 2.
# Slot "my" is 01:10 and reloads only mode 2, so a 00:00 rule change is not restarted twice.

set -e

ROOT="${MOSDNS_ROOT:-/etc/mosdns}"
CRONENV="${CRONENV:-$ROOT/cron/cron.env}"
[ -f "$CRONENV" ] && . "$CRONENV"
CRON_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
. "$CRON_DIR/my-mode.sh"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

OUT_DIR="${OUT_DIR:-$ROOT/tmp}"
RELOAD_MARK="${RELOAD_MARK:-$OUT_DIR/reload-needed}"
slot=${1:-rules}
mode=$(mosdns_my_mode)

case "$slot" in
    rules)
        if [ "$mode" = "2" ]; then
            log "my mode 2; defer reload to 01:10"
            exit 0
        fi
        ;;
    my)
        if [ "$mode" != "2" ]; then
            log "my mode ${mode}; skip 01:10 reload"
            exit 0
        fi
        ;;
    *)
        log "unknown reload slot: $slot"
        exit 1
        ;;
esac

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
        if [ -n "${MOSDNS_KILL:-}" ]; then
            "$MOSDNS_KILL" -TERM 1
        else
            kill -TERM 1
        fi
        ;;
    none)
        log "reload marker consumed; method=none"
        ;;
    *)
        log "unsupported reload method: $method"
        exit 1
        ;;
esac
