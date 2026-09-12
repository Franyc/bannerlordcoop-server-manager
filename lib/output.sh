# shellcheck shell=bash
#
# output.sh - the single place that knows whether a human or a machine is
# reading. Commands describe *what* they found; this file decides how it
# looks.
#
# Human output goes to stdout as aligned key/value lines. Machine output is
# a single JSON document, also on stdout, with nothing else mixed in - which
# is why every log and progress line in this project goes to stderr.

is_json() { [[ "$OUTPUT_FORMAT" == "json" ]]; }

# ------------------------------------------------------------------- human --
out_title() {
    is_json && return 0
    printf '\n%s%s%s\n\n' "$C_BLD" "$1" "$C_OFF"
}

out_section() {
    is_json && return 0
    printf '%s%s%s\n' "$C_DIM" "$1" "$C_OFF"
}

# out_kv <label> <value> [colour]
out_kv() {
    is_json && return 0
    local colour="${3:-}"
    printf '  %-18s %s%s%s\n' "$1" "$colour" "$2" "${colour:+$C_OFF}"
}

out_line() {
    is_json && return 0
    printf '%s\n' "${1:-}"
}

# out_check <ok|todo|warn|fail> <message>
#
# 'todo' is for something the installer is about to do on purpose - a
# missing dependency it will install. Reporting that as a warning makes
# every clean host ask "continue despite warnings?", which is noise for a
# person and a hard stop for automation.
#
# Used by doctor and by the installer's validation step. The mark carries
# the state, so the text does not have to repeat it.
out_check() {
    is_json && return 0
    case "$1" in
        ok)   printf '  %s+%s %s\n'  "$C_GRN" "$C_OFF" "$2" ;;
        todo) printf '  %s>%s %s\n'  "$C_BLU" "$C_OFF" "$2" ;;
        warn) printf '  %s!%s %s\n'  "$C_YEL" "$C_OFF" "$2" ;;
        fail) printf '  %sx%s %s\n'  "$C_RED" "$C_OFF" "$2" ;;
        *)    printf '    %s\n' "$2" ;;
    esac
}

# out_table <header-row> <row>...
#
# Rows are tab-separated. Columns are padded to the widest cell so numbers
# line up without needing an external formatter.
out_table() {
    is_json && return 0
    local rows=("$@")
    [[ ${#rows[@]} -gt 0 ]] || return 0
    printf '%s\n' "${rows[@]}" | column -t -s $'\t' 2>/dev/null \
        || printf '%s\n' "${rows[@]}"
}

# -------------------------------------------------------------------- json --
# Built with jq rather than string concatenation: values come from server
# logs, file names and user input, and hand-rolled escaping is exactly how
# malformed JSON reaches an automation pipeline.

# json_emit <jq-filter> [jq-args...]
#
#   json_emit '{status:$s, players:($p|tonumber)}' --arg s online --arg p 3
json_emit() {
    local filter="$1"; shift
    jq -n "$@" "$filter"
}

# json_error <exit-code> <message>
#
# Machine-readable failure. Commands that support --json call this instead
# of die() when the format is json, so a caller always gets a parsable body.
json_error() {
    local code="$1" msg="$2"
    jq -n --argjson code "$code" --arg error "$msg" '{ok:false, exit_code:$code, error:$error}'
    exit "$code"
}

# fail <exit-code> <message> [hint...]
#
# Format-aware failure: JSON body for machines, die() for humans. Prefer
# this in any command that advertises --json.
fail() {
    if is_json; then
        json_error "$1" "$2"
    fi
    die "$@"
}
