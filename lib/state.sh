# shellcheck shell=bash
#
# state.sh - installation metadata.
#
# What belongs here: facts about the installation that are not settings -
# when it was installed, which manager version wrote it, which Workshop
# version is on disk. What does not belong here: anything secret, and
# anything the user is meant to change. Settings live in server.env.
#
# The file is machine-written and machine-read; it is JSON so a hosting
# backend can consume it directly.

state_init() {
    mkdir -p "$DIR_STATE"
    [[ -f "$FILE_STATE" ]] && return 0
    jq -n \
        --arg manager "$MANAGER_VERSION" \
        --arg channel "$(cfg INSTALL_CHANNEL)" \
        --arg dir "$INSTALL_DIR" \
        --arg instance "$INSTANCE_ID" \
        --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{
            manager_version: $manager,
            install_channel: $channel,
            install_directory: $dir,
            instance_id: $instance,
            setup_profile: "unknown",
            installed_version: null,
            workshop_version: null,
            installed_at: $now,
            updated_at: $now
        }' >"$FILE_STATE"
    chmod 0640 "$FILE_STATE"
}

state_get() {
    [[ -f "$FILE_STATE" ]] || { printf ''; return 0; }
    jq -r --arg k "$1" '.[$k] // "" | if type=="object" or type=="array" then tojson else tostring end' \
        "$FILE_STATE" 2>/dev/null
}

# state_set <key> <value> [--raw]
#
# --raw writes the value as JSON (number, boolean, null) rather than as a
# string.
state_set() {
    local key="$1" value="$2" raw="${3:-}"
    state_init
    local tmp; tmp="$(mktemp "${FILE_STATE}.XXXXXX")"
    if [[ "$raw" == "--raw" ]]; then
        jq --arg k "$key" --argjson v "$value" '.[$k] = $v | .updated_at = (now | todate)' \
            "$FILE_STATE" >"$tmp"
    else
        jq --arg k "$key" --arg v "$value" '.[$k] = $v | .updated_at = (now | todate)' \
            "$FILE_STATE" >"$tmp"
    fi
    chmod 0640 "$tmp"
    mv -f "$tmp" "$FILE_STATE"
}

state_exists() { [[ -f "$FILE_STATE" ]]; }

# Is there an installation here at all? Judged by the data, not by the
# state file alone - somebody may have deleted it.
installation_present() {
    [[ -d "$INSTALL_DIR" ]] && { state_exists || server_installed || [[ -f "$FILE_CONFIG" ]]; }
}

# ------------------------------------------------------------ update marker --
# A small file rather than a field, so the MOTD snippet and other cheap
# consumers can test for it without parsing JSON.
update_marker_set()   { date -Is >"$DIR_STATE/update-available"; }
update_marker_clear() { rm -f "$DIR_STATE/update-available"; }
update_marker_is_set(){ [[ -f "$DIR_STATE/update-available" ]]; }
