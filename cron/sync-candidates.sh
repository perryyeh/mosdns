#!/bin/sh
# Extract not-in-list domains from in-memory mosdns log.
# Output files are candidate lists grouped by day. Counts are accumulated per day only.

set -e

CRONENV="${CRONENV:-/etc/mosdns/cron/cron.env}"
[ -f "$CRONENV" ] && . "$CRONENV"

LOG_FILE="${LOG_FILE:-/dev/shm/mosdns.log}"
OUT_DIR="${OUT_DIR:-/etc/mosdns/tmp}"
DIRECT_OUT="$OUT_DIR/not-in-list-direct.txt"
PROXY_OUT="$OUT_DIR/not-in-list-proxy.txt"
TMPDIR="/tmp/mosdns-not-in-list.$$"
TODAY="$(date +%Y-%m-%d)"
TODAY_HEADER="# === $TODAY ==="

if [ "${MOSDNS_SYNC_CANDIDATES_ENABLED:-1}" != "1" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] sync candidates disabled"
    exit 0
fi

cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT
mkdir -p "$OUT_DIR" "$TMPDIR"

touch "$DIRECT_OUT" "$PROXY_OUT"

extract_kind() {
    kind="$1"
    out="$2"
    new="$TMPDIR/$kind.counts"
    updated="$TMPDIR/$kind.updated"

    if [ -s "$LOG_FILE" ]; then
        grep "$kind" "$LOG_FILE" 2>/dev/null \
            | sed -n 's/.*"qname":[[:space:]]*"\([^"]*\)".*/\1/p' \
            | sed 's/\.$//; y/ABCDEFGHIJKLMNOPQRSTUVWXYZ/abcdefghijklmnopqrstuvwxyz/' \
            | sed '/^$/d' \
            | sort \
            | uniq -c \
            | awk '{count=$1; $1=""; sub(/^ /, ""); print $0 "\t" count}' > "$new"
    else
        : > "$new"
    fi

    awk -F '\t' '{hits += $2} END {print NR " " hits + 0}' "$new" > "$TMPDIR/$kind.stats"

    awk -v header="$TODAY_HEADER" -v newfile="$new" '
        function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
        function domain_of(line, s) { s=line; sub(/#.*/, "", s); return trim(s) }
        function count_of(line, s) {
            s=line
            if (index(s, "#") == 0) return 0
            sub(/^[^#]*#/, "", s)
            if (match(s, /count[=:][ \t]*[0-9]+/)) {
                s=substr(s, RSTART, RLENGTH)
                sub(/.*count[=:][ \t]*/, "", s)
                return s + 0
            }
            return 0
        }
        function has_pending(    i, d) {
            for (i = 1; i <= n; i++) {
                d = order[i]
                if (d in inc) return 1
            }
            return 0
        }
        function append_pending(    i, d) {
            for (i = 1; i <= n; i++) {
                d = order[i]
                if (d in inc) {
                    print d " # count=" inc[d]
                    delete inc[d]
                }
            }
        }
        BEGIN {
            while ((getline line < newfile) > 0) {
                split(line, a, "\t")
                if (a[1] != "") {
                    if (!(a[1] in inc)) order[++n] = a[1]
                    inc[a[1]] += a[2]
                }
            }
            close(newfile)
            in_today = 0
            saw_today = 0
            printed_any = 0
        }
        $0 == header {
            in_today = 1
            saw_today = 1
            print
            printed_any = 1
            next
        }
        /^# === [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] ===$/ {
            if (in_today) append_pending()
            in_today = 0
            print
            printed_any = 1
            next
        }
        {
            if (in_today) {
                d = domain_of($0)
                if (d != "" && d in inc) {
                    print d " # count=" (count_of($0) + inc[d])
                    delete inc[d]
                    printed_any = 1
                    next
                }
            }
            print
            printed_any = 1
        }
        END {
            if (in_today) {
                append_pending()
            } else if (!saw_today && has_pending()) {
                if (printed_any) print ""
                print header
                append_pending()
            }
        }
    ' "$out" > "$updated"

    mv -f "$updated" "$out"
}

extract_kind "not_in_list_direct" "$DIRECT_OUT"
extract_kind "not_in_list_fake" "$PROXY_OUT"

read direct_domains direct_hits < "$TMPDIR/not_in_list_direct.stats"
read proxy_domains proxy_hits < "$TMPDIR/not_in_list_fake.stats"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] sync candidates updated direct_domains=${direct_domains:-0} direct_hits=${direct_hits:-0} proxy_domains=${proxy_domains:-0} proxy_hits=${proxy_hits:-0}"

# Keep high-volume raw log in memory only; clear after extraction.
: > "$LOG_FILE"
