#!/usr/bin/env bash
#
# Prints the settings reference as Markdown, straight from the single
# source of truth: the specification in lib/config.sh and the defaults in
# config/defaults.env.
#
# docs/CONFIGURATION.md embeds the result between the marker comments
# below, and CI regenerates and diffs it - so the documentation cannot
# quietly fall behind the code.
#
#   tools/gen-config-docs.sh --check   compare, exit 1 on drift
#   tools/gen-config-docs.sh --write   update docs/CONFIGURATION.md

set -euo pipefail
COOP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export COOP_ROOT
# shellcheck source=/dev/null
. "$COOP_ROOT/lib/common.sh"
# shellcheck source=/dev/null
. "$COOP_ROOT/lib/output.sh"
# shellcheck source=/dev/null
. "$COOP_ROOT/lib/config.sh"

config_parse_file "$COOP_ROOT/config/defaults.env"

generate() {
    printf '| Setting | Default | Type | Restart required | Description |\n'
    printf '|---|---|---|---|---|\n'
    local key default type restart desc
    while IFS= read -r key; do
        default="${CFG[$key]:-}"
        [[ -z "$default" ]] && default='_(empty)_' || default="\`${default}\`"
        type="$(config_effective_type "$key")"
        if config_is_enum "$key"; then
            type="one of: $(_enum_values "$key" | sed 's/,/, /g')"
        fi
        case "$(config_restart "$key")" in
            yes)     restart='Yes' ;;
            install) restart='Install only' ;;
            *)       restart='No' ;;
        esac
        desc="$(config_describe "$key")"
        printf '| `%s` | %s | %s | %s | %s |\n' "$key" "$default" "$type" "$restart" "$desc"
    done < <(config_keys)
}

TARGET="$COOP_ROOT/docs/CONFIGURATION.md"
BEGIN='<!-- BEGIN GENERATED SETTINGS -->'
END='<!-- END GENERATED SETTINGS -->'

case "${1:---print}" in
    --print) generate ;;
    --write)
        [[ -f "$TARGET" ]] || { echo "missing $TARGET" >&2; exit 1; }
        tmp="$(mktemp)"
        awk -v b="$BEGIN" -v e="$END" -v f="$(generate)" '
            $0 == b { print; print f; skip = 1; next }
            $0 == e { skip = 0 }
            !skip   { print }
        ' "$TARGET" >"$tmp"
        mv -f "$tmp" "$TARGET"
        echo "updated $TARGET"
        ;;
    --check)
        [[ -f "$TARGET" ]] || { echo "missing $TARGET" >&2; exit 1; }
        current="$(awk -v b="$BEGIN" -v e="$END" '$0==e{p=0} p; $0==b{p=1}' "$TARGET")"
        if [[ "$current" == "$(generate)" ]]; then
            echo "docs/CONFIGURATION.md is up to date"
        else
            echo "docs/CONFIGURATION.md is out of date - run tools/gen-config-docs.sh --write" >&2
            diff <(printf '%s\n' "$current") <(generate) || true
            exit 1
        fi
        ;;
    *) echo "usage: $0 [--print|--write|--check]" >&2; exit 2 ;;
esac
