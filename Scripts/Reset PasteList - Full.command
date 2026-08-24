#!/bin/bash

set -u
script_directory="$(cd "$(dirname "$0")" && pwd)"

echo "PasteList reset launcher"
echo "Selected mode: FULL — remove installed PasteList/PasteDebug apps and all data."
echo

"$script_directory/reset-clean-install.sh" --mode full "$@"
status=$?

if [[ -t 0 ]]; then
    echo
    read -r -p "Press Return to close this window." _
fi
exit "$status"
