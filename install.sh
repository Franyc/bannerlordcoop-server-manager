#!/usr/bin/env bash
#
# install.sh - bootstrap for the Bannerlord Coop Server Manager.
#
#   git clone https://github.com/PlodyIce/bannerlordcoop-server-manager
#   cd bannerlordcoop-server-manager
#   sudo ./install.sh
#
# This script does as little as possible. It checks that bash is new
# enough, then hands over to bin/coop, which performs the read-only
# compatibility check first and changes nothing until you have seen it.
# Everything install.sh could do, `coop install` can do too - so there is
# only one implementation to keep correct.

set -euo pipefail

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
    echo "This installer needs bash 4 or newer (found ${BASH_VERSION:-unknown})." >&2
    exit 20
fi

if [[ "$(uname -s)" != "Linux" ]]; then
    echo "The Bannerlord Coop dedicated server runs on Linux with Docker." >&2
    echo "Detected: $(uname -s)" >&2
    exit 20
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ $EUID -ne 0 ]]; then
    echo "Installing needs root. Re-run with:" >&2
    echo "    sudo ./install.sh $*" >&2
    exit 2
fi

exec "$ROOT/bin/coop" install "$@"
