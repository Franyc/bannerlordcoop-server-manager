# shellcheck shell=bash
#
# update.sh - installing a new server build, and going back.
#
# UPDATE AND ROLLBACK ARE NOT RESTORE
# -----------------------------------
#   coop update / coop rollback   move the SOFTWARE forward or back
#   coop backup restore           puts SAVES AND CONFIGURATION back
# They never touch each other's territory. An update carries the campaign
# across untouched; a restore leaves the installed build alone.
#
# WHY UPDATES ARE NOT AUTOMATIC BY DEFAULT
# ----------------------------------------
# The server verifies its own Coop assemblies, and clients have to run the
# same build. An unattended nightly update would lock out every player who
# has not updated yet. So the check runs on a schedule and reports; the
# update itself is a decision.

# ----------------------------------------------------------- version check --
_fmt_ts() {
    [[ "${1:-0}" =~ ^[0-9]+$ ]] && (( $1 > 0 )) \
        && date -d "@$1" '+%Y-%m-%d %H:%M' || printf 'unknown'
}

# update_available
#   0  a newer version exists
#   1  up to date
#   2  cannot tell (Steam unreachable)
update_available() {
    local local_ts remote_ts
    local_ts="$(workshop_local_time)"
    remote_ts="$(workshop_remote_time || true)"

    [[ -n "$remote_ts" ]] || return 2
    debug "installed $(_fmt_ts "$local_ts") / workshop $(_fmt_ts "$remote_ts")"
    (( remote_ts > local_ts ))
}

# update_check [--exit-status]
#
# Exit code 0 means THE CHECK SUCCEEDED, which is the convention every
# other tool follows; whether an update exists is in the output. Scripts
# that want it as a code ask for --exit-status and get 100.
#
# shellcheck disable=SC2120  # called with --exit-status from bin/coop
update_check() {
    local exit_status=0
    [[ "${1:-}" == "--exit-status" ]] && exit_status=1

    [[ "$(cfg INSTALL_CHANNEL)" == "workshop" ]] || {
        is_json && json_emit '{ok:true, channel:$c, update_available:false, reason:"not the workshop channel"}' --arg c "$(cfg INSTALL_CHANNEL)"
        out_line "Install channel is '$(cfg INSTALL_CHANNEL)'; there is nothing to check against."
        return 0
    }

    local rc=0 local_ts remote_ts
    update_available || rc=$?
    local_ts="$(workshop_local_time)"
    remote_ts="$(workshop_remote_time || true)"

    if (( rc == 2 )); then
        update_marker_clear
        if is_json; then
            json_emit '{ok:false, update_available:null, error:"Steam API unreachable"}'
        fi
        warn "Could not reach the Steam API; update status is unknown."
        return "$EX_STEAM"
    fi

    if (( rc == 0 )); then
        update_marker_set
        if is_json; then
            json_emit '{ok:true, update_available:true, installed:$i, available:$a}' \
                --arg i "$(_fmt_ts "$local_ts")" --arg a "$(_fmt_ts "$remote_ts")"
        else
            out_line "A Workshop update is available."
            out_line "  installed: $(_fmt_ts "$local_ts")"
            out_line "  available: $(_fmt_ts "$remote_ts")"
            out_line ""
            out_line "  Install it with: coop update"
            out_line "  Remember that every player needs the same Coop build."
        fi
        (( exit_status )) && return "$EX_UPDATE_AVAILABLE"
        return 0
    fi

    update_marker_clear
    if is_json; then
        json_emit '{ok:true, update_available:false, installed:$i}' --arg i "$(_fmt_ts "$local_ts")"
    else
        out_line "The server is up to date (installed $(_fmt_ts "$local_ts"))."
    fi
    return 0
}

# update_scheduled
#
# What the systemd timer runs. The decision of whether to install lives
# here rather than in the unit file, so changing AUTO_UPDATE takes effect
# without touching systemd.
update_scheduled() {
    local rc=0
    update_check || rc=$?

    # 30 means Steam was unreachable - weather, not a failure. The unit
    # declares it a success for exactly this reason.
    (( rc == EX_STEAM )) && return "$EX_STEAM"

    if update_marker_is_set && cfg_bool AUTO_UPDATE; then
        log "AUTO_UPDATE is enabled - installing the update now."
        update_apply
        return $?
    fi

    if update_marker_is_set; then
        log "An update is available. Install it with 'coop update' once every player can update too."
    fi
    return 0
}

# ---------------------------------------------------------------- rollback --
rollback_available() { [[ -f "$DIR_ROLLBACK/BannerlordCoopServer.exe" ]]; }

# rollback_apply [--auto]
#
# --auto is the path taken by a failed update: no questions, because the
# decision was already made by the failure.
rollback_apply() {
    local auto=0
    [[ "${1:-}" == "--auto" ]] && auto=1

    rollback_available || fail "$EX_RUNTIME" \
        "There is no previous version to roll back to." \
        "A rollback copy is created the first time you run 'coop update'."

    if (( ! auto )); then
        out_title "Roll back to the previous server build"
        out_line "  Current : $(server_version)"
        out_line "  Previous: $(_rollback_version)"
        out_line ""
        out_line "  This replaces the server software. Campaign saves are not touched."
        out_line ""
        confirm "Continue?" no || { log "Cancelled."; return 0; }
    fi

    server_stop
    log "Restoring the previous server build"
    rsync -a --delete \
        --exclude 'mod-config.json.bak' --exclude '.timeupdated' \
        "$DIR_ROLLBACK/" "$DIR_SERVER/" \
        || fail "$EX_RUNTIME" "Could not restore the previous build."

    if [[ -f "$DIR_ROLLBACK/mod-config.json.bak" ]]; then
        cp -a "$DIR_ROLLBACK/mod-config.json.bak" "$FILE_MOD_JSON"
        log "Restored the gameplay configuration that went with that build."
    fi
    chown -R "$(cfg PUID):$(cfg PGID)" "$DIR_SERVER" "$DIR_COOPDATA" 2>/dev/null || true

    if [[ -f "$DIR_ROLLBACK/.timeupdated" ]]; then
        state_set workshop_version "$(cat "$DIR_ROLLBACK/.timeupdated")"
    fi
    state_set installed_version "$(server_version)"

    server_start || fail "$EX_HEALTH" \
        "The previous build did not start either." \
        "Inspect the logs: coop logs"

    ok "Rolled back to $(server_version)"
}

_rollback_version() {
    local f="$DIR_ROLLBACK/release-info.txt" built
    [[ -f "$f" ]] || { printf 'unknown'; return; }
    built="$(sed -n 's/^Built:[[:space:]]*//p' "$f" | tr -d '\r' | head -1)"
    printf 'build %s' "${built:-unknown}"
}

# ------------------------------------------------------------------ update --
# shellcheck disable=SC2120  # called with --force from bin/coop
update_apply() {
    local force=0 arg
    for arg in "$@"; do
        case "$arg" in
            --force) force=1 ;;
            *) fail "$EX_USAGE" "Unknown option for update: $arg" ;;
        esac
    done

    local rc=0
    update_available || rc=$?

    if (( rc == 1 && ! force )); then
        update_marker_clear
        out_line "The server is already up to date. Nothing to do."
        return 0
    fi
    if (( rc == 2 && ! force )); then
        fail "$EX_STEAM" \
            "Could not determine whether an update exists - the Steam API is unreachable." \
            "Retry later, or force the update with: coop update --force"
    fi

    out_title "Workshop update"

    # 1. stop cleanly - this writes a closing save
    server_stop

    # 2. campaign, configuration and gameplay settings first
    log "Creating a pre-update backup"
    backup_create pre-update "before Workshop update" >/dev/null

    # 3. keep the working build so a failure has somewhere to go back to.
    #    A directory copy costs disk but turns a rollback into a rename
    #    instead of a 6 GB download.
    log "Copying the current build to rollback/"
    mkdir -p "$DIR_ROLLBACK"
    rsync -a --delete "$DIR_SERVER/" "$DIR_ROLLBACK/" \
        || fail "$EX_RUNTIME" "Could not create the rollback copy; stopping before anything changed."
    cp -a "$FILE_MOD_JSON" "$DIR_ROLLBACK/mod-config.json.bak" 2>/dev/null || true
    workshop_local_time >"$DIR_ROLLBACK/.timeupdated"

    local modcfg_before
    modcfg_before="$(md5sum "$FILE_MOD_JSON" 2>/dev/null | cut -d' ' -f1 || true)"

    # 4. fetch
    if ! source_fetch; then
        warn "Download failed - restarting the current version."
        server_start || fail "$EX_RUNTIME" "The current version did not restart. Check: coop logs"
        return "$EX_STEAM"
    fi

    # 5. put the new files in place
    local staging; staging="$(source_staging_dir)"
    [[ -d "$staging" ]] || fail "$EX_RUNTIME" "The downloaded files are not where they were expected: $staging"
    log "Synchronising the new build into server/"
    rsync -a --delete "$staging/" "$DIR_SERVER/" \
        || fail "$EX_RUNTIME" "Could not synchronise the new build."
    chown -R "$(cfg PUID):$(cfg PGID)" "$DIR_SERVER" 2>/dev/null || true
    log "New build: $(server_version)"

    # 6. start - and if it will not serve, go back on its own
    if ! server_start; then
        warn "The server did not come up with the new build."
        rollback_apply --auto
        fail "$EX_HEALTH" \
            "The update failed and was rolled back automatically." \
            "The server is running the previous build again." \
            "Logs: coop logs"
    fi

    # 7. the mod may rewrite its own gameplay config on a new build
    _update_guard_mod_config "$modcfg_before"

    state_set installed_version "$(server_version)"
    state_set workshop_version "$(workshop_local_time)"
    update_marker_clear

    ok "Update complete: $(server_version)"
    out_line ""
    out_line "  Every player needs the same Coop build to connect."
    out_line "  The previous build is kept; undo with: coop rollback"
    out_line ""
}

# modconfig_merge <previous> <new> <output> <report>
#
# WHY A MERGE AND NOT A RESTORE
# -----------------------------
# mod-config.json holds the gameplay settings - difficulty, world ageing,
# battle size - and belongs to the Coop mod, which rewrites it with that
# build's defaults. Neither simple answer is right:
#
#   keep the new file   -> every setting the player chose is silently reset
#   put the old file back -> settings the new build introduced are missing,
#                            and the mod re-adds them on the next boot, so
#                            the same fight happens again every launch
#
# So the NEW file is the template. It brings the new keys and the comments
# that document them. Every value that existed before is transplanted into
# it; keys that are new keep their default; keys that no longer exist are
# dropped, because the setting is gone.
#
# The file is JSONC, which jq cannot read - but it is strictly one setting
# per line, which makes a line-oriented merge both possible and safe, and
# leaves every comment untouched.
#
# The report file receives one "added <key>" or "removed <key>" line per
# difference, so the caller can tell the user what actually changed.
modconfig_merge() {
    local previous="$1" new="$2" output="$3" report="$4"

    awk '
    function keyof(line,   p, q) {
        p = index(line, "\"")
        if (p == 0) return ""
        q = index(substr(line, p + 1), "\"")
        if (q == 0) return ""
        return substr(line, p + 1, q - 1)
    }
    function valof(line,   v) {
        v = substr(line, index(line, ":") + 1)
        sub(/^[[:space:]]+/, "", v)
        sub(/[[:space:]]+$/, "", v)
        return v
    }
    function indentof(line) {
        match(line, /^[[:space:]]*/)
        return substr(line, 1, RLENGTH)
    }

    # First pass: remember what the player had.
    NR == FNR {
        if ($0 ~ /^[[:space:]]*"[A-Za-z0-9_]+"[[:space:]]*:/) {
            k = keyof($0); v = valof($0); sub(/,$/, "", v)
            # A block opener carries no value of its own.
            if (v != "{" && v != "") kept[k] = v
        }
        next
    }

    # Second pass: the new file, with old values written back in.
    {
        if ($0 ~ /^[[:space:]]*"[A-Za-z0-9_]+"[[:space:]]*:/) {
            k = keyof($0); v = valof($0)
            comma = (v ~ /,$/) ? "," : ""
            sub(/,$/, "", v)
            if (v != "{") {
                if (k in kept) {
                    seen[k] = 1
                    print indentof($0) "\"" k "\": " kept[k] comma
                    next
                }
                print "added " k > REPORT
            }
        }
        print
    }

    END {
        for (k in kept) if (!(k in seen)) print "removed " k > REPORT
    }
    ' REPORT="$report" "$previous" "$new" >"$output"
}

# Called after the server has booted on the new build, because that is when
# the mod rewrites its configuration.
_update_guard_mod_config() {
    local before="$1" after saved="$DIR_ROLLBACK/mod-config.json.bak"
    after="$(md5sum "$FILE_MOD_JSON" 2>/dev/null | cut -d' ' -f1 || true)"

    if [[ -z "$before" || "$before" == "$after" ]]; then
        debug "gameplay configuration unchanged"
        return 0
    fi
    if [[ ! -f "$saved" ]]; then
        warn "The gameplay configuration changed, but there is no previous copy to merge from."
        return 0
    fi

    log "The new build rewrote the gameplay configuration; merging your settings back in"
    cp -a "$FILE_MOD_JSON" "${FILE_MOD_JSON}.new-from-update"

    local merged report
    merged="${FILE_MOD_JSON}.merged.$$"
    report="${FILE_MOD_JSON}.report.$$"
    cleanup_register "$merged"; cleanup_register "$report"

    modconfig_merge "$saved" "$FILE_MOD_JSON" "$merged" "$report"

    # A merge that lost settings is worse than no merge at all, so the
    # result has to account for every line the new file had.
    local new_count merged_count
    new_count="$(grep -cE '^[[:space:]]*"[A-Za-z0-9_]+"[[:space:]]*:' "$FILE_MOD_JSON" || echo 0)"
    merged_count="$(grep -cE '^[[:space:]]*"[A-Za-z0-9_]+"[[:space:]]*:' "$merged" || echo 0)"
    if (( merged_count != new_count )) || (( merged_count == 0 )); then
        warn "The gameplay configuration could not be merged safely; the new build's defaults are in place."
        out_line "    Your previous settings: ${saved}"
        out_line "    Compare them with: diff ${saved} ${FILE_MOD_JSON}"
        return 0
    fi

    cp -a "$merged" "$FILE_MOD_JSON"
    chown "$(cfg PUID):$(cfg PGID)" "$FILE_MOD_JSON" 2>/dev/null || true
    ok "Gameplay settings carried over"

    local line
    while IFS=' ' read -r what key; do
        [[ -n "${key:-}" ]] || continue
        case "$what" in
            added)   out_line "    new setting, left at the new default: $key" ;;
            removed) out_line "    setting no longer exists in this build: $key" ;;
        esac
    done <"$report"

    out_line "    The build's own version is kept beside it:"
    out_line "      diff ${FILE_MOD_JSON} ${FILE_MOD_JSON}.new-from-update"

    # The merged values only take effect on the next boot.
    server_stop
    server_start || fail "$EX_HEALTH" \
        "Restart after merging the gameplay configuration failed." \
        "Logs: coop logs"
}
