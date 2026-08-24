#!/bin/bash

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: Scripts/reset-clean-install.sh [--mode full|data-only] [--dry-run]

Resets both PasteList identities (PasteList and PasteDebug) to first-launch state.

Modes:
  full       Moves installed apps and all local app data to a timestamped
             recovery folder in the Trash. This is the default.
  data-only  Keeps installed apps, but moves all local app data to the same
             kind of recovery folder.

Both modes stop PasteList, unregister Launch at Login through SMAppService,
reset only Accessibility and PostEvent, and clear all local PasteList data.

The repository, Xcode Archives, DerivedData, system clipboard, Keychain, and
other apps' login items are not touched. The Trash is never emptied.
EOF
}

mode="full"
dry_run=false

while (($# > 0)); do
    case "$1" in
        --mode)
            if (($# < 2)); then
                echo "error: --mode requires full or data-only" >&2
                exit 2
            fi
            mode="$2"
            shift
            ;;
        --keep-apps)
            mode="data-only"
            ;;
        --dry-run)
            dry_run=true
            ;;
        --yes)
            # Backward-compatible no-op: reset no longer asks for confirmation.
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "error: Unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
    shift
done

case "$mode" in
    full|data-only) ;;
    *)
        echo "error: Unknown mode: $mode" >&2
        usage >&2
        exit 2
        ;;
esac

launch_services="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
launch_at_login_reset_argument="--unregister-launch-at-login-for-reset"
timestamp="$(/bin/date '+%Y-%m-%d_%H-%M-%S')"
trash_root="$HOME/.Trash/PasteList-clean-reset-$timestamp"
cleanup_incomplete=false
cleanup_failures=()

bundle_identifiers=(
    "com.kam.pastelist"
    "com.kam.pastelist.debug"
)

app_paths=(
    "/Applications/PasteList.app"
    "/Applications/PasteDebug.app"
    "$HOME/Applications/PasteList.app"
    "$HOME/Applications/PasteDebug.app"
)

app_executables=(
    "/Applications/PasteList.app/Contents/MacOS/PasteList"
    "/Applications/PasteDebug.app/Contents/MacOS/PasteDebug"
    "$HOME/Applications/PasteList.app/Contents/MacOS/PasteList"
    "$HOME/Applications/PasteDebug.app/Contents/MacOS/PasteDebug"
)

app_labels=(
    "app-system-PasteList.app"
    "app-system-PasteDebug.app"
    "app-user-PasteList.app"
    "app-user-PasteDebug.app"
)

run() {
    if $dry_run; then
        printf 'DRY RUN:'
        printf ' %q' "$@"
        printf '\n'
    else
        "$@"
    fi
}

run_launch_at_login_reset() {
    local app_executable="$1"

    if $dry_run; then
        run "$app_executable" "$launch_at_login_reset_argument"
        return 0
    fi

    "$app_executable" "$launch_at_login_reset_argument" &
    local reset_process_id=$!
    for _ in {1..40}; do
        if ! /bin/kill -0 "$reset_process_id" >/dev/null 2>&1; then
            if wait "$reset_process_id"; then
                return 0
            else
                return $?
            fi
        fi
        /bin/sleep 0.25
    done

    /bin/kill "$reset_process_id" >/dev/null 2>&1 || true
    /bin/sleep 0.25
    /bin/kill -KILL "$reset_process_id" >/dev/null 2>&1 || true
    wait "$reset_process_id" >/dev/null 2>&1 || true
    return 124
}

record_failure() {
    cleanup_incomplete=true
    cleanup_failures+=("$1")
    echo "warning: $1" >&2
}

delete_preferences_domain() {
    local domain="$1"
    local label="$2"

    if $dry_run; then
        echo "DRY RUN: /usr/bin/defaults delete $domain"
        return 0
    fi
    if /usr/bin/defaults read "$domain" >/dev/null 2>&1; then
        if ! /usr/bin/defaults delete "$domain" >/dev/null 2>&1; then
            record_failure "Could not delete $label preferences."
        elif /usr/bin/defaults read "$domain" >/dev/null 2>&1; then
            record_failure "$label preferences are still present after deletion."
        fi
    fi
}

move_to_reset_folder() {
    local source_path="$1"
    local label="$2"

    [[ -e "$source_path" || -L "$source_path" ]] || return 0
    if ! run /bin/mkdir -p "$trash_root"; then
        record_failure "Could not create the recovery folder in the Trash; move $source_path manually."
        return 0
    fi
    if ! run /bin/mv "$source_path" "$trash_root/$label"; then
        record_failure "macOS protected $source_path; move it to the Trash with Finder."
    fi
}

mode_description="FULL — apps and data"
if [[ "$mode" == "data-only" ]]; then
    mode_description="DATA ONLY — installed apps will be kept"
fi

echo "PasteList clean reset"
echo "Mode: $mode_description"
echo "Both com.kam.pastelist and com.kam.pastelist.debug will be reset."
echo "Recoverable files will be moved to:"
echo "  $trash_root"
echo "The repository, Xcode Archives, DerivedData, and system clipboard will not be changed."

# Stop only executables inside PasteList/PasteDebug app bundles.
while read -r process_id executable_path; do
    case "$executable_path" in
        */PasteList.app/Contents/MacOS/PasteList|*/PasteList.app/Contents/MacOS/PasteList\ *|*/PasteDebug.app/Contents/MacOS/PasteDebug|*/PasteDebug.app/Contents/MacOS/PasteDebug\ *)
            if ! run /bin/kill "$process_id"; then
                record_failure "Could not stop PasteList process $process_id."
            fi
            ;;
    esac
done < <(/bin/ps ax -o pid=,command=)

if ! $dry_run; then
    for _ in 1 2 3 4 5; do
        if ! /bin/ps ax -o command= | /usr/bin/grep -Eq '/Paste(List|Debug)\.app/Contents/MacOS/Paste(List|Debug)( |$)'; then
            break
        fi
        /bin/sleep 1
    done

    while read -r process_id executable_path; do
        case "$executable_path" in
            */PasteList.app/Contents/MacOS/PasteList|*/PasteList.app/Contents/MacOS/PasteList\ *|*/PasteDebug.app/Contents/MacOS/PasteDebug|*/PasteDebug.app/Contents/MacOS/PasteDebug\ *)
                if ! /bin/kill -KILL "$process_id"; then
                    record_failure "Could not force-stop PasteList process $process_id."
                fi
                ;;
        esac
    done < <(/bin/ps ax -o pid=,command=)
fi

# Each installed PasteList executable exposes one reset-only argument that
# unregisters its own main-app login item and exits before initializing storage.
installed_app_found=false
for index in "${!app_paths[@]}"; do
    app_path="${app_paths[$index]}"
    app_executable="${app_executables[$index]}"
    [[ -d "$app_path" ]] || continue
    installed_app_found=true
    if [[ ! -x "$app_executable" ]]; then
        record_failure "Installed app has no executable reset helper at $app_executable."
        continue
    fi
    if ! run_launch_at_login_reset "$app_executable"; then
        record_failure "Could not unregister Launch at Login through $app_path."
    fi
done

if ! $installed_app_found; then
    echo "Note: no installed app bundle was available to unregister Launch at Login."
    echo "A cleanly reinstalled PasteList will repeat the unregister operation on first launch."
fi

# Reset only the authorization services PasteList uses for Assistive Paste.
for bundle_identifier in "${bundle_identifiers[@]}"; do
    for service in Accessibility PostEvent; do
        if ! run /usr/bin/tccutil reset "$service" "$bundle_identifier"; then
            record_failure "Could not reset $service for $bundle_identifier."
        fi
    done
    delete_preferences_domain "$bundle_identifier" "$bundle_identifier host"
    delete_preferences_domain \
        "$HOME/Library/Containers/$bundle_identifier/Data/Library/Preferences/$bundle_identifier" \
        "$bundle_identifier sandbox"
done

if [[ "$mode" == "full" ]]; then
    for index in "${!app_paths[@]}"; do
        app_path="${app_paths[$index]}"
        [[ -d "$app_path" ]] || continue
        if ! run "$launch_services" -u "$app_path"; then
            record_failure "Could not unregister $app_path from LaunchServices."
        fi
        move_to_reset_folder "$app_path" "${app_labels[$index]}"
    done
fi

for bundle_identifier in "${bundle_identifiers[@]}"; do
    move_to_reset_folder "$HOME/Library/Containers/$bundle_identifier" "container-$bundle_identifier"
    move_to_reset_folder "$HOME/Library/Application Scripts/$bundle_identifier" "application-scripts-$bundle_identifier"
    move_to_reset_folder "$HOME/Library/Application Support/$bundle_identifier" "application-support-$bundle_identifier"
    move_to_reset_folder "$HOME/Library/Caches/$bundle_identifier" "cache-$bundle_identifier"
    move_to_reset_folder "$HOME/Library/Preferences/$bundle_identifier.plist" "preferences-$bundle_identifier.plist"
    move_to_reset_folder "$HOME/Library/Saved Application State/$bundle_identifier.savedState" "saved-state-$bundle_identifier.savedState"
    move_to_reset_folder "$HOME/Library/WebKit/$bundle_identifier" "webkit-$bundle_identifier"
    move_to_reset_folder "$HOME/Library/HTTPStorages/$bundle_identifier" "http-storage-$bundle_identifier"
done

echo
if $cleanup_incomplete; then
    echo "PasteList reset finished with unresolved items." >&2
else
    echo "PasteList reset complete."
fi
if [[ -d "$trash_root" ]] || $dry_run; then
    echo "Recovery folder: $trash_root"
    echo "Delete only that folder from the Trash when it is no longer needed."
fi
if [[ "$mode" == "full" ]]; then
    echo "Reinstall PasteList to start again."
else
    echo "Open PasteList when you are ready to start again."
fi
echo "The next launch will show onboarding and request Assistive Paste access only if you choose it."
echo "Note: the current app build seeds a 'Welcome to PasteList' history item on first launch."

if $cleanup_incomplete; then
    echo >&2
    echo "Unresolved items:" >&2
    printf '  - %s\n' "${cleanup_failures[@]}" >&2
    exit 1
fi
