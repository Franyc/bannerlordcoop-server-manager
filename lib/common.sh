# shellcheck shell=bash
#
# common.sh - foundation for every other library: exit codes, logging,
# locking, temporary files and the interaction guard rails.
#
# Sourced by bin/coop. Never executed directly.
#
# The one rule this file exists to enforce: nothing below the collection
# layer may ever prompt. Functions here either succeed, or they fail with a
# specific exit code that automation can act on.

# --------------------------------------------------------------- exit codes --
# Automation must be able to tell failure classes apart, so every failure
# path in this project ends in exactly one of these.
readonly EX_OK=0                 # success
readonly EX_USAGE=2              # wrong invocation: unknown command, missing argument
readonly EX_CONFIG=10            # invalid configuration, or a required value is missing
readonly EX_DEPS=20              # unsupported system, or a dependency is unavailable
readonly EX_STEAM=30             # Steam authentication or download failed
readonly EX_RUNTIME=40           # container or server process failure
readonly EX_HEALTH=50            # health check failed
readonly EX_BACKUP=60            # backup or restore failed
readonly EX_LOCKED=70            # another operation holds the lock
readonly EX_UPDATE_AVAILABLE=100 # only with `update --check --exit-status`

# ------------------------------------------------------------------ globals --
# Set by bin/coop from the command line before anything else runs.
: "${NON_INTERACTIVE:=0}"
: "${ASSUME_YES:=0}"
: "${QUIET:=0}"
: "${VERBOSE:=0}"
: "${OUTPUT_FORMAT:=human}"

# Populated by config_load(). Declared here so `set -u` never bites.
: "${INSTALL_DIR:=}"
: "${INSTANCE_ID:=}"

MANAGER_VERSION="$(cat "${COOP_ROOT}/VERSION" 2>/dev/null || echo "0.0.0-dev")"
readonly MANAGER_VERSION

# ------------------------------------------------------------------- colour --
# Colour is a courtesy for humans at a terminal. Anything else - a pipe, a
# systemd unit, a hosting backend - gets plain text.
if [[ -t 2 && "${OUTPUT_FORMAT}" == "human" && -z "${NO_COLOR:-}" ]]; then
    C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
    C_BLU=$'\033[34m'; C_DIM=$'\033[2m';  C_BLD=$'\033[1m'; C_OFF=$'\033[0m'
else
    C_RED=''; C_GRN=''; C_YEL=''; C_BLU=''; C_DIM=''; C_BLD=''; C_OFF=''
fi

# ------------------------------------------------------------------ logging --
# Everything the manager does goes to stderr and, once an installation
# exists, to a log file. stdout stays clean so `--json` output can be piped.

COOP_LOG_FILE=""

log_open() {
    local dir="${1:-}/logs"
    [[ -n "${1:-}" && -d "$dir" ]] || return 0
    COOP_LOG_FILE="$dir/manager.log"
    touch "$COOP_LOG_FILE" 2>/dev/null || COOP_LOG_FILE=""
}

_log_write() {
    [[ -n "$COOP_LOG_FILE" ]] || return 0
    printf '%s  %-5s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2" >>"$COOP_LOG_FILE" 2>/dev/null || true
}

log()   { _log_write INFO "$*";  [[ "$QUIET" == 1 ]] && return 0; printf '%s\n' "$*" >&2; }
step()  { _log_write STEP "$*";  [[ "$QUIET" == 1 ]] && return 0; printf '\n%s==>%s %s%s%s\n' "$C_BLU" "$C_OFF" "$C_BLD" "$*" "$C_OFF" >&2; }
ok()    { _log_write OK   "$*";  [[ "$QUIET" == 1 ]] && return 0; printf '  %s+%s %s\n' "$C_GRN" "$C_OFF" "$*" >&2; }
warn()  { _log_write WARN "$*";  printf '  %s!%s %s\n' "$C_YEL" "$C_OFF" "$*" >&2; }
error() { _log_write ERROR "$*"; printf '  %sx%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; }
debug() { [[ "$VERBOSE" == 1 ]] || return 0; _log_write DEBUG "$*"; printf '  %s%s%s\n' "$C_DIM" "$*" "$C_OFF" >&2; }

# die <exit-code> <message> [hint...]
#
# Ends the run with a specific code. Extra arguments are printed as
# indented follow-up lines - use them to say what to do next, never to
# restate the failure.
die() {
    local code="$1"; shift
    error "$1"; shift
    local line
    for line in "$@"; do
        [[ "$QUIET" == 1 ]] || printf '    %s%s%s\n' "$C_DIM" "$line" "$C_OFF" >&2
        _log_write ERROR "  $line"
    done
    exit "$code"
}

# ------------------------------------------------------------ preconditions --
require_root() {
    [[ "$(id -u)" -eq 0 ]] || die "$EX_USAGE" \
        "This command must be run as root." \
        "Try: sudo coop ${COOP_COMMAND:-<command>}"
}

require_cmd() {
    local cmd missing=()
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    (( ${#missing[@]} == 0 )) || die "$EX_DEPS" \
        "Missing required command(s): ${missing[*]}" \
        "Run 'coop doctor' to see what your system is missing."
}

# ----------------------------------------------------------------- locking --
# Start, stop, update, backup and restore all touch the same files. One lock
# per installation, not one per operation: an hourly backup timer must never
# be able to fire in the middle of an update.
_LOCK_FD=""

acquire_lock() {
    local what="${1:-operation}" lock_dir="/run/lock" lock
    [[ -d "$lock_dir" ]] || lock_dir="/tmp"
    lock="${lock_dir}/bannerlordcoop-${INSTANCE_ID:-default}.lock"

    exec {_LOCK_FD}>"$lock" || die "$EX_RUNTIME" \
        "Cannot create lock file: $lock" \
        "This usually means the command was not run as root."

    if ! flock -n "$_LOCK_FD"; then
        die "$EX_LOCKED" \
            "Another operation is already running for instance '${INSTANCE_ID:-default}'." \
            "Wait for it to finish, then retry: coop $what"
    fi
    debug "lock acquired: $lock"
}

# ------------------------------------------------- temporary files and traps --
# Every temporary directory is registered here, so an interrupt cannot leave
# half-written state behind.
_CLEANUP_PATHS=()

cleanup_register() { _CLEANUP_PATHS+=("$1"); }

cleanup_run() {
    local p
    for p in "${_CLEANUP_PATHS[@]:-}"; do
        [[ -n "$p" && -e "$p" ]] || continue
        rm -rf -- "$p" 2>/dev/null || true
    done
    _CLEANUP_PATHS=()
}

# make_temp_dir [parent]
#
# Pass the parent when the result will later be moved into place: a rename
# is only atomic within one filesystem.
make_temp_dir() {
    local parent="${1:-${TMPDIR:-/tmp}}" d
    mkdir -p -- "$parent" || die "$EX_RUNTIME" "Cannot create directory: $parent"
    d="$(mktemp -d "${parent}/.coop-tmp.XXXXXXXX")" \
        || die "$EX_RUNTIME" "Cannot create a temporary directory in $parent"
    cleanup_register "$d"
    printf '%s\n' "$d"
}

install_traps() {
    trap 'cleanup_run' EXIT
    trap 'cleanup_run; exit 130' INT
    trap 'cleanup_run; exit 143' TERM
}

# ------------------------------------------------------------- interaction --
# The single place that decides whether asking is allowed. Everything below
# the collection layer calls confirm() rather than read, so --non-interactive
# is honoured in exactly one implementation.

is_interactive() { [[ "$NON_INTERACTIVE" != 1 && -t 0 ]]; }

# confirm <question> [default:yes|no]
#
# In non-interactive mode this never prompts: it returns the answer implied
# by --yes, or fails with EX_CONFIG. A hidden confirmation would be worse
# than an error.
confirm() {
    local question="$1" default="${2:-no}" reply prompt

    if [[ "$ASSUME_YES" == 1 ]]; then
        debug "confirm: assuming yes ($question)"
        return 0
    fi
    if ! is_interactive; then
        die "$EX_CONFIG" \
            "This operation needs confirmation: $question" \
            "Re-run with --yes to confirm it without a prompt."
    fi

    [[ "$default" == "yes" ]] && prompt="[Y/n]" || prompt="[y/N]"
    printf '%s %s ' "$question" "$prompt" >&2
    read -r reply || reply=""
    reply="${reply,,}"
    [[ -z "$reply" ]] && reply="$default"
    [[ "$reply" == "y" || "$reply" == "yes" ]]
}

# ask <variable-name> <question> [default]
#
# Reads a visible value. Callers must have checked is_interactive first;
# this refuses rather than hanging on a closed stdin.
ask() {
    local __var="$1" question="$2" default="${3:-}" reply
    is_interactive || die "$EX_CONFIG" \
        "Missing value for: $question" \
        "In non-interactive mode every required value must be passed as a flag."
    if [[ -n "$default" ]]; then
        printf '%s [%s]: ' "$question" "$default" >&2
    else
        printf '%s: ' "$question" >&2
    fi
    read -r reply || reply=""
    [[ -z "$reply" ]] && reply="$default"
    printf -v "$__var" '%s' "$reply"
}

# ask_secret <variable-name> <question>
#
# Hidden input. The value stays in the named variable only; callers are
# expected to unset it as soon as it has been used.
ask_secret() {
    local __var="$1" question="$2" reply
    is_interactive || die "$EX_CONFIG" \
        "Missing value for: $question" \
        "In non-interactive mode this value must be supplied explicitly."
    printf '%s: ' "$question" >&2
    read -rs reply || reply=""
    printf '\n' >&2
    printf -v "$__var" '%s' "$reply"
}

# ------------------------------------------------------------------ helpers --
human_size() {
    local bytes="${1:-0}"
    if   (( bytes >= 1073741824 )); then printf '%.1f GB' "$(bc -l <<<"$bytes/1073741824")"
    elif (( bytes >= 1048576 ));    then printf '%.0f MB' "$(bc -l <<<"$bytes/1048576")"
    elif (( bytes >= 1024 ));       then printf '%.0f KB' "$(bc -l <<<"$bytes/1024")"
    else printf '%d B' "$bytes"
    fi
}

# Deliberately arithmetic-only: bc is not installed everywhere.
human_size_simple() {
    local b="${1:-0}"
    if   (( b >= 1073741824 )); then printf '%d.%d GB' $(( b / 1073741824 )) $(( (b % 1073741824) * 10 / 1073741824 ))
    elif (( b >= 1048576 ));    then printf '%d MB' $(( b / 1048576 ))
    elif (( b >= 1024 ));       then printf '%d KB' $(( b / 1024 ))
    else printf '%d B' "$b"
    fi
}

human_duration() {
    local s="${1:-0}"
    if   (( s < 60 ));    then printf '%ds' "$s"
    elif (( s < 3600 ));  then printf '%dm %ds' $(( s / 60 )) $(( s % 60 ))
    elif (( s < 86400 )); then printf '%dh %dm' $(( s / 3600 )) $(( (s % 3600) / 60 ))
    else printf '%dd %dh' $(( s / 86400 )) $(( (s % 86400) / 3600 ))
    fi
}

human_ago() {
    local then_ts="${1:-0}" now
    now="$(date +%s)"
    (( then_ts > 0 )) || { printf 'never'; return; }
    printf '%s ago' "$(human_duration $(( now - then_ts )))"
}

# Writes a file only if the complete content was produced: temp file in the
# same directory, then rename. A half-written config is worse than none.
write_atomic() {
    local target="$1" tmp
    tmp="$(mktemp "${target}.XXXXXX")" || die "$EX_RUNTIME" "Cannot write to $(dirname "$target")"
    cat >"$tmp" || { rm -f "$tmp"; die "$EX_RUNTIME" "Failed while writing $target"; }
    chmod --reference="$target" "$tmp" 2>/dev/null || chmod 0644 "$tmp"
    mv -f "$tmp" "$target" || { rm -f "$tmp"; die "$EX_RUNTIME" "Failed to replace $target"; }
}
