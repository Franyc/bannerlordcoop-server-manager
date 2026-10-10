# shellcheck shell=bash
#
# license.sh - the dedicated server's own license terms, and the operator's
# acceptance of them.
#
# WHAT THE SERVER REQUIRES
# ------------------------
# From Coop v0.1.6 on, the dedicated server ships with an EULA and a
# license (EULA.md and LICENSE.txt beside BannerlordCoopServer.exe) and
# will not host a campaign until they have been accepted. Without that it
# prints the terms and exits 6. The server records acceptance itself, in
# eula.txt in its data directory, when it is started with
# DS_ACCEPT_EULA=true.
#
# WHAT THIS MANAGER DOES, AND WHAT IT REFUSES TO DO
# -------------------------------------------------
# The terms ask for a deliberate acceptance and forbid bypassing the check,
# so the manager never accepts on anyone's behalf. It shows where the terms
# are, asks, and records the answer against a checksum of the exact
# documents that were accepted. DS_ACCEPT_EULA is passed to the server only
# for a build whose documents match a recorded acceptance.
#
# The checksum is what makes "changed terms require fresh acceptance" work.
# A later build whose documents differ by a single byte is a build whose
# terms have not been accepted, so the question comes back, and an
# unattended update never answers it. Acceptance takes either "y" at a
# terminal or the explicit --accept-eula flag. --yes does not count.
#
# Every accepted checksum is kept, not only the latest, so a rollback to a
# build whose terms were accepted earlier starts without asking again.

# The documents that make up the terms, in the order they are checksummed.
# LICENSE.txt calls the EULA "EULA.txt" while the build ships EULA.md, so
# both spellings are recognised.
readonly LICENSE_DOCUMENTS=(EULA.md EULA.txt LICENSE.txt LICENSE.md)

# license_documents <build-dir> - the documents a build ships, one per line.
license_documents() {
    local dir="$1" doc
    for doc in "${LICENSE_DOCUMENTS[@]}"; do
        [[ -f "$dir/$doc" ]] && printf '%s\n' "$dir/$doc"
    done
    return 0
}

# license_id <build-dir>
#
# A checksum identifying the exact terms a build ships with, or nothing when
# it ships none, which is true of every build before v0.1.6. The file names
# are part of it, so moving text from one document to the other is a change.
license_id() {
    local docs=() doc
    mapfile -t docs < <(license_documents "$1")
    (( ${#docs[@]} )) || return 0
    for doc in "${docs[@]}"; do
        printf '%s\0' "$(basename "$doc")"
        cat -- "$doc"
    done | sha256sum | cut -c1-64
}

# license_acceptance <id> - the recorded acceptance as JSON, or nothing.
license_acceptance() {
    [[ -n "$1" && -f "$FILE_STATE" ]] || return 0
    jq -c --arg id "$1" '.license_accepted[$id] // empty' "$FILE_STATE" 2>/dev/null
}

license_is_accepted() { [[ -n "$(license_acceptance "$1")" ]]; }

# license_accepted_for <build-dir>
#
# True only when the build ships terms and they were accepted. A build
# without terms needs nothing passed to it.
license_accepted_for() {
    local id; id="$(license_id "$1")"
    [[ -n "$id" ]] && license_is_accepted "$id"
}

# license_record <id> <method>
#
# Who accepted, when, and how. The terms bind "the individual accepting
# them", so the record names the account behind sudo rather than root.
license_record() {
    local id="$1" method="$2" by
    by="${SUDO_USER:-$(id -un 2>/dev/null || echo unknown)}"
    state_apply '.license_accepted = ((.license_accepted // {}) + {($id): {accepted_at: $at, accepted_by: $by, method: $method}})' \
        --arg id "$id" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg by "$by" --arg method "$method"
}

# license_require <build-dir>
#
#   0           the build ships no terms, or they have been accepted, now
#               or earlier
#   EX_LICENSE  they have not been accepted
#
# Asks at a terminal. Without one, only --accept-eula accepts.
license_require() {
    local dir="$1" id
    id="$(license_id "$dir")"
    [[ -n "$id" ]] || return 0
    license_is_accepted "$id" && return 0

    _license_notice "$dir"

    if (( ACCEPT_EULA )); then
        license_record "$id" "--accept-eula" || return "$EX_LICENSE"
        ok "License terms accepted (--accept-eula)"
        return 0
    fi

    if ! is_interactive; then
        warn "The license terms have not been accepted."
        out_line "    Read them in the files listed above. To accept them, run the same"
        out_line "    command again with --accept-eula, or on a terminal without it."
        return "$EX_LICENSE"
    fi

    _license_offer_reading "$dir"
    if _license_ask; then
        license_record "$id" "terminal" || return "$EX_LICENSE"
        ok "License terms accepted"
        return 0
    fi
    warn "License terms not accepted."
    return "$EX_LICENSE"
}

_license_notice() {
    local dir="$1" doc
    out_title "License terms"
    out_line "  This Coop server build comes with license terms of its own. The"
    out_line "  server will not host a campaign until they have been accepted:"
    out_line ""
    while IFS= read -r doc; do
        out_line "    $doc"
    done < <(license_documents "$dir")
    out_line ""
    out_line "  They are the Bannerlord Coop team's terms, not this installer's, and"
    out_line "  accepting them is your decision. Acceptance alone does not permit"
    out_line "  commercial hosting; the terms say what does."
    out_line ""
}

# Offers the documents before the question that matters.
_license_offer_reading() {
    local reply
    printf 'Read them now? [Y/n] ' >&2
    read -r reply || reply="n"
    reply="${reply,,}"
    [[ -z "$reply" || "$reply" == "y" || "$reply" == "yes" ]] && license_show "$1"
    return 0
}

# The one question in this project that --yes must not answer, which is
# why it does not go through confirm().
_license_ask() {
    local reply
    printf 'Do you accept these license terms? [y/N] ' >&2
    read -r reply || reply=""
    reply="${reply,,}"
    [[ "$reply" == "y" || "$reply" == "yes" ]]
}

# license_show <build-dir> - the documents, through a pager on a terminal.
license_show() {
    local docs=() doc
    mapfile -t docs < <(license_documents "$1")
    if (( ${#docs[@]} == 0 )); then
        out_line "This build ships no license terms."
        return 0
    fi
    {
        for doc in "${docs[@]}"; do
            printf '==> %s <==\n\n' "$doc"
            tr -d '\r' <"$doc"
            printf '\n'
        done
    } | if [[ -t 1 ]] && command -v less >/dev/null 2>&1; then less; else cat; fi
}

# ------------------------------------------------------------------ report --
license_status_report() {
    local id acceptance docs=()
    id="$(license_id "$DIR_SERVER")"
    acceptance="$(license_acceptance "$id")"
    mapfile -t docs < <(license_documents "$DIR_SERVER")

    if is_json; then
        jq -n --arg id "$id" --argjson acc "${acceptance:-null}" \
              --argjson docs "$(printf '%s\n' "${docs[@]}" | jq -R . | jq -s 'map(select(length > 0))')" \
            '{ok:true, terms:($id != ""), accepted:($id == "" or $acc != null),
              terms_id:(if $id == "" then null else $id end), documents:$docs,
              accepted_at:($acc.accepted_at // null), accepted_by:($acc.accepted_by // null),
              method:($acc.method // null)}'
        return 0
    fi

    out_title "License terms"
    if [[ -z "$id" ]]; then
        out_kv "Terms" "the installed build ships none, so there is nothing to accept"
        out_line ""
        return 0
    fi

    local doc first=1
    for doc in "${docs[@]}"; do
        if (( first )); then out_kv "Documents" "$doc"; first=0
        else out_kv "" "$doc"; fi
    done
    if [[ -n "$acceptance" ]]; then
        out_kv "Accepted" "$(jq -r '"yes, \(.accepted_at) by \(.accepted_by) (\(.method))"' <<<"$acceptance")" "$C_GRN"
    else
        out_kv "Accepted" "no, so the server will not start" "$C_YEL"
    fi
    out_kv "Terms ID" "${id:0:16}"
    out_line ""
    out_line "  Read them:  coop eula show"
    [[ -n "$acceptance" ]] || out_line "  Accept:     coop eula accept"
    out_line ""
}
