# shellcheck shell=bash
#
# server.sh - talking to the game server and knowing what it is doing.
#
# The server publishes two things a manager can rely on, both discovered by
# reading its output rather than by guessing:
#
#   1. Structured events, one JSON object per line behind an @DS@ prefix:
#        @DS@{"ev":"state","phase":"serving","save":"Campaign","pw":true}
#        @DS@{"ev":"players","list":[]}
#      phase is one of boot, loading, serving.
#
#   2. A pulse line, refreshed on every campaign tick:
#        pulse: time=Spring 1, 1095 timeMode=Stop players=0 parties=1954
#
# Everything below is built on those two. The functions that wait for
# something return status codes rather than exiting, because their callers -
# update in particular - need the chance to roll back.

# ------------------------------------------------------------ server state --
ds_event() {
    container_logs_current \
        | sed -n 's/.*@DS@\({.*}\)$/\1/p' \
        | jq -c --arg ev "$1" 'select(.ev==$ev)' 2>/dev/null \
        | tail -1
}

server_phase() { ds_event state | jq -r '.phase // empty' 2>/dev/null || true; }
server_is_serving() { [[ "$(server_phase)" == "serving" ]]; }

last_pulse()  { container_logs_current | grep -a 'pulse: ' | tail -1; }
pulse_field() { last_pulse | sed -n "s/.*[[:space:]]$1=\([^[:space:]]*\).*/\1/p"; }
pulse_time()  { last_pulse | sed -n 's/.*time=\(.*\) timeMode=.*/\1/p'; }

player_count() {
    local n; n="$(pulse_field players)"
    [[ "$n" =~ ^[0-9]+$ ]] && printf '%s' "$n" || printf '0'
}

player_list() { ds_event players | jq -r '.list[]? // empty' 2>/dev/null || true; }

# The installed Coop build, read from the file the Workshop item ships.
server_version() {
    local f="$DIR_SERVER/release-info.txt" built game
    [[ -f "$f" ]] || { printf 'not installed'; return 0; }
    # The file ships with a Windows build and has CRLF line endings. A
    # trailing carriage return is invisible in a terminal but travels into
    # the JSON backup manifest and the status output, where it is not.
    built="$(sed -n 's/^Built:[[:space:]]*//p'        "$f" | tr -d '\r' | head -1)"
    game="$(sed -n 's/^Game version:[[:space:]]*//p'  "$f" | tr -d '\r' | head -1)"
    printf 'build %s / %s' "${built:-unknown}" "${game:-unknown}"
}

server_installed() { [[ -f "$DIR_SERVER/BannerlordCoopServer.exe" ]]; }

# ------------------------------------------------------------- interaction --
# Sends a command to the server console through the FIFO the entrypoint
# attached to its stdin.
server_cmd() {
    container_running || fail "$EX_RUNTIME" "The server is not running."
    docker exec "$CONTAINER_NAME" coop-cmd "$@"
}

# Forces a save AND waits until the file on disk is actually newer.
#
# A blind `save; sleep 5` would be the weakest link in the whole backup
# chain, so this watches the modification time instead.
server_save() {
    local timeout="${1:-120}" name file before=0 waited=0
    name="$(cfg SAVE_NAME)"
    [[ -n "$name" ]] || { warn "SAVE_NAME is empty; cannot verify the save."; return 1; }
    file="$DIR_SAVES/${name}.sav"
    [[ -f "$file" ]] && before="$(stat -c %Y "$file")"

    log "Requesting save of '$name'"
    server_cmd save >/dev/null || return 1

    while (( waited < timeout )); do
        sleep 2; waited=$(( waited + 2 ))
        if [[ -f "$file" ]] && (( $(stat -c %Y "$file") > before )); then
            ok "Save written after ${waited}s ($(human_size_simple "$(stat -c %s "$file")"))"
            return 0
        fi
    done
    warn "No new save appeared within ${timeout}s"
    return 1
}

# ---------------------------------------------------------- start and stop --
# Waits until the server actually serves clients - not merely until the
# container is up. Loading a grown campaign takes about two minutes.
#
#   0  serving
#   1  timed out
#   2  the container stopped on its own
#   3  the container is crash looping
wait_serving() {
    local timeout="${1:-600}" waited=0 restarts_before restarts_now
    restarts_before="$(container_restart_count)"

    while (( waited < timeout )); do
        container_running || return 2
        server_is_serving && return 0

        # A crash loop is not a slow start. With restart:unless-stopped a
        # container that dies on every attempt still reads as "running"
        # between attempts, so without this the full timeout would elapse
        # before anyone was told - ten minutes before an update rolls back.
        restarts_now="$(container_restart_count)"
        if (( restarts_now - restarts_before >= 3 )); then
            return 3
        fi

        sleep 5; waited=$(( waited + 5 ))
    done
    return 1
}

server_start() {
    local timeout="${1:-600}"
    docker_require
    server_installed || fail "$EX_RUNTIME" \
        "No server files found in $DIR_SERVER." \
        "Install them first: coop update --force"

    log "Starting the server"
    dc up -d --remove-orphans >/dev/null 2>&1 \
        || { warn "docker compose up failed"; return 1; }

    local rc=0
    wait_serving "$timeout" || rc=$?
    case "$rc" in
        0) # The campaign date comes from the pulse line, which has not
           # necessarily been printed yet the moment the server starts
           # serving - so it is appended only when there is one.
           local when; when="$(pulse_time)"
           ok "Server is serving ('$(cfg SAVE_NAME)'${when:+, $when})"
           return 0 ;;
        3) # Mid-restart, the reported exit code is whatever Docker happened
           # to be holding, so it is not worth printing. The log is.
           warn "The server is not starting: the container exits at once and Docker keeps restarting it."
           out_line "    See what it says:  coop logs -n 50"
           return 2 ;;
        2) warn "The container exited during start-up (exit $(container_exitcode))."
           _explain_exit_code "$(container_exitcode)"
           return 2 ;;
        *) warn "The server did not reach 'serving' within ${timeout}s."
           return 1 ;;
    esac
}

# The server's own exit codes. Naming them turns a support question into a
# one-line answer.
_explain_exit_code() {
    case "${1:-}" in
        2) out_line "    Exit 2: the save could not be loaded, or loading timed out." ;;
        3) out_line "    Exit 3: the server failed while running. See 'coop logs'." ;;
        4) out_line "    Exit 4: the Coop assemblies do not match the release - files under"
           out_line "            Modules/Coop were modified. Try 'coop update --force' or"
           out_line "            'coop rollback'." ;;
        137) out_line "    Exit 137: the container was killed. This should not happen with the"
             out_line "              console shutdown path; please report it." ;;
    esac
}

# Stops through the server console, never by signal alone: the entrypoint
# turns SIGTERM into a console "stop" and waits for the closing save.
server_stop() {
    if ! container_running; then
        log "The server is already stopped."
        return 0
    fi
    log "Stopping the server (console shutdown, with a closing save)"
    dc stop >/dev/null 2>&1 || true

    local code; code="$(container_exitcode)"
    if [[ "$code" == "0" ]]; then
        ok "Server stopped cleanly"
        return 0
    fi
    warn "The server exited with code $code"
    _explain_exit_code "$code"
    return 0
}

# --------------------------------------------------- the game's own config --
# server-config.json is JSONC: it carries comments and trailing commas, so
# jq cannot read it and an in-place regex edit is how a campaign gets lost.
# The manager therefore *generates* it from templates/server-config.json.tmpl
# and owns the file; users change config/server.env instead.
server_config_render() {
    local tmpl="${COOP_ROOT}/templates/server-config.json.tmpl"
    [[ -f "$tmpl" ]] || fail "$EX_CONFIG" "Missing template: $tmpl"

    mkdir -p "$DIR_CONFIG"
    [[ -f "$FILE_SERVER_JSON" ]] && cp -a "$FILE_SERVER_JSON" "${FILE_SERVER_JSON}.bak"

    local pw; pw="$(cfg SERVER_PASSWORD)"
    # JSON string escaping for the two characters that can occur in a
    # password and would otherwise break the file.
    pw="${pw//\\/\\\\}"; pw="${pw//\"/\\\"}"
    local save; save="$(cfg SAVE_NAME)"
    save="${save//\\/\\\\}"; save="${save//\"/\\\"}"

    # Substitution is literal on purpose. awk's gsub() treats '&' in the
    # replacement as "the text that matched" and eats backslashes, so a
    # password of "a&b" would silently become "a@@SERVER_PASSWORD@@b".
    # Values reach awk through the environment, which skips -v's escape
    # processing as well.
    COOP_T_SAVE="$save" \
    COOP_T_PASSWORD="$pw" \
    COOP_T_PORT="$(cfg GAME_PORT)" \
    COOP_T_AUTOSAVE="$(cfg AUTOSAVE_MINUTES)" \
    COOP_T_STEAM="$(cfg STEAM_ADVERTISE)" \
    COOP_T_LOGFILE="$(cfg SERVER_LOG_FILE)" \
    awk '
        function lit(s, from, to,   p, out) {
            while ((p = index(s, from)) > 0) {
                out = out substr(s, 1, p - 1) to
                s = substr(s, p + length(from))
            }
            return out s
        }
        {
            $0 = lit($0, "@@SAVE_NAME@@",        ENVIRON["COOP_T_SAVE"])
            $0 = lit($0, "@@SERVER_PASSWORD@@",  ENVIRON["COOP_T_PASSWORD"])
            $0 = lit($0, "@@GAME_PORT@@",        ENVIRON["COOP_T_PORT"])
            $0 = lit($0, "@@AUTOSAVE_MINUTES@@", ENVIRON["COOP_T_AUTOSAVE"])
            $0 = lit($0, "@@STEAM_ADVERTISE@@",  ENVIRON["COOP_T_STEAM"])
            $0 = lit($0, "@@SERVER_LOG_FILE@@",  ENVIRON["COOP_T_LOGFILE"])
            print
        }
    ' "$tmpl" >"${FILE_SERVER_JSON}.tmp" \
        || fail "$EX_CONFIG" "Could not render $FILE_SERVER_JSON"

    # A placeholder left behind means the template and the renderer have
    # drifted apart - better to catch it here than at the next server start.
    if grep -q '@@[A-Z_]*@@' "${FILE_SERVER_JSON}.tmp"; then
        rm -f "${FILE_SERVER_JSON}.tmp"
        fail "$EX_CONFIG" "Template placeholders were left unfilled - this is a bug in the manager."
    fi

    chown "$(cfg PUID):$(cfg PGID)" "${FILE_SERVER_JSON}.tmp" 2>/dev/null || true
    chmod 0640 "${FILE_SERVER_JSON}.tmp"
    mv -f "${FILE_SERVER_JSON}.tmp" "$FILE_SERVER_JSON"
    debug "rendered $FILE_SERVER_JSON"
}
