#!/bin/sh
# mosdns rule updater - reads cron/sync.conf, fetches enabled sources
# Output:
#   geosite/domain files -> mosdns domain rule lines
#   geoip_*.txt          -> raw CIDR/IP lines

set -e

CRON_ENV="/etc/mosdns/cron/env"
[ -f "$CRON_ENV" ] && . "$CRON_ENV"

RULES_DIR="/etc/mosdns/rule"
CONF="/etc/mosdns/cron/sync.conf"
TMPDIR="/tmp/mosdns-rule-update.$$"
RELOAD_MARK="/etc/mosdns/tmp/reload-needed"

cleanup() {
    rm -rf "$TMPDIR"
    rm -f "$RULES_DIR"/.*.tmp.$$
}
trap cleanup EXIT
mkdir -p "$TMPDIR" "$RULES_DIR"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

if [ "${MOSDNS_SYNC_RULES_ENABLED:-1}" != "1" ]; then
    log "rule sync disabled"
    exit 0
fi

DNS_CONF="/etc/mosdns/dns.yaml"

get_proxy_socks5() {
    [ -f "$DNS_CONF" ] || return 0
    awk -F'"' '
        /^[[:space:]]*-[[:space:]]*tag:[[:space:]]*(cloudflare|google)[[:space:]]*$/ { in_proxy = 1; next }
        /^[[:space:]]*-[[:space:]]*tag:[[:space:]]*/ { in_proxy = 0 }
        in_proxy && /^[[:space:]]*socks5:[[:space:]]*"/ { print $2; exit }
    ' "$DNS_CONF"
}

get_proxy_bootstrap() {
    [ -f "$DNS_CONF" ] || return 0
    bootstrap=$(awk -F'"' '
        /^[[:space:]]*-[[:space:]]*tag:[[:space:]]*(cloudflare|google)[[:space:]]*$/ { in_proxy = 1; next }
        /^[[:space:]]*-[[:space:]]*tag:[[:space:]]*/ { in_proxy = 0 }
        in_proxy && /^[[:space:]]*bootstrap:[[:space:]]*"/ { print $2; exit }
    ' "$DNS_CONF")

    if [ -n "$bootstrap" ]; then
        echo "$bootstrap"
        return 0
    fi

    # Fallback for this setup: the fake-ip DNS upstream is a DNS server too.
    awk -F'"' '/^[[:space:]]*- addr:[[:space:]]*"udp:\/\/198\.18\./ { sub(/^udp:\/\//, "", $2); sub(/:.*/, "", $2); print $2; exit }' "$DNS_CONF"
}

SCRIPT_SOCKS5=$(get_proxy_socks5)
SCRIPT_BOOTSTRAP=$(get_proxy_bootstrap)

url_host() {
    echo "$1" | sed -n 's#^[A-Za-z][A-Za-z0-9+.-]*://\([^/:]*\).*#\1#p'
}

resolve_with_bootstrap() {
    local r_host="$1"
    local r_dns="$2"
    [ -n "$r_host" ] && [ -n "$r_dns" ] || return 1
    nslookup "$r_host" "$r_dns" 2>/dev/null | awk '
        /^Address: / && $2 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ { print $2; exit }
    '
}

wget_with_hosts_ip() {
    local w_url="$1"
    local w_dst="$2"
    local w_host="$3"
    local w_ip="$4"
    local w_hosts_bak="$TMPDIR/hosts.bak"
    local w_rc

    cp /etc/hosts "$w_hosts_bak"
    printf '\n%s %s\n' "$w_ip" "$w_host" >> /etc/hosts
    timeout 180 wget -q -T 30 -O "$w_dst" "$w_url"
    w_rc=$?
    cat "$w_hosts_bak" > /etc/hosts
    return "$w_rc"
}

fetch_url() {
    local f_url="$1"
    local f_dst="$2"
    local f_host
    local f_ip
    f_host=$(url_host "$f_url")

    # Order: socks5 proxy -> bootstrap DNS/fake-ip -> direct.
    # Current image has BusyBox wget only; socks5 is used when curl is available.
    if [ -n "$SCRIPT_SOCKS5" ]; then
        if command -v curl >/dev/null 2>&1; then
            if curl -fsSL --connect-timeout 20 --max-time 180 --socks5-hostname "$SCRIPT_SOCKS5" -o "$f_dst" "$f_url"; then
                log "  fetched via socks5 $SCRIPT_SOCKS5"
                return 0
            fi
            log "WARN: socks5 fetch failed, trying bootstrap/direct"
        else
            log "WARN: socks5 configured ($SCRIPT_SOCKS5) but curl is not available, trying bootstrap/direct"
        fi
    fi

    if [ -n "$SCRIPT_BOOTSTRAP" ] && [ -n "$f_host" ]; then
        f_ip=$(resolve_with_bootstrap "$f_host" "$SCRIPT_BOOTSTRAP")
        if [ -n "$f_ip" ]; then
            if wget_with_hosts_ip "$f_url" "$f_dst" "$f_host" "$f_ip"; then
                log "  fetched via bootstrap $SCRIPT_BOOTSTRAP ($f_host -> $f_ip)"
                return 0
            fi
            log "WARN: bootstrap fetch failed via $SCRIPT_BOOTSTRAP ($f_host -> $f_ip), trying direct"
        else
            log "WARN: bootstrap $SCRIPT_BOOTSTRAP did not return IPv4 for $f_host, trying direct"
        fi
    fi

    log "  trying direct fetch"
    timeout 180 wget -q -T 30 -O "$f_dst" "$f_url"
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
while IFS='|' read -r filename enabled interval url; do
    # trim whitespace
    filename=$(echo "$filename" | xargs)
    enabled=$(echo "$enabled" | xargs)
    url=$(echo "$url" | xargs)

    # skip comments and empty lines
    case "$filename" in \#*|"") continue ;; esac

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
            # Keep CIDR/IP lines as-is; trim whitespace and drop empty/comment lines.
            sed -n 's/[[:space:]]*#.*$//; s/^[[:space:]]*//; s/[[:space:]]*$//; /^$/d; p' "$raw" > "$out"
            if ! validate_geoip_set "$out"; then
                log "ERROR: validation failed for $filename, keeping existing local file"
                rm -f "$out"
                continue
            fi
            ;;
        *)
            # Keep mosdns domain rule syntax as-is; trim whitespace and drop empty/comment lines.
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
