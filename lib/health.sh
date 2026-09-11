# shellcheck shell=bash
#
# health.sh - `coop status` and `coop doctor`.
#
# status answers "what is it doing right now". doctor answers "why is it
# not doing what I expect". Both read the same sources and both can speak
# JSON, because a hosting backend needs exactly these two questions
# answered without a human in front of them.

# Each check is "status<TAB>category<TAB>name<TAB>detail".
declare -ga HEALTH_CHECKS=()
HEALTH_WORST=0   # 0 ok, 1 warning, 2 failure

_hc() {
    HEALTH_CHECKS+=("$1"$'\t'"$2"$'\t'"$3"$'\t'"${4:-}")
    case "$1" in
        fail) HEALTH_WORST=2 ;;
        warn) (( HEALTH_WORST < 1 )) && HEALTH_WORST=1 ;;
    esac
    return 0
}

# ------------------------------------------------------------------ status --
status_report() {
    local running=0 phase="" health="" players=0 uptime=0 last_backup="" last_backup_age=0

    if container_exists && container_running; then
        running=1
        phase="$(server_phase)"
        health="$(container_health)"
        players="$(player_count)"
        uptime="$(container_uptime_seconds)"
    fi

    local f
    f="$(_backup_all_files | head -1)"
    if [[ -n "$f" ]]; then
        last_backup="$(basename "$f")"
        last_backup_age=$(( $(date +%s) - $(stat -c %Y "$f") ))
    fi

    if is_json; then
        local state="offline"
        (( running )) && case "$phase" in
            serving) state="online" ;;
            loading) state="loading" ;;
            boot)    state="starting" ;;
            *)       state="running" ;;
        esac
        jq -n \
            --arg status "$state" \
            --arg label "$(cfg SERVER_LABEL)" \
            --arg save "$(cfg SAVE_NAME)" \
            --arg campaign "$(pulse_time)" \
            --arg channel "$(cfg INSTALL_CHANNEL)" \
            --arg version "$(server_version)" \
            --arg manager "$MANAGER_VERSION" \
            --arg health "${health:-none}" \
            --arg backup "$last_backup" \
            --arg instance "$INSTANCE_ID" \
            --argjson players "${players:-0}" \
            --argjson port "$(cfg GAME_PORT)" \
            --argjson uptime "${uptime:-0}" \
            --argjson backup_age "${last_backup_age:-0}" \
            --argjson password "$( [[ -n "$(cfg SERVER_PASSWORD)" ]] && echo true || echo false )" \
            --argjson update "$( update_marker_is_set && echo true || echo false )" \
            '{
               ok:true, status:$status, instance:$instance, server_label:$label,
               save_name:$save, campaign_date:$campaign, players:$players,
               install_channel:$channel, coop_version:$version,
               manager_version:$manager, container_health:$health,
               game_port:$port, password_set:$password, uptime_seconds:$uptime,
               last_backup:$backup, last_backup_age_seconds:$backup_age,
               update_available:$update
             }'
        return 0
    fi

    out_title "$(cfg SERVER_LABEL)"

    if ! container_exists; then
        out_kv "Status" "NOT INSTALLED" "$C_YEL"
        out_line ""
        out_line "  Set the server up with: coop install"
        out_line ""
        return 0
    fi

    if (( running )); then
        case "$phase" in
            serving) out_kv "Status" "ONLINE" "$C_GRN" ;;
            loading) out_kv "Status" "LOADING CAMPAIGN" "$C_YEL" ;;
            boot)    out_kv "Status" "STARTING" "$C_YEL" ;;
            *)       out_kv "Status" "RUNNING (${health})" "$C_YEL" ;;
        esac
        out_kv "Uptime" "$(human_duration "$uptime")"
    else
        out_kv "Status" "OFFLINE" "$C_RED"
        out_kv "Last exit" "$(container_exitcode)"
    fi

    out_kv "Campaign" "$(cfg SAVE_NAME)$( [[ -n "$(pulse_time)" ]] && printf '  (%s)' "$(pulse_time)" )"
    (( running )) && out_kv "Players" "$players$( [[ -n "$(pulse_field parties)" ]] && printf '  (%s parties)' "$(pulse_field parties)" )"
    out_kv "Connection" "UDP $(cfg GAME_PORT)$( [[ -n "$(cfg SERVER_PASSWORD)" ]] && printf '  (password set)' || printf '  (no password)' )"
    out_kv "Install channel" "$( [[ "$(cfg INSTALL_CHANNEL)" == workshop ]] && printf 'Steam Workshop' || printf 'Custom build' )"
    out_kv "Coop build" "$(server_version)"
    out_kv "Manager" "v$MANAGER_VERSION"

    out_line ""
    if (( running )); then
        local stats mem cpu
        stats="$(container_stats)"
        if [[ -n "$stats" ]]; then
            IFS=$'\t' read -r mem cpu <<<"$stats"
            out_kv "Memory" "$mem"
            out_kv "CPU" "$cpu"
        fi
    fi
    out_kv "Disk" "$(compat_disk_gb "$INSTALL_DIR") GB free"

    if [[ -n "$last_backup" ]]; then
        out_kv "Last backup" "$last_backup  ($(human_duration "$last_backup_age") ago)"
    else
        out_kv "Last backup" "none" "$C_YEL"
    fi
    out_kv "Automatic backups" "$( cfg_bool BACKUP_ENABLED && printf 'enabled (%s)' "$(cfg BACKUP_SCHEDULE)" || printf 'disabled' )"

    if update_marker_is_set; then
        out_line ""
        out_line "  ${C_YEL}A Workshop update is available${C_OFF} - install it with: coop update"
    fi
    out_line ""
}

# ------------------------------------------------------------------ doctor --
doctor_run() {
    HEALTH_CHECKS=(); HEALTH_WORST=0

    _doctor_system
    _doctor_docker
    _doctor_configuration
    _doctor_data
    _doctor_steam
    _doctor_server
    _doctor_backups

    if is_json; then
        local arr="[]" row status category name detail
        for row in "${HEALTH_CHECKS[@]}"; do
            IFS=$'\t' read -r status category name detail <<<"$row"
            arr="$(jq -c -n --argjson acc "$arr" \
                --arg s "$status" --arg c "$category" --arg n "$name" --arg d "$detail" \
                '$acc + [{status:$s, category:$c, check:$n, detail:$d}]')"
        done
        jq -n --argjson checks "$arr" --argjson worst "$HEALTH_WORST" \
            '{ok: ($worst < 2), severity: (if $worst==0 then "ok" elif $worst==1 then "warning" else "failure" end),
              checks: $checks,
              summary: {
                total: ($checks|length),
                failures: ([$checks[]|select(.status=="fail")]|length),
                warnings: ([$checks[]|select(.status=="warn")]|length)
              }}'
    else
        local row status category name detail current=""
        out_title "Diagnostics"
        for row in "${HEALTH_CHECKS[@]}"; do
            IFS=$'\t' read -r status category name detail <<<"$row"
            if [[ "$category" != "$current" ]]; then
                [[ -n "$current" ]] && out_line ""
                out_section "$category"
                current="$category"
            fi
            out_check "$status" "$(printf '%-26s %s' "$name" "$detail")"
        done
        out_line ""
        case "$HEALTH_WORST" in
            0) out_line "  Everything checks out." ;;
            1) out_line "  Usable, with warnings above." ;;
            2) out_line "  Problems found. Each failing line above says what to look at." ;;
        esac
        out_line ""
    fi

    (( HEALTH_WORST < 2 )) || return "$EX_HEALTH"
    return 0
}

_doctor_system() {
    compat_detect
    compat_matrix
    case "$COMPAT_STATUS" in
        supported)    _hc ok   "System" "Operating system" "$OS_NAME" ;;
        experimental) _hc warn "System" "Operating system" "$OS_NAME (experimental)" ;;
        *)            _hc fail "System" "Operating system" "$OS_NAME - $COMPAT_REASON" ;;
    esac

    if [[ "$SYS_ARCH" == "x86_64" || "$SYS_ARCH" == "amd64" ]]; then
        _hc ok "System" "Architecture" "$SYS_ARCH"
    else
        _hc fail "System" "Architecture" "$SYS_ARCH is not supported"
    fi

    local missing=()
    compat_missing_packages missing "${REQUIRED_COMMANDS[@]}"
    if (( ${#missing[@]} == 0 )); then
        _hc ok "System" "Required tools" "all present"
    else
        _hc fail "System" "Required tools" "missing: ${missing[*]}"
    fi

    local free; free="$(compat_disk_gb "$INSTALL_DIR")"
    if   (( free >= 10 )); then _hc ok   "System" "Disk space" "${free} GB free"
    elif (( free >= 3 ));  then _hc warn "System" "Disk space" "${free} GB free - an update needs about 7 GB"
    else                        _hc fail "System" "Disk space" "${free} GB free - too little to update or back up"
    fi

    if (( SYS_MEM_MB >= MIN_MEM_MB )); then
        _hc ok "System" "Memory" "${SYS_MEM_MB} MB"
    else
        _hc warn "System" "Memory" "${SYS_MEM_MB} MB is below the recommended minimum"
    fi
}

_doctor_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        _hc fail "Docker" "Docker Engine" "not installed"
        return
    fi
    if docker info >/dev/null 2>&1; then
        _hc ok "Docker" "Docker daemon" "$(compat_docker_version)"
    else
        _hc fail "Docker" "Docker daemon" "not responding - try: systemctl status docker"
        return
    fi

    local cv; cv="$(compat_compose_version)"
    [[ -n "$cv" ]] && _hc ok "Docker" "Compose plugin" "$cv" \
                   || _hc fail "Docker" "Compose plugin" "missing"

    if image_exists; then
        _hc ok "Docker" "Runtime image" "bannerlordcoop/server:$(cfg WINE_BRANCH)"
    else
        _hc warn "Docker" "Runtime image" "not built yet - run: coop install"
    fi
}

_doctor_configuration() {
    if [[ -f "$FILE_CONFIG" ]]; then
        _hc ok "Configuration" "server.env" "$FILE_CONFIG"
    else
        _hc fail "Configuration" "server.env" "not found - this host has no installation yet"
        return
    fi

    local perms; perms="$(stat -c %a "$FILE_CONFIG" 2>/dev/null)"
    if [[ "$perms" == "600" || "$perms" == "640" ]]; then
        _hc ok "Configuration" "File permissions" "$perms"
    else
        _hc warn "Configuration" "File permissions" "$perms - the file holds the server password; 600 is expected"
    fi

    local key reason problems=0
    for key in $(config_keys); do
        reason="$(_validate_value "$key" "${CFG[$key]:-}")"
        [[ -n "$reason" ]] && { _hc fail "Configuration" "$key" "$reason"; problems=$(( problems + 1 )); }
    done
    (( problems == 0 )) && _hc ok "Configuration" "Values" "all valid"

    if config_selfcheck >/dev/null 2>&1; then
        _hc ok "Configuration" "Defaults consistency" "spec and defaults.env agree"
    else
        _hc warn "Configuration" "Defaults consistency" "defaults.env and the spec have drifted - reinstall the manager files"
    fi

    if [[ -f "$FILE_SERVER_JSON" ]]; then
        _hc ok "Configuration" "server-config.json" "generated"
    else
        _hc fail "Configuration" "server-config.json" "missing - run: coop config --apply"
    fi
}

_doctor_data() {
    local d
    for d in "$DIR_SAVES" "$DIR_CONFIG" "$DIR_COOPDATA" "$DIR_BACKUPS" "$DIR_LOGS" "$DIR_STATE"; do
        [[ -d "$d" ]] || { _hc fail "Data" "$(basename "$d")/" "missing: $d"; continue; }
        _hc ok "Data" "$(basename "$d")/" "$(du -sh "$d" 2>/dev/null | cut -f1) in $d"
    done

    local owner expect
    expect="$(cfg PUID):$(cfg PGID)"
    owner="$(stat -c '%u:%g' "$DIR_SAVES" 2>/dev/null)"
    if [[ "$owner" == "$expect" ]]; then
        _hc ok "Data" "Ownership" "$owner"
    else
        _hc warn "Data" "Ownership" "saves/ is owned by $owner, expected $expect - the container may not be able to write"
    fi

    local save="$DIR_SAVES/$(cfg SAVE_NAME).sav"
    if [[ -f "$save" ]]; then
        _hc ok "Data" "Campaign save" "$(cfg SAVE_NAME) ($(human_size_simple "$(stat -c %s "$save")"))"
        [[ -f "${save%.sav}.json" ]] \
            || _hc warn "Data" "Campaign metadata" "$(cfg SAVE_NAME).json is missing beside the save"
    else
        _hc warn "Data" "Campaign save" "no save named '$(cfg SAVE_NAME)' yet - a new world is created on first start"
    fi

    if [[ -f "$FILE_MOD_JSON" ]]; then
        _hc ok "Data" "Gameplay config" "mod-config.json present"
    else
        _hc warn "Data" "Gameplay config" "mod-config.json not created yet - the mod writes it on first launch"
    fi
}

_doctor_steam() {
    [[ "$(cfg INSTALL_CHANNEL)" == "workshop" ]] || {
        _hc ok "Steam" "Channel" "custom build - Steam is not used"
        return
    }
    if [[ -z "$(cfg STEAM_USERNAME)" ]]; then
        _hc fail "Steam" "Account" "not configured - run: coop steam login"
        return
    fi
    _hc ok "Steam" "Account" "$(cfg STEAM_USERNAME)"

    local st; st="$(steam_status)"
    case "$st" in
        valid|present) _hc ok   "Steam" "Session" "$(steam_status_explain "$st")" ;;
        expired)       _hc fail "Steam" "Session" "$(steam_status_explain "$st")" ;;
        *)             _hc fail "Steam" "Session" "$(steam_status_explain "$st")" ;;
    esac

    if [[ -d "$(workshop_item_dir)" ]]; then
        _hc ok "Steam" "Workshop files" "$(du -sh "$(workshop_item_dir)" 2>/dev/null | cut -f1)"
    else
        _hc warn "Steam" "Workshop files" "not downloaded yet - run: coop update --force"
    fi
}

_doctor_server() {
    if server_installed; then
        _hc ok "Server" "Server files" "$(server_version)"
    else
        _hc fail "Server" "Server files" "BannerlordCoopServer.exe not found in $DIR_SERVER"
    fi

    if ! container_exists; then
        _hc warn "Server" "Container" "not created yet"
        return
    fi
    if container_running; then
        _hc ok "Server" "Container" "running, health: $(container_health)"
        case "$(server_phase)" in
            serving) _hc ok   "Server" "Server process" "serving clients" ;;
            loading) _hc warn "Server" "Server process" "still loading the campaign" ;;
            boot)    _hc warn "Server" "Server process" "starting up" ;;
            *)       _hc warn "Server" "Server process" "no state event seen yet" ;;
        esac
    else
        _hc warn "Server" "Container" "stopped (exit $(container_exitcode))"
    fi

    if port_in_use "$(cfg GAME_PORT)" udp; then
        _hc ok "Server" "Game port" "UDP $(cfg GAME_PORT) is bound"
    elif container_running; then
        _hc fail "Server" "Game port" "UDP $(cfg GAME_PORT) is not bound although the container runs"
    else
        _hc warn "Server" "Game port" "UDP $(cfg GAME_PORT) is not bound - the server is stopped"
    fi
    _hc info "Server" "Firewall reminder" "UDP $(cfg GAME_PORT) must be open at your provider too"

    if container_exists; then
        local errors
        errors="$(container_logs_tail 300 | grep -ciE '^\[?(error|fatal)|Unhandled exception' || true)"
        if (( errors > 0 )); then
            _hc warn "Server" "Recent log errors" "$errors error line(s) in the last 300 - see: coop logs"
        else
            _hc ok "Server" "Recent log errors" "none in the last 300 lines"
        fi
    fi
}

_doctor_backups() {
    local newest age days
    newest="$(_backup_all_files | head -1)"
    if [[ -z "$newest" ]]; then
        _hc warn "Backups" "Last backup" "none yet - create one with: coop backup"
    else
        age=$(( $(date +%s) - $(stat -c %Y "$newest") ))
        days=$(( age / 86400 ))
        if   (( days >= 7 )); then _hc warn "Backups" "Last backup" "$(human_duration "$age") ago - older than a week"
        else                       _hc ok   "Backups" "Last backup" "$(basename "$newest"), $(human_duration "$age") ago"
        fi
    fi

    local count total
    count="$(_backup_all_files | wc -l)"
    total="$(du -sh "$DIR_BACKUPS" 2>/dev/null | cut -f1)"
    _hc ok "Backups" "Stored" "${count} archive(s), ${total:-0} in $DIR_BACKUPS"

    if cfg_bool BACKUP_ENABLED; then
        if systemctl is-enabled "bannerlordcoop-backup@$(systemd_instance).timer" >/dev/null 2>&1; then
            _hc ok "Backups" "Schedule" "$(cfg BACKUP_SCHEDULE), timer enabled"
        else
            _hc warn "Backups" "Schedule" "enabled in the configuration but the systemd timer is not active"
        fi
    else
        _hc warn "Backups" "Schedule" "automatic backups are disabled"
    fi

    _hc info "Backups" "Off-host copies" "a backup that only exists on this server is not a backup"
}
