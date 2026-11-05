#!/bin/sh
# mosdns rule updater - reads cron/sync.conf and fetches enabled rule/ sources.
# my/ lines in the same file are ignored here.
# Output:
#   geosite/domain files -> mosdns domain rule lines
#   geoip_*.txt          -> raw CIDR/IP lines

set -e

ROOT="${MOSDNS_ROOT:-/etc/mosdns}"
CRONENV="${CRONENV:-$ROOT/cron/cron.env}"
[ -f "$CRONENV" ] && . "$CRONENV"

RULES_DIR="${RULES_DIR:-$ROOT/rule}"
CONF="${CONF:-$ROOT/cron/sync.conf}"
TMPDIR="${TMPDIR_SYNC:-${TMPDIR:-/tmp}/mosdns-rule-update.$$}"
RELOAD_MARK="${RELOAD_MARK:-$ROOT/tmp/reload-needed}"
CRON_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)

cleanup() {
    rm -rf "$TMPDIR"
    rm -f "$RULES_DIR"/.*.tmp.$$
}
trap cleanup EXIT
mkdir -p "$TMPDIR" "$RULES_DIR" "$(dirname "$RELOAD_MARK")"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

if [ "${MOSDNS_SYNC_RULES_ENABLED:-1}" != "1" ]; then
    log "rule sync disabled"
    exit 0
fi

# shellcheck disable=SC1091
. "$CRON_DIR/sync-target.sh"
# shellcheck disable=SC1091
. "$CRON_DIR/fetch.sh"
DNS_CONF="${DNS_CONF:-$ROOT/dns.yaml}"
SCRIPT_BOOTSTRAP=$(get_proxy_bootstrap)

trim() {
    printf '%s' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

validate_domain_set() {
    file="$1"
    if [ ! -s "$file" ]; then
        log "ERROR: generated empty domain set for $filename"
        return 1
    fi

    awk '
        function bad() {
            print "invalid domain line " NR ": " $0 > "/dev/stderr"
            exit 1
        }
        /[[:space:]]/ { bad() }
        /^domain:[A-Za-z0-9_.-]+$/ { next }
        /^full:[A-Za-z0-9_.-]+$/ { next }
        /^keyword:.+$/ { next }
        /^regexp:.+$/ { next }
        /^[A-Za-z0-9_.-]+$/ { next }
        { bad() }
    ' "$file"
}

validate_geoip_set() {
    file="$1"
    if [ ! -s "$file" ]; then
        log "ERROR: generated empty geoip set for $filename"
        return 1
    fi

    awk '
        function valid_ipv4(ip, a, n, i) {
            n = split(ip, a, ".")
            if (n != 4) return 0
            for (i = 1; i <= 4; i++) {
                if (a[i] !~ /^[0-9]+$/ || a[i] < 0 || a[i] > 255) return 0
            }
            return 1
        }
        function valid_ipv6(ip) {
            return ip ~ /^[0-9A-Fa-f:]+$/ && ip ~ /:/
        }
        {
            n = split($0, p, "/")
            if (n > 2) {
                print "invalid geoip line " NR ": " $0 > "/dev/stderr"
                exit 1
            }
            if (valid_ipv4(p[1]) && (n == 1 || (p[2] ~ /^[0-9]+$/ && p[2] >= 0 && p[2] <= 32))) next
            if (valid_ipv6(p[1]) && (n == 1 || (p[2] ~ /^[0-9]+$/ && p[2] >= 0 && p[2] <= 128))) next
            print "invalid geoip line " NR ": " $0 > "/dev/stderr"
            exit 1
        }
    ' "$file"
}

updated=0
while IFS='|' read -r filename enabled url; do
    filename=$(trim "$filename")
    enabled=$(trim "$enabled")
    url=$(trim "$url")

    case "$filename" in
        \#*|"") continue ;;
    esac

    if ! classified=$(mosdns_sync_classify "$filename"); then
        log "ERROR: reject sync target $filename"
        continue
    fi
    area=${classified%% *}
    base=${classified#* }
    if [ "$area" != "rule" ]; then
        log "skip $filename (handled by my sync)"
        continue
    fi
    filename=$base

    if [ "$enabled" != "yes" ]; then
        log "skip $filename (enabled=$enabled)"
        continue
    fi

    dst="$RULES_DIR/$filename"
    raw="$TMPDIR/$filename.raw"
    out="$RULES_DIR/.$filename.tmp.$$"

    log "fetching $filename ..."
    if ! fetch_url "$url" "$raw"; then
        log "ERROR: failed to download $url"
        rm -f "$raw" "$out"
        continue
    fi

    lines=$(wc -l < "$raw")
    log "  downloaded $lines lines"

    case "$filename" in
        geoip_*.txt)
            sed -n 's/[[:space:]]*#.*$//; s/^[[:space:]]*//; s/[[:space:]]*$//; /^$/d; p' "$raw" > "$out"
            if ! validate_geoip_set "$out"; then
                log "ERROR: validation failed for $filename, keeping existing local file"
                rm -f "$out"
                continue
            fi
            ;;
        *)
            sed -n '/^[[:space:]]*#/d; s/^[[:space:]]*//; s/[[:space:]]*$//; /^$/d; p' "$raw" > "$out"
            if ! validate_domain_set "$out"; then
                log "ERROR: validation failed for $filename, keeping existing local file"
                rm -f "$out"
                continue
            fi
            ;;
    esac

    if [ -f "$dst" ] && cmp -s "$out" "$dst"; then
        log "  unchanged $dst"
        rm -f "$out"
    else
        mv -f "$out" "$dst"
        log "  wrote $(wc -l < "$dst") lines to $dst"
        touch "$RELOAD_MARK"
        updated=1
    fi
done < "$CONF"

if [ "$updated" -eq 1 ]; then
    log "update complete"
else
    log "no source files changed"
fi
