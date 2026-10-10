# shellcheck shell=bash
#
# bans.sh - the server's Steam ban list.
#
# From Coop v0.1.6 on, the dedicated server refuses Steam accounts listed in
# steam-bans.json. It re-reads the file whenever the file changes, so a ban
# takes effect at the account's next join attempt, without a restart.
#
# WHERE THE FILE LIVES, AND WHY NOT WHERE THE SERVER WOULD LOOK
# -------------------------------------------------------------
# Left to itself, the server looks in server-data/ beside its engine
# directory - inside server/, which is mounted read-only and replaced
# wholesale by every update and every rollback. A ban kept there would
# vanish without a word at the next update, and it would be in no backup.
# compose.yaml therefore points the server at config/steam-bans.json
# through COOP_STEAM_BAN_FILE, and config/ is in every backup.
#
# THE FORMAT
# ----------
#   { "steamIds": ["76561198000000042"],
#     "entries":  [{ "steamId": "76561198000000042", "heroName": "Example" }] }
#
# The server bans every id in either list. "entries" only exists so that a
# name can travel with an id. Anything else in the file is left alone.
#
# The server parses it as strict JSON: no comments, no trailing commas. If
# an edit breaks it, the server keeps its last valid list and logs the
# error, so a broken file is refused here rather than written.

# Steam64 ids as the server accepts them: 5 to 20 digits.
bans_valid_id() { [[ "$1" =~ ^[0-9]{5,20}$ ]]; }

# The current list, or an empty one when there is no file yet.
_bans_read() {
    if [[ ! -f "$FILE_BANS" ]]; then
        printf '{"steamIds":[]}'
        return 0
    fi
    jq -e 'type == "object"' "$FILE_BANS" >/dev/null 2>&1 || fail "$EX_CONFIG" \
        "$FILE_BANS is not valid JSON, so it was not changed." \
        "The server keeps using the last valid list until the file is fixed by hand."
    cat "$FILE_BANS"
}

# One line per banned id: "id<TAB>name", the name possibly empty.
bans_entries() {
    _bans_read | jq -r '
        [ (.steamIds // [])[] | strings ] as $ids
        | [ (.entries // [])[] | objects | select(.steamId | type == "string") ] as $named
        | ($ids + [$named[].steamId]) | unique[] as $id
        | [$id, ([$named[] | select(.steamId == $id) | (.heroName // "") | tostring] | first // "")]
        | @tsv'
}

_bans_write() {
    local content="$1" tmp
    mkdir -p "$DIR_CONFIG"
    tmp="$(mktemp "${FILE_BANS}.XXXXXX")"
    if ! jq . <<<"$content" >"$tmp" 2>/dev/null || [[ ! -s "$tmp" ]]; then
        rm -f "$tmp"
        fail "$EX_RUNTIME" "Could not write $FILE_BANS"
    fi
    # Read by the server, which runs as the service user.
    chown "$(cfg PUID):$(cfg PGID)" "$tmp" 2>/dev/null || true
    chmod 0640 "$tmp"
    mv -f "$tmp" "$FILE_BANS"
}

# ban_add <steam64-id> [name]
ban_add() {
    local id="$1" name="${2:-}" current
    bans_valid_id "$id" || fail "$EX_USAGE" \
        "Not a Steam64 id: $id" \
        "It is the number in a player's profile address, steamcommunity.com/profiles/<id>."
    current="$(_bans_read)"
    _bans_write "$(jq --arg id "$id" --arg name "$name" '
        .steamIds = ((.steamIds // []) | if index([$id]) then . else . + [$id] end)
        | if $name == "" then .
          else .entries = ([(.entries // [])[] | select(.steamId != $id)]
                           + [{steamId: $id, heroName: $name}])
          end' <<<"$current")"
    ok "Banned $id${name:+ ($name)}"
    _bans_effect_note
}

# ban_remove <steam64-id>
ban_remove() {
    local id="$1" current
    bans_valid_id "$id" || fail "$EX_USAGE" "Not a Steam64 id: $id"
    current="$(_bans_read)"
    if ! jq -e --arg id "$id" \
            '((.steamIds // []) | index([$id])) or any((.entries // [])[]; .steamId == $id)' \
            <<<"$current" >/dev/null; then
        log "$id is not banned."
        return 0
    fi
    _bans_write "$(jq --arg id "$id" '
        .steamIds = [(.steamIds // [])[] | select(. != $id)]
        | if has("entries") then .entries = [.entries[] | select(.steamId != $id)] else . end' \
        <<<"$current")"
    ok "Lifted the ban on $id"
    _bans_effect_note
}

_bans_effect_note() {
    out_line "    The server re-reads the list on the next join attempt; no restart needed."
}

ban_list() {
    local rows=() id name
    if is_json; then
        bans_entries | jq -R -s --arg file "$FILE_BANS" '
            split("\n") | map(select(length > 0) | split("\t") | {steam_id: .[0], name: (.[1] // "")})
            | {ok: true, file: $file, count: length, bans: .}'
        return 0
    fi

    out_title "Steam bans"
    while IFS=$'\t' read -r id name; do
        [[ -n "$id" ]] && rows+=("$(printf '%s\t%s' "$id" "${name:--}")")
    done < <(bans_entries)

    if (( ${#rows[@]} == 0 )); then
        out_line "  Nobody is banned."
    else
        out_table "$(printf 'STEAM ID\tNAME')" "${rows[@]}"
    fi
    out_line ""
    out_line "  Ban:    coop ban <steam64-id> [--name \"<hero name>\"]"
    out_line "  Lift:   coop unban <steam64-id>"
    out_line "  File:   $FILE_BANS"
    out_line ""
}

# For status and doctor: the number of banned accounts, or "invalid".
bans_count() {
    [[ -f "$FILE_BANS" ]] || { printf '0'; return 0; }
    jq -e 'type == "object"' "$FILE_BANS" >/dev/null 2>&1 || { printf 'invalid'; return 0; }
    bans_entries | grep -c . || true
}
