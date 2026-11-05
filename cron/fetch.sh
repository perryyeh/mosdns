#!/bin/sh
# Shared downloader for rule/ and my/ sync. Callers define log() and TMPDIR.
# The container image provides wget; do not require python or git.

get_proxy_bootstrap() {
    DNS_CONF="${DNS_CONF:-${MOSDNS_ROOT:-/etc/mosdns}/dns.yaml}"
    [ -f "$DNS_CONF" ] || return 0
    bootstrap=$(awk -F'"' '
        /^[[:space:]]*-[[:space:]]*tag:[[:space:]]*(cloudflare|google)[[:space:]]*$/ { in_proxy = 1; next }
        /^[[:space:]]*-[[:space:]]*tag:[[:space:]]*/ { in_proxy = 0 }
        in_proxy && /^[[:space:]]*bootstrap:[[:space:]]*"/ { print $2; exit }
    ' "$DNS_CONF")

    if [ -n "$bootstrap" ]; then
        printf '%s\n' "$bootstrap"
        return 0
    fi

    awk -F'"' '/^[[:space:]]*- addr:[[:space:]]*"udp:\/\/198\.18\./ { sub(/^udp:\/\//, "", $2); sub(/:.*/, "", $2); print $2; exit }' "$DNS_CONF"
}

url_host() {
    printf '%s\n' "$1" | sed -n 's#^[A-Za-z][A-Za-z0-9+.-]*://\([^/:]*\).*#\1#p'
}

resolve_with_bootstrap() {
    r_host=$1
    r_dns=$2
    [ -n "$r_host" ] && [ -n "$r_dns" ] || return 1
    nslookup "$r_host" "$r_dns" 2>/dev/null | awk '
        /^Address: / && $2 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ { print $2; exit }
    '
}

wget_with_hosts_ip() {
    w_url=$1
    w_dst=$2
    w_host=$3
    w_ip=$4
    w_hosts_bak="$TMPDIR/hosts.bak"
    w_rc=0

    cp /etc/hosts "$w_hosts_bak"
    printf '\n%s %s\n' "$w_ip" "$w_host" >> /etc/hosts
    timeout 180 wget -q -T 30 -O "$w_dst" "$w_url"
    w_rc=$?
    cat "$w_hosts_bak" > /etc/hosts
    return "$w_rc"
}

fetch_url() {
    f_url=$1
    f_dst=$2
    f_host=$(url_host "$f_url")
    f_ip=""

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
