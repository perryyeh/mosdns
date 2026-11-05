#!/bin/sh
# Resolve my-list mode. MOSDNS_MY_MODE wins when it is 0, 1, or 2.
# Legacy cron.env without that key: candidate sync or promotion enabled => 1, else 0.
# Mode 2 must not be inferred.

mosdns_my_mode() {
    case "${MOSDNS_MY_MODE-}" in
        0|1|2)
            printf '%s\n' "$MOSDNS_MY_MODE"
            ;;
        "")
            if [ "${MOSDNS_SYNC_CANDIDATES_ENABLED:-0}" = "1" ] || [ "${MOSDNS_PROMOTE_ENABLED:-0}" = "1" ]; then
                printf '1\n'
            else
                printf '0\n'
            fi
            ;;
        *)
            printf '0\n'
            ;;
    esac
}
