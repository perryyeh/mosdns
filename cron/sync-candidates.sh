#!/bin/sh
# Extract unique not-in-list domains from in-memory mosdns log.
# Output files are cumulative unique candidate lists, not active rule files.

set -e

LOG_FILE="/dev/shm/mosdns.log"
OUT_DIR="/etc/mosdns/tmp"
DIRECT_OUT="$OUT_DIR/not-in-list-direct.txt"
PROXY_OUT="$OUT_DIR/not-in-list-proxy.txt"
TMPDIR="/tmp/mosdns-not-in-list.$$"

cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT
mkdir -p "$OUT_DIR" "$TMPDIR"

touch "$DIRECT_OUT" "$PROXY_OUT"

extract_kind() {
    kind="$1"
    out="$2"
    new="$TMPDIR/$kind.new"
    merged="$TMPDIR/$kind.merged"

    if [ -s "$LOG_FILE" ]; then
        grep "$kind" "$LOG_FILE" 2>/dev/null \
            | sed -n 's/.*"qname":[[:space:]]*"\([^"]*\)".*/\1/p' \
            | sed 's/\.$//; y/ABCDEFGHIJKLMNOPQRSTUVWXYZ/abcdefghijklmnopqrstuvwxyz/' \
            | sed '/^$/d' \
            | sort -u > "$new"
    else
        : > "$new"
    fi

    cat "$out" "$new" 2>/dev/null \
        | sed 's/\.$//; y/ABCDEFGHIJKLMNOPQRSTUVWXYZ/abcdefghijklmnopqrstuvwxyz/' \
        | sed '/^$/d' \
        | sort -u > "$merged"

    mv -f "$merged" "$out"
}

extract_kind "not_in_list_direct" "$DIRECT_OUT"
extract_kind "not_in_list_fake" "$PROXY_OUT"

# Keep high-volume raw log in memory only; clear after extraction.
: > "$LOG_FILE"
