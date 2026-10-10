#!/usr/bin/env bash
#
# Entrypoint for the Bannerlord Coop dedicated server running under Wine.
#
# WHY A WRAPPER IS NEEDED
# -----------------------
# Signals do not stop this server. `docker compose stop` ran into its 120 s
# timeout and ended in exit 137 - a SIGKILL, possibly in the middle of
# writing a save. PID 1 ignores signals without a handler of its own, and
# Wine does not forward them to the Windows process.
#
# The server does have a console:
#     status  players  save  say  kick  stop  help
#
# So this wrapper attaches a FIFO to the server's stdin. On SIGTERM it
# writes "stop" and waits for the server to finish its closing save. The
# same channel lets the manager trigger a save before a backup:
#
#     docker exec <container> coop-cmd save
#
# Measured result of the change: 2 seconds, exit 0, save written.

set -uo pipefail

SERVER_EXE="${SERVER_EXE:-/server/BannerlordCoopServer.exe}"
DATA_DIR="${DATA_DIR:-Z:\\data}"
STOP_TIMEOUT="${STOP_TIMEOUT:-150}"
FIFO="${COOP_FIFO:-/tmp/coop.cmd}"

rm -f "$FIFO"
mkfifo -m 0600 "$FIFO"

# Hold both ends open. With only a writer attached, the server would see
# EOF on stdin every time a command finished writing.
exec 3<>"$FIFO"

log() { printf '[entrypoint] %s\n' "$*"; }

graceful_stop() {
    log "signal received, sending 'stop' to the server console"
    printf 'stop\n' >&3
    local waited=0
    while kill -0 "$SRV" 2>/dev/null && (( waited < STOP_TIMEOUT )); do
        sleep 1
        waited=$(( waited + 1 ))
    done

    if kill -0 "$SRV" 2>/dev/null; then
        log "no response after ${STOP_TIMEOUT}s, terminating"
        kill -TERM "$SRV" 2>/dev/null || true
        sleep 5
        kill -KILL "$SRV" 2>/dev/null || true
    else
        log "server stopped cleanly after ${waited}s"
    fi

    wait "$SRV" 2>/dev/null
    local code=$?
    log "exit code $code"
    exit "$code"
}

if [[ ! -f "$SERVER_EXE" ]]; then
    log "server executable not found: $SERVER_EXE"
    log "the server files are missing. Run 'coop update --force' on the host"
    exit 2
fi

log "starting: wine $SERVER_EXE --data-dir $DATA_DIR"
wine "$SERVER_EXE" --data-dir "$DATA_DIR" <&3 &
SRV=$!
trap graceful_stop TERM INT

wait "$SRV"
CODE=$?
log "server process ended, exit code $CODE"

# The server's own exit codes, worth naming in the log because the most
# common one is easy to misread as a crash:
#   0  clean shutdown
#   2  load error or timeout
#   3  runtime failure
#   4  module verification failed - files under Modules/Coop were modified
#   6  the license terms of this build have not been accepted
case "$CODE" in
    4) log "exit 4 means the Coop assemblies do not match the release." \
           "Run 'coop update --force' or 'coop rollback' on the host." ;;
    6) log "exit 6 means the license terms of this build have not been accepted." \
           "Run 'coop eula' on the host." ;;
esac
exit "$CODE"
