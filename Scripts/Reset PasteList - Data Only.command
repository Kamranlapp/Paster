#!/bin/bash

set -u
script_directory="$(cd "$(dirname "$0")" && pwd)"

echo "PasteList reset launcher"
echo "Selected mode: DATA ONLY — keep installed apps and remove all saved state."
echo

"$script_directory/reset-clean-install.sh" --mode data-only "$@"
status=$?

if [[ -t 0 ]]; then
    echo
    read -r -p "Press Return to close this window." _
fi
exit "$status"
