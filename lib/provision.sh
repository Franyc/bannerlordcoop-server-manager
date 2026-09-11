# shellcheck shell=bash
#
# provision.sh - the installer.
#
# THE ONE ARCHITECTURAL RULE
# --------------------------
#     collect  ->  validate  ->  summarise  ->  provision
#
# The collectors (default, advanced, command line, config file) do nothing
# but gather values. provision_run() does nothing but apply them, and never
# asks a question. That is why the interactive installer and a future
# hosting backend can share one implementation rather than two that drift
# apart:
#
#     human      -> coop install                       -> provision_run()
#     automation -> coop install --non-interactive ... -> provision_run()

# ------------------------------------------------------- systemd instance --
# The unit template is instantiated with the escaped install path, so the
# unit knows which installation it belongs to without a separate registry.
# %f inside the unit gives the path back.
systemd_instance() {
    systemd-escape --path "$INSTALL_DIR" 2>/dev/null || printf '%s' "${INSTANCE_ID}"
}

systemd_available() { [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null 2>&1; }

# ------------------------------------------------------------- collectors --
# Default setup. Three questions and a Steam login.
#
# Note on what is NOT asked: the dedicated server has no server-name and no
# player-limit setting - server-config.json has nine fields and neither is
# among them. Asking for a value that cannot be applied would be worse than
# not asking, so the campaign name takes that place. It is the one answer
# that genuinely changes the outcome: an existing save of that name is
# loaded, otherwise a new world is created under it.
provision_collect_default() {
    local value

    out_title "Campaign"
    out_line "  The campaign name decides what the server hosts. If a save of this"
    out_line "  name already exists it is loaded; otherwise a new world is created."
    out_line ""

    ask value "Campaign name" "$(cfg SAVE_NAME)"
    cfg_set SAVE_NAME "$value"

    ask_secret value "Server password (empty for none)"
    cfg_set SERVER_PASSWORD "$value"
    unset value

    # Only asked when the default is genuinely unavailable.
    if port_in_use "$(cfg GAME_PORT)" udp; then
        local suggestion; suggestion="$(find_free_port "$(cfg GAME_PORT)" udp || echo "")"
        warn "UDP port $(cfg GAME_PORT) is already in use on this host."
        ask value "Game port" "${suggestion:-4201}"
        cfg_set GAME_PORT "$value"
    fi

    cfg_set SERVER_LABEL "$(cfg SAVE_NAME)"
}

# Advanced setup. Everything the default mode decides silently.
provision_collect_advanced() {
    local value

    provision_collect_default

    out_title "Installation"
    ask value "Instance id" "$(cfg INSTANCE_ID)";            cfg_set INSTANCE_ID "$value"
    ask value "Installation directory" "$(cfg INSTALL_DIR)"; cfg_set INSTALL_DIR "$value"
    ask value "Display name" "$(cfg SERVER_LABEL)";          cfg_set SERVER_LABEL "$value"
    ask value "Install channel (workshop/custom)" "$(cfg INSTALL_CHANNEL)"
    cfg_set INSTALL_CHANNEL "$value"
    if [[ "$(cfg INSTALL_CHANNEL)" == "custom" ]]; then
        ask value "Directory holding the server files" "$(cfg CUSTOM_SOURCE_PATH)"
        cfg_set CUSTOM_SOURCE_PATH "$value"
    fi

    out_title "Server"
    ask value "Game port (UDP)" "$(cfg GAME_PORT)";               cfg_set GAME_PORT "$value"
    ask value "Autosave interval in minutes" "$(cfg AUTOSAVE_MINUTES)"; cfg_set AUTOSAVE_MINUTES "$value"
    ask value "Advertise a public Steam lobby (true/false)" "$(cfg STEAM_ADVERTISE)"
    cfg_set STEAM_ADVERTISE "$value"
    ask value "Time zone ('system' for the host's)" "$(cfg TIMEZONE)"; cfg_set TIMEZONE "$value"
    ask value "Memory limit (e.g. 4g, empty for none)" "$(cfg MEMORY_LIMIT)"; cfg_set MEMORY_LIMIT "$value"

    out_title "Backups"
    ask value "Enable automatic backups (true/false)" "$(cfg BACKUP_ENABLED)"; cfg_set BACKUP_ENABLED "$value"
    if cfg_bool BACKUP_ENABLED; then
        ask value "Schedule (systemd OnCalendar)" "$(cfg BACKUP_SCHEDULE)"; cfg_set BACKUP_SCHEDULE "$value"
        ask value "Keep how many automatic backups" "$(cfg BACKUP_KEEP_AUTO)"; cfg_set BACKUP_KEEP_AUTO "$value"
        ask value "Delete automatic backups older than N days (0 = never)" "$(cfg BACKUP_MAX_AGE_DAYS)"
        cfg_set BACKUP_MAX_AGE_DAYS "$value"
        ask value "Total backup size cap in GB (0 = no cap)" "$(cfg BACKUP_MAX_TOTAL_GB)"
        cfg_set BACKUP_MAX_TOTAL_GB "$value"
    fi

    out_title "Updates"
    out_line "  Automatic updates are off by default because every player must run"
    out_line "  the same Coop build - an unattended update locks out anyone who has"
    out_line "  not updated their client."
    out_line ""
    ask value "Check for updates on a schedule (true/false)" "$(cfg UPDATE_CHECK_ENABLED)"
    cfg_set UPDATE_CHECK_ENABLED "$value"
    if cfg_bool UPDATE_CHECK_ENABLED; then
        ask value "Update check schedule (systemd OnCalendar)" "$(cfg UPDATE_CHECK_SCHEDULE)"
        cfg_set UPDATE_CHECK_SCHEDULE "$value"
        ask value "Install updates automatically (true/false)" "$(cfg AUTO_UPDATE)"
        cfg_set AUTO_UPDATE "$value"
    fi
    unset value
}

provision_summary() {
    out_title "Configuration summary"
    out_kv "Instance"          "$INSTANCE_ID"
    out_kv "Directory"         "$INSTALL_DIR"
    out_kv "Campaign"          "$(cfg SAVE_NAME)"
    out_kv "Password"          "$( [[ -n "$(cfg SERVER_PASSWORD)" ]] && printf 'set' || printf 'none - anyone with the address can join' )"
    out_kv "Game port"         "UDP $(cfg GAME_PORT)"
    out_kv "Install channel"   "$(cfg INSTALL_CHANNEL)"
    out_kv "Steam account"     "$( [[ -n "$(cfg STEAM_USERNAME)" ]] && cfg STEAM_USERNAME || printf 'not set' )"
    out_kv "Automatic backups" "$( cfg_bool BACKUP_ENABLED && printf '%s, keep %s' "$(cfg BACKUP_SCHEDULE)" "$(cfg BACKUP_KEEP_AUTO)" || printf 'disabled' )"
    out_kv "Update checks"     "$( cfg_bool UPDATE_CHECK_ENABLED && cfg UPDATE_CHECK_SCHEDULE || printf 'disabled' )"
    out_kv "Automatic updates" "$( cfg_bool AUTO_UPDATE && printf 'enabled' || printf 'disabled (recommended)' )"
    out_line ""
    out_line "  About 6 GB will be downloaded from Steam."
    out_line ""
}

# ---------------------------------------------------------- the engine --
# Applies a validated configuration. Asks nothing, returns exit codes.
provision_run() {
    local skip_download="${1:-0}"

    step "Creating the directory layout"
    mkdir -p "$DIR_CONFIG" "$DIR_SAVES" "$DIR_COOPDATA" "$DIR_SERVER" \
             "$DIR_WORKSHOP" "$DIR_ROLLBACK" "$DIR_BACKUPS" "$DIR_LOGS" \
             "$DIR_STATE" "$DIR_STEAM" \
        || fail "$EX_RUNTIME" "Could not create $INSTALL_DIR"
    chown -R "$(cfg PUID):$(cfg PGID)" "$INSTALL_DIR" 2>/dev/null || true
    chmod 0750 "$INSTALL_DIR"
    log_open "$INSTALL_DIR"
    ok "$INSTALL_DIR"

    step "Writing the configuration"
    if [[ -f "$FILE_CONFIG" ]]; then
        mapfile -t _all_keys < <(config_keys)
        config_persist "$FILE_CONFIG" "${_all_keys[@]}"
    else
        config_write_new "$FILE_CONFIG"
    fi
    config_write_compose_env
    server_config_render
    state_init
    ok "$FILE_CONFIG"

    step "Building the runtime image"
    image_build

    if (( ! skip_download )); then
        step "Fetching the server files"
        source_fetch

        step "Installing the server files"
        local staging; staging="$(source_staging_dir)"
        [[ -d "$staging" ]] || fail "$EX_RUNTIME" \
            "The server files are not where they were expected: $staging"
        rsync -a --delete "$staging/" "$DIR_SERVER/" \
            || fail "$EX_RUNTIME" "Could not copy the server files into place."
        chown -R "$(cfg PUID):$(cfg PGID)" "$DIR_SERVER" 2>/dev/null || true
        state_set installed_version "$(server_version)"
        state_set workshop_version "$(workshop_local_time)"
        ok "$(server_version)"
    fi

    step "Installing scheduled tasks"
    provision_install_units

    return 0
}

# ---------------------------------------------------------------- systemd --
provision_install_units() {
    if ! systemd_available; then
        warn "No systemd on this host - scheduled backups and update checks are not installed."
        out_line "    Run 'coop backup' and 'coop update --check' from your own scheduler."
        return 0
    fi

    local inst tmpl_dir="${COOP_ROOT}/templates/systemd" unit
    inst="$(systemd_instance)"

    for unit in bannerlordcoop-backup@.service bannerlordcoop-backup@.timer \
                bannerlordcoop-update-check@.service bannerlordcoop-update-check@.timer; do
        [[ -f "$tmpl_dir/$unit" ]] || { warn "Missing unit template: $unit"; continue; }
        install -m 0644 "$tmpl_dir/$unit" "/etc/systemd/system/$unit"
    done

    # The schedule lives in a drop-in rather than in the template, so a
    # user's choice survives an upgrade of the unit files.
    _write_timer_override bannerlordcoop-backup       "$inst" "$(cfg BACKUP_SCHEDULE)"       300
    _write_timer_override bannerlordcoop-update-check "$inst" "$(cfg UPDATE_CHECK_SCHEDULE)" 1800

    systemctl daemon-reload

    if cfg_bool BACKUP_ENABLED; then
        systemctl enable --now "bannerlordcoop-backup@${inst}.timer" >/dev/null 2>&1 \
            && ok "Backup timer: $(cfg BACKUP_SCHEDULE)" \
            || warn "Could not enable the backup timer."
    else
        systemctl disable --now "bannerlordcoop-backup@${inst}.timer" >/dev/null 2>&1 || true
        log "Automatic backups are disabled."
    fi

    if cfg_bool UPDATE_CHECK_ENABLED; then
        systemctl enable --now "bannerlordcoop-update-check@${inst}.timer" >/dev/null 2>&1 \
            && ok "Update check: $(cfg UPDATE_CHECK_SCHEDULE)" \
            || warn "Could not enable the update-check timer."
    else
        systemctl disable --now "bannerlordcoop-update-check@${inst}.timer" >/dev/null 2>&1 || true
    fi
}

_write_timer_override() {
    local unit="$1" inst="$2" schedule="$3" spread="$4"
    local dir="/etc/systemd/system/${unit}@${inst}.timer.d"
    mkdir -p "$dir"
    cat >"$dir/schedule.conf" <<EOF
# Written by coop from config/server.env. Edit the configuration instead:
#   coop config --set $( [[ "$unit" == *backup* ]] && echo BACKUP_SCHEDULE || echo UPDATE_CHECK_SCHEDULE )="..."
[Timer]
OnCalendar=
OnCalendar=${schedule}
RandomizedDelaySec=${spread}
EOF
}

# ------------------------------------------------------------- validation --
# Step 8 of the install flow: prove that what was just built actually works.
provision_validate() {
    local problems=0
    out_title "Validation"

    if container_running; then out_check ok "Container running"
    else out_check fail "Container running"; problems=$(( problems + 1 )); fi

    if server_is_serving; then out_check ok "Server process serving clients"
    else out_check fail "Server process serving clients"; problems=$(( problems + 1 )); fi

    if [[ -f "$FILE_SERVER_JSON" ]]; then out_check ok "Configuration generated"
    else out_check fail "Configuration generated"; problems=$(( problems + 1 )); fi

    if port_in_use "$(cfg GAME_PORT)" udp; then out_check ok "UDP $(cfg GAME_PORT) bound"
    else out_check fail "UDP $(cfg GAME_PORT) bound"; problems=$(( problems + 1 )); fi

    if cfg_bool BACKUP_ENABLED; then
        if ! systemd_available; then
            out_check warn "Backup schedule (no systemd on this host)"
        elif systemctl is-active "bannerlordcoop-backup@$(systemd_instance).timer" >/dev/null 2>&1; then
            out_check ok "Backup schedule active"
        else
            out_check warn "Backup schedule not active"
        fi
    fi
    out_line ""
    return "$problems"
}

# ------------------------------------------------------- existing install --
# A second `coop install` must never quietly overwrite a campaign.
provision_existing_menu() {
    out_title "An existing installation was found"
    out_kv "Directory" "$INSTALL_DIR"
    out_kv "Campaign"  "$(cfg SAVE_NAME)"
    out_kv "Installed" "$(state_get installed_at)"
    out_kv "Build"     "$(server_version)"
    out_line ""
    out_line "  [1] Update       install a newer Coop build"
    out_line "  [2] Repair       rebuild the image and rewrite generated files,"
    out_line "                   leaving saves and settings alone"
    out_line "  [3] Reconfigure  change settings, then apply them"
    out_line "  [4] Exit         change nothing"
    out_line ""

    local choice
    ask choice "Select" "4"
    printf '%s' "$choice"
}
