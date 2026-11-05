#!/bin/sh
# Classify one sync.conf target.
# Prints "rule <file>" or "my <file>". Legacy bare filenames mean rule/<file>.
# Rejects absolute paths, "..", and every directory other than rule/ or my/.

mosdns_sync_classify() {
    raw=$1
    raw=$(printf '%s' "$raw" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    case "$raw" in
        ""|\#*)
            return 1
            ;;
        /*|./*|../*|..|*/..|*/../*|*\\*)
            return 1
            ;;
        *..*)
            return 1
            ;;
    esac

    case "$raw" in
        rule/*)
            area=rule
            rest=${raw#rule/}
            ;;
        my/*)
            area=my
            rest=${raw#my/}
            ;;
        */*)
            return 1
            ;;
        *)
            area=rule
            rest=$raw
            ;;
    esac

    case "$rest" in
        ""|.*|*/|*/*|*..*)
            return 1
            ;;
        *[!A-Za-z0-9._-]*)
            return 1
            ;;
    esac
    printf '%s %s\n' "$area" "$rest"
}
