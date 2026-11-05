#!/bin/sh
# Download the four my/ lists named in cron/sync.conf.
# Runs only in my mode 2. Mode 1 is never overridden and no file is written.
# All four files are fetched from one perryyeh/mosdns commit, validated, then installed together.

set -e

ROOT="${MOSDNS_ROOT:-/etc/mosdns}"
CRONENV="${CRONENV:-$ROOT/cron/cron.env}"
[ -f "$CRONENV" ] && . "$CRONENV"

CRON_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
. "$CRON_DIR/my-mode.sh"
# shellcheck disable=SC1091
. "$CRON_DIR/sync-target.sh"
# shellcheck disable=SC1091
. "$CRON_DIR/fetch.sh"

CONF="${CONF:-$ROOT/cron/sync.conf}"
MY_DIR="${MY_DIR:-$ROOT/my}"
TMPDIR="${TMPDIR_SYNC:-${TMPDIR:-/tmp}/mosdns-my-update.$$}"
RELOAD_MARK="${RELOAD_MARK:-$ROOT/tmp/reload-needed}"
REPO_API="https://api.github.com/repos/perryyeh/mosdns/commits/main"

cleanup() {
    rm -rf "$TMPDIR"
    rm -f "$MY_DIR"/.whitelist.txt.new.$$ "$MY_DIR"/.greylist.txt.new.$$ \
        "$MY_DIR"/.blacklist.txt.new.$$ "$MY_DIR"/.hosts.txt.new.$$
}
trap cleanup EXIT

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

mode=$(mosdns_my_mode)
if [ "$mode" != "2" ]; then
    log "my download skipped; mode=$mode"
    exit 0
fi

mkdir -p "$TMPDIR" "$MY_DIR" "$(dirname "$RELOAD_MARK")"
SCRIPT_BOOTSTRAP=$(get_proxy_bootstrap)

trim() {
    printf '%s' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

my_ref_for() {
    ref_url=$1
    ref_file=$2
    ref_prefix="https://raw.githubusercontent.com/perryyeh/mosdns/"
    ref_suffix="/my/$ref_file"
    ref_url=${ref_url%%\?*}
    case "$ref_url" in
        "$ref_prefix"*"$ref_suffix")
            ref_url=${ref_url#"$ref_prefix"}
            ref_url=${ref_url%"$ref_suffix"}
            ;;
        "https://github.com/perryyeh/mosdns/raw/"*"$ref_suffix")
            ref_url=${ref_url#https://github.com/perryyeh/mosdns/raw/}
            ref_url=${ref_url%"$ref_suffix"}
            ;;
        *)
            return 1
            ;;
    esac
    [ -n "$ref_url" ] || return 1
    printf '%s\n' "$ref_url"
}

url_set() {
    case "$1" in
        whitelist.txt) URL_whitelist=$2 ;;
        greylist.txt) URL_greylist=$2 ;;
        blacklist.txt) URL_blacklist=$2 ;;
        hosts.txt) URL_hosts=$2 ;;
        *) return 1 ;;
    esac
}

url_get() {
    case "$1" in
        whitelist.txt) printf '%s\n' "$URL_whitelist" ;;
        greylist.txt) printf '%s\n' "$URL_greylist" ;;
        blacklist.txt) printf '%s\n' "$URL_blacklist" ;;
        hosts.txt) printf '%s\n' "$URL_hosts" ;;
        *) return 1 ;;
    esac
}

is_commit_sha() {
    printf '%s' "$1" | grep -Eq '^[0-9a-fA-F]{40}$'
}

validate_domain_file() {
    kind=$1
    file=$2
    if grep -q '[<>]' "$file" 2>/dev/null; then
        log "ERROR: $kind contains HTML-like content"
        return 1
    fi
    awk -v kind="$kind" '
        function bad() { exit 1 }
        /^[[:space:]]*$/ { next }
        /^[[:space:]]*#/ { next }
        {
            data++
            line=$0
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
            if (line ~ /[[:space:]]/) bad()
            if (line ~ /^domain:[A-Za-z0-9_.-]+$/) next
            if (line ~ /^full:[A-Za-z0-9_.-]+$/) next
            if (line ~ /^keyword:.+$/) next
            if (line ~ /^regexp:.+$/) next
            if (line ~ /^[A-Za-z0-9_.-]+$/) next
            bad()
        }
        END {
            if (kind != "blacklist" && data < 1) exit 1
        }
    ' "$file"
}

validate_hosts_file() {
    file=$1
    if [ ! -s "$file" ] || grep -q '[<>]' "$file"; then
        log "ERROR: hosts missing or HTML-like"
        return 1
    fi
    awk '
        function valid_ip(ip, n, a, i) {
            if (ip ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) {
                n = split(ip, a, ".")
                if (n != 4) return 0
                for (i = 1; i <= 4; i++) {
                    if (a[i] !~ /^[0-9]+$/ || a[i] < 0 || a[i] > 255 || a[i] ~ /^0[0-9]/) return 0
                }
                return 1
            }
            if (ip ~ /:/ && ip ~ /^[0-9A-Fa-f:]+$/ && ip !~ /:::/) return 1
            return 0
        }
        function valid_name(name) {
            sub(/^(full:|domain:)/, "", name)
            return name ~ /^[A-Za-z0-9]([A-Za-z0-9-]{0,62}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,62}[A-Za-z0-9])?)*$/
        }
        BEGIN { data = 0 }
        /^[[:space:]]*$/ { next }
        /^[[:space:]]*#/ { next }
        {
            data++
            if (!valid_name($1) || NF < 2) exit 1
            for (i = 2; i <= NF; i++) if (!valid_ip($i)) exit 1
        }
        END { if (data < 1) exit 1 }
    ' "$file"
}

URL_whitelist=""
URL_greylist=""
URL_blacklist=""
URL_hosts=""
seen_my=""

while IFS='|' read -r target enabled url; do
    target=$(trim "$target")
    enabled=$(trim "$enabled")
    url=$(trim "$url")
    case "$target" in
        ""|\#*) continue ;;
    esac
    if ! classified=$(mosdns_sync_classify "$target"); then
        log "ERROR: reject sync target $target"
        exit 1
    fi
    area=${classified%% *}
    base=${classified#* }
    [ "$area" = "my" ] || continue
    case "$base" in
        whitelist.txt|greylist.txt|blacklist.txt|hosts.txt) ;;
        *)
            log "ERROR: my target is not one of the four lists: $base"
            exit 1
            ;;
    esac
    case " $seen_my " in
        *" $base "*)
            log "ERROR: duplicate my target $base"
            exit 1
            ;;
    esac
    seen_my="$seen_my $base"
    if [ "$enabled" != "yes" ]; then
        log "ERROR: $base must be enabled for mode 2"
        exit 1
    fi
    url_set "$base" "$url"
done < "$CONF"

for required in whitelist.txt greylist.txt blacklist.txt hosts.txt; do
    one=$(url_get "$required")
    if [ -z "$one" ]; then
        log "ERROR: sync.conf missing enabled my/$required"
        exit 1
    fi
    if ! ref=$(my_ref_for "$one" "$required"); then
        log "ERROR: $required URL is not perryyeh/mosdns my/$required"
        exit 1
    fi
    if [ "$ref" = "main" ] || [ "$ref" = "refs/heads/main" ]; then
        kind=branch
    elif is_commit_sha "$ref"; then
        kind=sha
        ref=$(printf '%s' "$ref" | tr 'A-F' 'a-f')
    else
        log "ERROR: $required ref must be main or one commit: $ref"
        exit 1
    fi
    if [ -z "${REF_KIND:-}" ]; then
        REF_KIND=$kind
        REF_VALUE=$ref
    elif [ "$REF_KIND" != "$kind" ] || [ "$REF_VALUE" != "$ref" ]; then
        log "ERROR: my URLs do not share one ref"
        exit 1
    fi
done

if [ "$REF_KIND" = "sha" ]; then
    sha=$REF_VALUE
else
    if ! fetch_url "$REPO_API" "$TMPDIR/commit.json"; then
        log "ERROR: failed to resolve perryyeh/mosdns main"
        exit 1
    fi
    sha=$(awk -F'"' '$2 == "sha" && $4 ~ /^[0-9a-fA-F]{40}$/ { print tolower($4); exit }' "$TMPDIR/commit.json")
    if [ -z "$sha" ]; then
        log "ERROR: main commit response has no sha"
        exit 1
    fi
fi
log "my snapshot $sha"

for required in whitelist.txt greylist.txt blacklist.txt hosts.txt; do
    pinned="https://raw.githubusercontent.com/perryyeh/mosdns/$sha/my/$required"
    if ! fetch_url "$pinned" "$TMPDIR/$required"; then
        log "ERROR: failed to download $required"
        exit 1
    fi
done

validate_domain_file whitelist "$TMPDIR/whitelist.txt"
validate_domain_file greylist "$TMPDIR/greylist.txt"
validate_domain_file blacklist "$TMPDIR/blacklist.txt"
validate_hosts_file "$TMPDIR/hosts.txt"

changed=0
for required in whitelist.txt greylist.txt blacklist.txt hosts.txt; do
    dest="$MY_DIR/$required"
    stage="$MY_DIR/.$required.new.$$"
    if [ -f "$dest" ] && cmp -s "$TMPDIR/$required" "$dest"; then
        continue
    fi
    cp "$TMPDIR/$required" "$stage"
    changed=1
done

if [ "$changed" -eq 0 ]; then
    log "my lists unchanged"
    exit 0
fi

for required in whitelist.txt greylist.txt blacklist.txt hosts.txt; do
    stage="$MY_DIR/.$required.new.$$"
    if [ -f "$stage" ]; then
        mv -f "$stage" "$MY_DIR/$required"
    fi
done
touch "$RELOAD_MARK"
log "my lists updated"
