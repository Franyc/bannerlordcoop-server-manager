# shellcheck shell=bash
#
# compat.sh - read-only system detection and the compatibility matrix.
#
# NOTHING IN THIS FILE CHANGES THE SYSTEM. It reads /etc/os-release, asks
# the package manager what it could install, looks at free memory and disk,
# and reports. Installing anything is lib/deps.sh, and only after the user
# has seen this report.
#
# WHY THE MATRIX LOOKS THE WAY IT DOES
# ------------------------------------
# Wine, the .NET runtime and the game server all live inside the container,
# built on Debian. The host distribution therefore barely matters: what the
# host has to provide is x86_64, a Docker Engine, systemd for the timers,
# and a handful of standard tools. So the matrix tracks Docker CE support,
# not the game.
#
# The one hard exclusion is architecture. The server is a Windows x64
# binary run under Wine; on arm64 that would need box64 or FEX - exactly the
# kind of dependency hack this project refuses to perform. Many cheap VPS
# offers are arm64 today, so this is checked first.

# Detection results, filled by compat_detect().
OS_ID=""; OS_VERSION=""; OS_NAME=""; OS_LIKE=""
SYS_ARCH=""; SYS_KERNEL=""; SYS_INIT=""; PKG_MANAGER=""
SYS_MEM_MB=0; SYS_DISK_GB=0
COMPAT_STATUS=""          # supported | experimental | unsupported
COMPAT_REASON=""

# Every check appends "status<TAB>label<TAB>detail".
declare -ga COMPAT_CHECKS=()

_check() { COMPAT_CHECKS+=("$1"$'\t'"$2"$'\t'"${3:-}"); }

# Host packages the manager itself needs, beyond Docker.
readonly REQUIRED_COMMANDS=(curl git jq rsync tar flock awk sed grep)
readonly REQUIRED_PACKAGES_APT=(ca-certificates curl git jq rsync tar unzip util-linux)
readonly REQUIRED_PACKAGES_DNF=(ca-certificates curl git jq rsync tar unzip util-linux)

# Minimums are drawn from measured behaviour, not from guesswork:
# the server itself uses 1.2-1.6 GB, and the Workshop item is ~6.1 GB held
# in three places (workshop/, server/, rollback/) plus backups.
readonly MIN_MEM_MB=3800
readonly REC_MEM_MB=7500
readonly MIN_DISK_GB=25
readonly REC_DISK_GB=40

# ---------------------------------------------------------------- detection --
compat_detect() {
    if [[ -r /etc/os-release ]]; then
        # Read without sourcing: this file is trusted, but the habit is not
        # worth breaking for one exception.
        OS_ID="$(sed -n 's/^ID=//p'         /etc/os-release | tr -d '"' | head -1)"
        OS_VERSION="$(sed -n 's/^VERSION_ID=//p' /etc/os-release | tr -d '"' | head -1)"
        OS_NAME="$(sed -n 's/^PRETTY_NAME=//p'   /etc/os-release | tr -d '"' | head -1)"
        OS_LIKE="$(sed -n 's/^ID_LIKE=//p'       /etc/os-release | tr -d '"' | head -1)"
    fi
    [[ -n "$OS_NAME" ]] || OS_NAME="unknown Linux"

    SYS_ARCH="$(uname -m)"
    SYS_KERNEL="$(uname -r)"

    if [[ -d /run/systemd/system ]]; then SYS_INIT="systemd"
    else SYS_INIT="$(ps -p 1 -o comm= 2>/dev/null || echo unknown)"; fi

    if   command -v apt-get >/dev/null 2>&1; then PKG_MANAGER="apt"
    elif command -v dnf     >/dev/null 2>&1; then PKG_MANAGER="dnf"
    elif command -v yum     >/dev/null 2>&1; then PKG_MANAGER="yum"
    elif command -v zypper  >/dev/null 2>&1; then PKG_MANAGER="zypper"
    elif command -v pacman  >/dev/null 2>&1; then PKG_MANAGER="pacman"
    else PKG_MANAGER="unknown"; fi

    SYS_MEM_MB=$(( $(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null || echo 0) / 1024 ))
}

# The first existing ancestor of the install path - free space has to be
# measured on the filesystem that will actually hold the data, which may not
# exist yet.
_existing_ancestor() {
    local p="${1:-/}"
    while [[ ! -d "$p" && "$p" != "/" ]]; do p="$(dirname "$p")"; done
    printf '%s' "$p"
}

compat_disk_gb() {
    local path; path="$(_existing_ancestor "${1:-/}")"
    df -BG --output=avail "$path" 2>/dev/null | tail -1 | tr -dc '0-9' || echo 0
}

# ------------------------------------------------------------------ matrix --
# Returns the status and sets COMPAT_REASON. Version comparison is done on
# the major version only, because point releases never change Docker CE
# availability.
compat_matrix() {
    local id="$OS_ID" ver="$OS_VERSION" major="${OS_VERSION%%.*}"

    if [[ "$SYS_ARCH" != "x86_64" && "$SYS_ARCH" != "amd64" ]]; then
        COMPAT_STATUS="unsupported"
        COMPAT_REASON="The dedicated server is a Windows x64 binary run under Wine. On ${SYS_ARCH} that would require an x86 emulation layer, which this installer will not set up."
        return
    fi

    case "$id" in
        ubuntu)
            case "$ver" in
                22.04|24.04|26.04) COMPAT_STATUS="supported" ;;
                *) if [[ "$major" =~ ^[0-9]+$ ]] && (( major >= 20 )); then
                       COMPAT_STATUS="experimental"
                       COMPAT_REASON="Ubuntu $ver is not one of the tested LTS releases."
                   else
                       COMPAT_STATUS="unsupported"
                       COMPAT_REASON="Ubuntu $ver is too old to provide a current Docker Engine."
                   fi ;;
            esac ;;
        debian)
            case "$major" in
                12|13) COMPAT_STATUS="supported" ;;
                11)    COMPAT_STATUS="experimental"; COMPAT_REASON="Debian 11 is untested here and nearing end of life." ;;
                *)     COMPAT_STATUS="unsupported"; COMPAT_REASON="Debian $ver is too old to provide a current Docker Engine." ;;
            esac ;;
        rocky|almalinux|rhel|centos)
            if [[ "$major" =~ ^[0-9]+$ ]] && (( major >= 9 )); then
                COMPAT_STATUS="experimental"
                COMPAT_REASON="Docker CE is available for ${OS_NAME}, but this installer has not been tested on it."
            else
                COMPAT_STATUS="unsupported"
                COMPAT_REASON="${OS_NAME} is too old to provide a current Docker Engine."
            fi ;;
        fedora)
            COMPAT_STATUS="experimental"
            COMPAT_REASON="Fedora moves faster than this installer is tested against." ;;
        *)
            if [[ "$OS_LIKE" == *debian* || "$OS_LIKE" == *rhel* || "$OS_LIKE" == *fedora* ]]; then
                COMPAT_STATUS="experimental"
                COMPAT_REASON="${OS_NAME} is not in the compatibility matrix, but resembles a supported distribution."
            else
                COMPAT_STATUS="unsupported"
                COMPAT_REASON="${OS_NAME} is not in the compatibility matrix."
            fi ;;
    esac

    # systemd is how backups and update checks are scheduled. Its absence
    # does not stop a server from running, so it downgrades rather than
    # blocks.
    if [[ "$COMPAT_STATUS" == "supported" && "$SYS_INIT" != "systemd" ]]; then
        COMPAT_STATUS="experimental"
        COMPAT_REASON="No systemd found (init is '${SYS_INIT}'). Scheduled backups and update checks will not be installed."
    fi
}

# ---------------------------------------------------- package availability --
# Checking the OS version is not enough: an old release may still be
# installable but no longer carry the packages. Ask the package manager.
compat_package_available() {
    local pkg="$1"
    case "$PKG_MANAGER" in
        apt)    apt-cache policy -- "$pkg" 2>/dev/null | grep -qE '^\s+Candidate: [^(]' ;;
        dnf)    dnf --quiet list --available "$pkg" >/dev/null 2>&1 || dnf --quiet list --installed "$pkg" >/dev/null 2>&1 ;;
        yum)    yum --quiet list available "$pkg" >/dev/null 2>&1 || yum --quiet list installed "$pkg" >/dev/null 2>&1 ;;
        zypper) zypper --quiet search --match-exact "$pkg" >/dev/null 2>&1 ;;
        pacman) pacman -Si "$pkg" >/dev/null 2>&1 ;;
        *)      return 1 ;;
    esac
}

compat_missing_packages() {
    local -n _out="$1"; shift
    local pkg
    _out=()
    for pkg in "$@"; do
        command -v "$pkg" >/dev/null 2>&1 && continue
        _out+=("$pkg")
    done
}

# ------------------------------------------------------------------ docker --
compat_docker_version() { docker version --format '{{.Server.Version}}' 2>/dev/null; }
compat_docker_running() { docker info >/dev/null 2>&1; }
compat_compose_version() { docker compose version --short 2>/dev/null; }

# -------------------------------------------------------------------- ports --
port_in_use() {
    local port="$1" proto="${2:-udp}"
    if command -v ss >/dev/null 2>&1; then
        [[ "$proto" == "udp" ]] && ss -lunH 2>/dev/null | grep -qE "[:.]${port}\b" \
                                || ss -ltnH 2>/dev/null | grep -qE "[:.]${port}\b"
    else
        return 1   # cannot tell; treated as free and re-checked at start
    fi
}

# Finds the next free port at or after the given one, so automatic port
# selection has something to select.
find_free_port() {
    local start="${1:-4200}" proto="${2:-udp}" p
    for (( p = start; p < start + 200; p++ )); do
        port_in_use "$p" "$proto" || { printf '%d' "$p"; return 0; }
    done
    return 1
}

# ---------------------------------------------------------------- network --
compat_can_reach() {
    curl -fsS --max-time "${2:-8}" -o /dev/null "$1" 2>/dev/null
}

# ------------------------------------------------------------- the preflight --
# compat_preflight <install-dir> <game-port>
#
# Runs every read-only check and fills COMPAT_CHECKS. Returns:
#   0  everything supported
#   1  usable, but with warnings (experimental, or a soft limit missed)
#   2  unsupported - do not continue
compat_preflight() {
    local install_dir="${1:-/srv/bannerlordcoop}" port="${2:-4200}"
    local worst=0 missing=()

    COMPAT_CHECKS=()
    compat_detect
    compat_matrix
    SYS_DISK_GB="$(compat_disk_gb "$install_dir")"

    # -- operating system -----------------------------------------------
    case "$COMPAT_STATUS" in
        supported)    _check ok   "Operating system" "$OS_NAME" ;;
        experimental) _check warn "Operating system" "$OS_NAME - experimental. $COMPAT_REASON"; worst=1 ;;
        unsupported)  _check fail "Operating system" "$OS_NAME - unsupported. $COMPAT_REASON"; worst=2 ;;
    esac
    if [[ "$SYS_ARCH" == "x86_64" || "$SYS_ARCH" == "amd64" ]]; then
        _check ok   "Architecture" "$SYS_ARCH"
    else
        _check fail "Architecture" "$SYS_ARCH is not supported"; worst=2
    fi
    _check info "Kernel" "$SYS_KERNEL"

    # -- privileges -------------------------------------------------------
    if [[ "$(id -u)" -eq 0 ]]; then
        _check ok   "Privileges" "running as root"
    else
        _check fail "Privileges" "root is required to install"; worst=2
    fi

    # -- package manager and dependencies ---------------------------------
    if [[ "$PKG_MANAGER" == "unknown" ]]; then
        _check warn "Package manager" "none recognised - dependencies must be installed by hand"
        (( worst < 1 )) && worst=1
    else
        _check ok "Package manager" "$PKG_MANAGER"
    fi

    compat_missing_packages missing "${REQUIRED_COMMANDS[@]}"
    if (( ${#missing[@]} == 0 )); then
        _check ok "Required tools" "all present"
    else
        # Present is better than installable, but installable is enough.
        local unavailable=() pkg
        for pkg in "${missing[@]}"; do
            compat_package_available "$pkg" || unavailable+=("$pkg")
        done
        if (( ${#unavailable[@]} == 0 )); then
            _check warn "Required tools" "will be installed: ${missing[*]}"
            (( worst < 1 )) && worst=1
        else
            _check fail "Required tools" "not available from your package repositories: ${unavailable[*]}"
            worst=2
        fi
    fi

    # -- docker ------------------------------------------------------------
    local dver cver
    dver="$(compat_docker_version)"
    if [[ -n "$dver" ]]; then
        if compat_docker_running; then
            _check ok "Docker Engine" "$dver"
        else
            _check fail "Docker Engine" "installed ($dver) but the daemon is not reachable"; worst=2
        fi
    else
        _check warn "Docker Engine" "not installed - will be installed from Docker's own repository"
        (( worst < 1 )) && worst=1
    fi

    cver="$(compat_compose_version)"
    if [[ -n "$cver" ]]; then
        _check ok "Docker Compose" "$cver"
    else
        _check warn "Docker Compose" "compose plugin missing - will be installed"
        (( worst < 1 )) && worst=1
    fi

    # -- resources ---------------------------------------------------------
    if   (( SYS_MEM_MB >= REC_MEM_MB )); then _check ok   "Memory" "${SYS_MEM_MB} MB"
    elif (( SYS_MEM_MB >= MIN_MEM_MB )); then _check warn "Memory" "${SYS_MEM_MB} MB - runs, but ${REC_MEM_MB} MB is recommended"; (( worst < 1 )) && worst=1
    else _check fail "Memory" "${SYS_MEM_MB} MB - at least ${MIN_MEM_MB} MB is required"; worst=2
    fi

    if   (( SYS_DISK_GB >= REC_DISK_GB )); then _check ok   "Disk space" "${SYS_DISK_GB} GB free at $(_existing_ancestor "$install_dir")"
    elif (( SYS_DISK_GB >= MIN_DISK_GB )); then _check warn "Disk space" "${SYS_DISK_GB} GB free - tight; ${REC_DISK_GB} GB is recommended"; (( worst < 1 )) && worst=1
    else _check fail "Disk space" "${SYS_DISK_GB} GB free - at least ${MIN_DISK_GB} GB is required (game files are about 18 GB across three directories)"; worst=2
    fi

    # -- ports -------------------------------------------------------------
    if port_in_use "$port" udp; then
        _check fail "Game port" "UDP $port is already in use"; worst=2
    else
        _check ok "Game port" "UDP $port is free"
    fi

    # -- connectivity ------------------------------------------------------
    local unreachable=()
    compat_can_reach "https://api.steampowered.com/" || unreachable+=("Steam")
    compat_can_reach "https://download.docker.com/"  || unreachable+=("Docker")
    compat_can_reach "https://dl.winehq.org/"        || unreachable+=("WineHQ")
    if (( ${#unreachable[@]} == 0 )); then
        _check ok "Internet access" "Steam, Docker and WineHQ reachable"
    else
        _check fail "Internet access" "cannot reach: ${unreachable[*]}"; worst=2
    fi

    return "$worst"
}

# Prints COMPAT_CHECKS for a human. The machine-readable form lives in
# lib/health.sh, which reuses the same array.
compat_report() {
    local row status label detail
    out_title "System compatibility"
    for row in "${COMPAT_CHECKS[@]}"; do
        IFS=$'\t' read -r status label detail <<<"$row"
        case "$status" in
            info) out_check info "$(printf '%-18s %s' "$label" "$detail")" ;;
            *)    out_check "$status" "$(printf '%-18s %s' "$label" "$detail")" ;;
        esac
    done
    out_line ""
}
