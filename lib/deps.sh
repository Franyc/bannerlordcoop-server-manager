# shellcheck shell=bash
#
# deps.sh - phase B: install what the preflight found missing.
#
# This is the first file that changes the system, and it only runs after
# lib/compat.sh has reported and the user has agreed.
#
# WHAT THIS FILE WILL NOT DO
# --------------------------
# No third-party PPAs. No downloading loose .deb files. No pulling libraries
# out of another release. No overwriting system libraries. If a distribution
# cannot supply a dependency from its own repositories - or, for Docker,
# from Docker's official repository - the answer is that the distribution is
# unsupported, not that we work around it. Reproducibility is worth more
# than one more supported release.

readonly DOCKER_PACKAGES=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)

# --------------------------------------------------------- base packages --
deps_install_packages() {
    (( $# )) || return 0
    step "Installing packages: $*"
    case "$PKG_MANAGER" in
        apt)
            DEBIAN_FRONTEND=noninteractive apt-get update -qq \
                || die "$EX_DEPS" "apt-get update failed." "Check your network and /etc/apt/sources.list."
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "$@" \
                || die "$EX_DEPS" "Failed to install: $*"
            ;;
        dnf|yum)
            "$PKG_MANAGER" install -y -q "$@" || die "$EX_DEPS" "Failed to install: $*"
            ;;
        zypper)
            zypper --non-interactive install -y "$@" || die "$EX_DEPS" "Failed to install: $*"
            ;;
        pacman)
            pacman -Sy --noconfirm "$@" || die "$EX_DEPS" "Failed to install: $*"
            ;;
        *)
            die "$EX_DEPS" \
                "No supported package manager found." \
                "Install these by hand, then run the installer again: $*"
            ;;
    esac
    ok "Packages installed"
}

deps_install_base() {
    local missing=()
    compat_missing_packages missing "${REQUIRED_COMMANDS[@]}"
    if (( ${#missing[@]} == 0 )); then
        ok "Base tools already present"
        return 0
    fi
    case "$PKG_MANAGER" in
        apt)      deps_install_packages "${REQUIRED_PACKAGES_APT[@]}" ;;
        dnf|yum)  deps_install_packages "${REQUIRED_PACKAGES_DNF[@]}" ;;
        *)        deps_install_packages "${missing[@]}" ;;
    esac
    compat_missing_packages missing "${REQUIRED_COMMANDS[@]}"
    (( ${#missing[@]} == 0 )) || die "$EX_DEPS" \
        "Still missing after installation: ${missing[*]}" \
        "Your distribution may package these under different names."
}

# ---------------------------------------------------------------- docker --
# Installed from Docker's own repository, which is the vendor's supported
# path - not a third-party PPA.
deps_install_docker() {
    if compat_docker_running && [[ -n "$(compat_compose_version)" ]]; then
        ok "Docker Engine and Compose already available"
        return 0
    fi

    step "Installing Docker Engine"
    case "$PKG_MANAGER" in
        apt)  _deps_docker_apt ;;
        dnf|yum) _deps_docker_rpm ;;
        *)
            die "$EX_DEPS" \
                "Cannot install Docker automatically on this system." \
                "Install Docker Engine and the Compose plugin, then run the installer again." \
                "https://docs.docker.com/engine/install/"
            ;;
    esac

    systemctl enable --now docker >/dev/null 2>&1 || true
    compat_docker_running || die "$EX_DEPS" \
        "Docker was installed but the daemon is not responding." \
        "Check: systemctl status docker"
    [[ -n "$(compat_compose_version)" ]] || die "$EX_DEPS" \
        "The Docker Compose plugin is missing after installation."
    ok "Docker Engine $(compat_docker_version), Compose $(compat_compose_version)"
}

_deps_docker_apt() {
    local codename repo_os="$OS_ID"
    # Derivatives (Linux Mint, Pop!_OS, ...) have no Docker repository of
    # their own but track a base release that does.
    case "$OS_ID" in
        ubuntu|debian) ;;
        *) [[ "$OS_LIKE" == *ubuntu* ]] && repo_os="ubuntu"
           [[ "$OS_LIKE" == *debian* ]] && repo_os="debian" ;;
    esac

    codename="$(sed -n 's/^VERSION_CODENAME=//p' /etc/os-release | tr -d '"' | head -1)"
    [[ -n "$codename" ]] || codename="$(sed -n 's/^UBUNTU_CODENAME=//p' /etc/os-release | tr -d '"' | head -1)"
    [[ -n "$codename" ]] || die "$EX_DEPS" \
        "Cannot determine the distribution codename needed for Docker's repository." \
        "Install Docker Engine by hand: https://docs.docker.com/engine/install/"

    deps_install_packages ca-certificates curl gnupg

    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/${repo_os}/gpg" -o /etc/apt/keyrings/docker.asc \
        || die "$EX_DEPS" "Could not download Docker's signing key."
    chmod a+r /etc/apt/keyrings/docker.asc

    # deb822 format: one file, explicitly signed, no legacy apt-key.
    cat >/etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/${repo_os}
Suites: ${codename}
Components: stable
Architectures: amd64
Signed-By: /etc/apt/keyrings/docker.asc
EOF

    deps_install_packages "${DOCKER_PACKAGES[@]}"
}

_deps_docker_rpm() {
    local repo_os="$OS_ID"
    case "$OS_ID" in
        fedora) repo_os="fedora" ;;
        *)      repo_os="centos" ;;   # rocky, alma, rhel all use the centos repo
    esac
    if command -v dnf >/dev/null 2>&1; then
        dnf -y -q install dnf-plugins-core || true
        dnf -y -q config-manager --add-repo "https://download.docker.com/linux/${repo_os}/docker-ce.repo" \
            || dnf -y -q config-manager addrepo --from-repofile="https://download.docker.com/linux/${repo_os}/docker-ce.repo" \
            || die "$EX_DEPS" "Could not add Docker's repository."
    fi
    deps_install_packages "${DOCKER_PACKAGES[@]}"
}

# ---------------------------------------------------------- service user --
# The old single-server setup required a user with UID 1000 to exist. That
# is an assumption about the host, not a requirement of the software: what
# actually matters is that the files inside the container and the files on
# the host are owned by the same numeric ID. So the manager creates its own
# system user and records that ID in the configuration.
deps_ensure_service_user() {
    local user="bannerlordcoop" uid gid

    if id -u "$user" >/dev/null 2>&1; then
        debug "service user '$user' already exists"
    else
        step "Creating service user '$user'"
        if command -v useradd >/dev/null 2>&1; then
            groupadd --system "$user" 2>/dev/null || true
            useradd --system --gid "$user" --home-dir "$INSTALL_DIR" \
                    --no-create-home --shell /usr/sbin/nologin "$user" \
                || die "$EX_DEPS" "Could not create the service user '$user'."
        else
            die "$EX_DEPS" "useradd is not available; create a user named '$user' by hand."
        fi
    fi

    uid="$(id -u "$user")"
    gid="$(id -g "$user")"
    cfg_set PUID "$uid"
    cfg_set PGID "$gid"
    ok "Service user '$user' (uid $uid, gid $gid)"
}

# ------------------------------------------------------ docker log rotation --
# Suggested, never imposed. Rewriting a host's Docker daemon configuration
# behind its owner's back is not something an application installer should
# do - other containers on the same host depend on it.
deps_suggest_daemon_config() {
    local target=/etc/docker/daemon.json
    if [[ -f "$target" ]]; then
        grep -q 'log-opts' "$target" 2>/dev/null && return 0
        warn "Container logs are not size-limited on this host."
        out_line "    Consider adding log rotation to $target:"
        out_line "      \"log-driver\": \"json-file\","
        out_line "      \"log-opts\": { \"max-size\": \"50m\", \"max-file\": \"5\" }"
        return 0
    fi
    # Per-container limits are set in compose.yaml regardless, so this is a
    # nicety rather than a requirement.
    debug "no /etc/docker/daemon.json; per-container log limits apply"
}
