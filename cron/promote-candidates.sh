#!/bin/sh
# Promote high-frequency not-in-list candidates into my/whitelist.txt and my/greylist.txt.
# Also prunes old candidate history blocks.

set -e

CRONENV="/etc/mosdns/cron/cron.env"
[ -f "$CRONENV" ] && . "$CRONENV"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

if [ "${MOSDNS_PROMOTE_ENABLED:-0}" != "1" ]; then
    log "candidate promotion disabled"
    exit 0
fi

OUT_DIR="${OUT_DIR:-/etc/mosdns/tmp}"
MY_DIR="${MY_DIR:-/etc/mosdns/my}"
DIRECT_CANDIDATES="$OUT_DIR/not-in-list-direct.txt"
PROXY_CANDIDATES="$OUT_DIR/not-in-list-proxy.txt"
WHITELIST="$MY_DIR/whitelist.txt"
GREYLIST="$MY_DIR/greylist.txt"
RELOAD_MARK="$OUT_DIR/reload-needed"
TMPDIR="/tmp/mosdns-promote.$$"

LOOKBACK_DAYS="${MOSDNS_PROMOTE_LOOKBACK_DAYS:-7}"
DIRECT_THRESHOLD="${MOSDNS_PROMOTE_DIRECT_THRESHOLD:-50}"
PROXY_THRESHOLD="${MOSDNS_PROMOTE_PROXY_THRESHOLD:-50}"
RETENTION_DAYS="${MOSDNS_CANDIDATE_RETENTION_DAYS:-30}"
TODAY="$(date +%Y-%m-%d)"
TODAY_EPOCH="$(date -d "$TODAY" +%s)"
LOOKBACK_CUTOFF=$((TODAY_EPOCH - (LOOKBACK_DAYS - 1) * 86400))
RETENTION_CUTOFF=$((TODAY_EPOCH - (RETENTION_DAYS - 1) * 86400))
TODAY_HEADER="# === $TODAY ==="

cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT
mkdir -p "$OUT_DIR" "$MY_DIR" "$TMPDIR"
touch "$DIRECT_CANDIDATES" "$PROXY_CANDIDATES" "$WHITELIST" "$GREYLIST"

promote_one() {
    candidates="$1"
    target="$2"
    threshold="$3"
    label="$4"
    counts="$TMPDIR/$label.counts"
    additions="$TMPDIR/$label.additions"
    target_new="$TMPDIR/$label.target"
    cand_new="$TMPDIR/$label.candidates"

    awk -v cutoff="$LOOKBACK_CUTOFF" '
        function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
        function epoch(d, a) { split(d, a, "-"); return mktime(a[1] " " a[2] " " a[3] " 00 00 00") }
        function domain_of(line, s) { s=line; sub(/#.*/, "", s); return trim(s) }
        function count_of(line, s) {
            s=line
            if (index(s, "#") == 0) return 1
            sub(/^[^#]*#/, "", s)
            if (match(s, /count[=:][ \t]*[0-9]+/)) {
                s=substr(s, RSTART, RLENGTH)
                sub(/.*count[=:][ \t]*/, "", s)
                return s + 0
            }
            return 1
        }
        /^# === [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/ {
            date=substr($3, 1, 10)
            in_range=(epoch(date) >= cutoff)
            next
        }
        {
            if (!in_range) next
            d=domain_of($0)
            if (d != "") total[d] += count_of($0)
        }
        END {
            for (d in total) print d "\t" total[d]
        }
    ' "$candidates" | sort > "$counts"

    awk -v threshold="$threshold" -v targetfile="$target" '
        function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
        function covered_by_domain_rule(d, x) {
            x=d
            while (x != "") {
                if (x in domain_exists) return 1
                if (index(x, ".") == 0) break
                sub(/^[^.]+\./, "", x)
            }
            return 0
        }
        BEGIN {
            while ((getline line < targetfile) > 0) {
                s=line; sub(/#.*/, "", s); s=trim(s)
                if (s == "") continue
                if (s ~ /^full:/) {
                    sub(/^full:/, "", s)
                    if (s != "") full_exists[s]=1
                } else {
                    sub(/^domain:/, "", s)
                    if (s != "") domain_exists[s]=1
                }
            }
            close(targetfile)
        }
        {
            d=$1; c=$2 + 0
            if (c >= threshold && !(d in full_exists) && !covered_by_domain_rule(d)) print d "\t" c
        }
    ' "$counts" > "$additions"

    if [ -s "$additions" ]; then
        cp "$target" "$target_new"
        if ! grep -Fqx "$TODAY_HEADER" "$target_new" 2>/dev/null; then
            if [ -s "$target_new" ]; then
                printf '\n%s\n' "$TODAY_HEADER" >> "$target_new"
            else
                printf '%s\n' "$TODAY_HEADER" >> "$target_new"
            fi
        fi
        awk '{ print "domain:" $1 }' "$additions" >> "$target_new"
        mv -f "$target_new" "$target"
        touch "$RELOAD_MARK"
        log "promoted $(wc -l < "$additions") domains to $target"
    else
        log "no $label candidates reached threshold $threshold"
    fi

    if [ "$RETENTION_DAYS" -gt 0 ] 2>/dev/null; then
        awk -v cutoff="$RETENTION_CUTOFF" '
            function epoch(d, a) { split(d, a, "-"); return mktime(a[1] " " a[2] " " a[3] " 00 00 00") }
            /^# === [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/ {
                date=substr($3, 1, 10)
                keep=(epoch(date) >= cutoff)
                if (keep && printed) print ""
                if (keep) { print; printed=1 }
                next
            }
            { if (keep) print }
        ' "$candidates" > "$cand_new"
        mv -f "$cand_new" "$candidates"
    fi
}

promote_one "$DIRECT_CANDIDATES" "$WHITELIST" "$DIRECT_THRESHOLD" "direct"
promote_one "$PROXY_CANDIDATES" "$GREYLIST" "$PROXY_THRESHOLD" "proxy"

report_my_lists() {
    whitelist_count=$(sed -n 's/#.*//; /^[[:space:]]*$/d; p' "$WHITELIST" | wc -l | tr -d ' ')
    greylist_count=$(sed -n 's/#.*//; /^[[:space:]]*$/d; p' "$GREYLIST" | wc -l | tr -d ' ')
    log "my whitelist domains: $whitelist_count ($WHITELIST)"
    log "my greylist domains: $greylist_count ($GREYLIST)"
}

report_my_lists
