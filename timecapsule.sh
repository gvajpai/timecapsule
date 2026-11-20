#!/usr/bin/env bash
# ==============================================================================
# Script Name : timecapsule.sh
# Version     : 1.2.1
# Description : Interactive TUI (whiptail) incremental backup and recovery tool
#               for GNU/Linux using rsync hard links (--link-dest) with tiered
#               retention cleanup (daily, weekly, monthly) and single-file or
#               full-snapshot restoration.
# Dependencies: bash (>= 4.0), rsync, whiptail (package: 'newt' on Void/RHEL,
#               'whiptail' on Debian/Ubuntu), coreutils (date, readlink,
#               realpath, stat), util-linux (findmnt, flock), findutils (find).
# Config File : ~/.config/timecapsule.conf (auto-generated on first run)
# ==============================================================================

set -euo pipefail

# ==============================================================================
# Version & CLI Flags
# ==============================================================================
readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_VERSION="1.2.1"

case "${1:-}" in
    -v|--version)
        echo "${SCRIPT_NAME} v${SCRIPT_VERSION}"
        exit 0
        ;;
    -h|--help)
        cat <<EOF
${SCRIPT_NAME} v${SCRIPT_VERSION} - Interactive Incremental Backup & Recovery Tool

Usage:
  ./${SCRIPT_NAME}           Launch the interactive TUI menu
  ./${SCRIPT_NAME} -v        Display script version
  ./${SCRIPT_NAME} -h        Display this help message

Configuration:
  Settings are stored in ~/.config/timecapsule.conf and can be edited through
  the TUI Configuration menu or directly in a text editor.
EOF
        exit 0
        ;;
esac

# ==============================================================================
# Global Constants & Default Configuration
# ==============================================================================
readonly CONFIG_FILE="${HOME}/.config/timecapsule.conf"
readonly LEGACY_CONFIG_FILES=(
    "${HOME}/.config/rewind.conf"
    "${HOME}/.config/rsync-tui-backup.conf"
)
readonly GLOBAL_LOCK_FILE="${XDG_RUNTIME_DIR:-/tmp}/timecapsule-ui.lock"
readonly TITLE="Time Capsule - Incremental Backup Manager v${SCRIPT_VERSION}"

# Generic fallback defaults (used to pre-populate first-time setup)
readonly DEFAULT_SOURCE_DIR="${HOME}"
readonly DEFAULT_BACKUP_DIR="/mnt/backup/snapshots"
readonly DEFAULT_REQUIRE_MOUNT="yes"
readonly DEFAULT_KEEP_DAILY_DAYS=7
readonly DEFAULT_KEEP_WEEKLY_DAYS=56
readonly DEFAULT_KEEP_MONTHLY_DAYS=365
readonly DEFAULT_MIN_SNAPSHOTS=3

# Runtime state variables
CONFIG_STATUS=""
LATEST_LINK=""

# Default rsync exclusion patterns
readonly RSYNC_EXCLUDES=(
    '.cache/'
    '.Rproj.user/'
    'RESTORE_*/'
    '*.restored'
    '*.tmp'
    '*.temp'
    '*.bak'
    '*.swp'
    '*.swo'
    '*~'
    '.DS_Store'
    'Thumbs.db'
)

# ==============================================================================
# Pre-Flight Checks & UI Instance Lock
# ==============================================================================
for cmd in whiptail rsync findmnt flock realpath; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Error: Required command '$cmd' is not installed." >&2
        echo "  Void Linux    : sudo xbps-install -S newt rsync util-linux coreutils" >&2
        echo "  Debian/Ubuntu : sudo apt install whiptail rsync util-linux coreutils" >&2
        exit 1
    fi
done

# Per-user UI lock (released automatically by the kernel on exit/Ctrl-C/crash)
exec 9>>"$GLOBAL_LOCK_FILE"
if ! flock -n 9; then
    whiptail --title "$TITLE" --msgbox \
        "Another instance of ${SCRIPT_NAME} is already running." 8 60
    exit 1
fi

# ==============================================================================
# Configuration Persistence
# ==============================================================================
save_config() {
    mkdir -p "$(dirname "$CONFIG_FILE")"
    {
        printf '# Configuration for %s (v%s)\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"
        printf 'SOURCE_DIR=%q\n' "$SOURCE_DIR"
        printf 'BACKUP_DIR=%q\n' "$BACKUP_DIR"
        printf 'REQUIRE_MOUNT=%q\n' "$REQUIRE_MOUNT"
        printf 'KEEP_DAILY_DAYS=%q\n' "$KEEP_DAILY_DAYS"
        printf 'KEEP_WEEKLY_DAYS=%q\n' "$KEEP_WEEKLY_DAYS"
        printf 'KEEP_MONTHLY_DAYS=%q\n' "$KEEP_MONTHLY_DAYS"
        printf 'MIN_SNAPSHOTS=%q\n' "$MIN_SNAPSHOTS"
    } > "$CONFIG_FILE"

    CONFIG_STATUS="Loaded from $CONFIG_FILE"
    LATEST_LINK="${BACKUP_DIR}/latest"
}

init_config() {
    # Pre-load defaults first so no variable is ever unbound under 'set -u'
    SOURCE_DIR="$DEFAULT_SOURCE_DIR"
    BACKUP_DIR="$DEFAULT_BACKUP_DIR"
    REQUIRE_MOUNT="$DEFAULT_REQUIRE_MOUNT"
    KEEP_DAILY_DAYS=$DEFAULT_KEEP_DAILY_DAYS
    KEEP_WEEKLY_DAYS=$DEFAULT_KEEP_WEEKLY_DAYS
    KEEP_MONTHLY_DAYS=$DEFAULT_KEEP_MONTHLY_DAYS
    MIN_SNAPSHOTS=$DEFAULT_MIN_SNAPSHOTS

    # Migrate legacy config file if present
    if [ ! -f "$CONFIG_FILE" ]; then
        for legacy in "${LEGACY_CONFIG_FILES[@]}"; do
            if [ -f "$legacy" ]; then
                mkdir -p "$(dirname "$CONFIG_FILE")"
                cp "$legacy" "$CONFIG_FILE"
                break
            fi
        done
    fi

    if [ -f "$CONFIG_FILE" ]; then
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"

        # Migrate legacy MOUNT_POINT + SNAP_SUBDIR format if present
        if [ -n "${MOUNT_POINT:-}" ] && [ -n "${SNAP_SUBDIR:-}" ]; then
            BACKUP_DIR="${MOUNT_POINT%/}/${SNAP_SUBDIR#/}"
        fi

        # Validate integer retention fields against corrupted config edits
        [[ "$KEEP_DAILY_DAYS" =~ ^[0-9]+$ ]] || KEEP_DAILY_DAYS=$DEFAULT_KEEP_DAILY_DAYS
        [[ "$KEEP_WEEKLY_DAYS" =~ ^[0-9]+$ ]] || KEEP_WEEKLY_DAYS=$DEFAULT_KEEP_WEEKLY_DAYS
        [[ "$KEEP_MONTHLY_DAYS" =~ ^[0-9]+$ ]] || KEEP_MONTHLY_DAYS=$DEFAULT_KEEP_MONTHLY_DAYS
        [[ "$MIN_SNAPSHOTS" =~ ^[0-9]+$ ]] || MIN_SNAPSHOTS=$DEFAULT_MIN_SNAPSHOTS

        save_config
    else
        CONFIG_STATUS="First-time setup (will save to $CONFIG_FILE)"
        LATEST_LINK="${BACKUP_DIR}/latest"

        whiptail --title "Welcome to Time Capsule - First-Time Setup" --msgbox \
            "No configuration file was found at:\n$CONFIG_FILE\n\nPlease review and configure your backup source, destination, and retention policy to generate your configuration file." 12 72

        configure_settings "FIRST_RUN"
    fi
}

# ==============================================================================
# Filesystem, Locking, Logging & Snapshot Helper Functions
# ==============================================================================
log_event() {
    local msg="$1"
    if [ -d "$BACKUP_DIR" ] && [ -w "$BACKUP_DIR" ]; then
        printf '[%s] %s\n' "$(date '+%F %T')" "$msg" >> "$BACKUP_DIR/backup.log"
    fi
}

# Acquires a destination-level lock on FD 8.
# Usage: acquire_dest_lock [exclusive|shared]
acquire_dest_lock() {
    local mode="${1:-exclusive}"
    if ! mkdir -p "$BACKUP_DIR" 2>/dev/null; then
        whiptail --title "Permission Error" --msgbox \
            "Cannot create or access backup directory:\n$BACKUP_DIR" 9 65
        return 1
    fi

    if ! exec 8>>"$BACKUP_DIR/.timecapsule.lock"; then
        whiptail --title "Lock Permission Error" --msgbox \
            "Cannot open lock file:\n$BACKUP_DIR/.timecapsule.lock\n\nIt may be owned by another user (e.g., created with sudo)." 11 68
        return 1
    fi

    local flock_flag="-n"
    [ "$mode" == "shared" ] && flock_flag="-sn"

    if ! flock "$flock_flag" 8; then
        exec 8>&-
        whiptail --title "Destination Busy" --msgbox \
            "Another backup or cleanup process is currently modifying:\n$BACKUP_DIR" 9 68
        return 1
    fi
    return 0
}

# IMPORTANT: Never add '2>/dev/null' to bare 'exec', as that permanently
# redirects the entire script's stderr (including whiptail UI output)!
release_dest_lock() {
    exec 8>&-
}

# Checks whether the target path resides on a mounted filesystem separate from '/'
is_on_mounted_drive() {
    local check_path="$1"
    while [ ! -e "$check_path" ] && [ "$check_path" != "/" ]; do
        check_path="$(dirname "$check_path")"
    done
    local target
    target="$(findmnt -n -o TARGET --target "$check_path" 2>/dev/null)" || return 1
    [ "$target" != "/" ]
}

# Warns during configuration if destination uses a FAT filesystem lacking hard links
warn_if_fat_filesystem() {
    local check_path="$1"
    while [ ! -e "$check_path" ] && [ "$check_path" != "/" ]; do
        check_path="$(dirname "$check_path")"
    done
    local fs_type
    fs_type="$(stat -f -c %T "$check_path" 2>/dev/null || echo "unknown")"
    case "$fs_type" in
        msdos|vfat|exfat)
            whiptail --title "Filesystem Warning ($fs_type)" --msgbox \
                "NOTE: '$check_path' uses '$fs_type', which does not support POSIX hard links.\n\nBackups will still work, but every snapshot will store a full copy instead of incremental deduplication. Linux filesystems (ext4, btrfs, xfs) are recommended." 12 70
            ;;
    esac
}

# Validates safety constraints before running backup, restore, or delete tasks
validate_backup_destination() {
    local real_src real_dst
    real_src="$(realpath -m "$SOURCE_DIR")"
    real_dst="$(realpath -m "$BACKUP_DIR")"

    # Prevent backing up a directory into itself (including when source is '/')
    if [ "$real_src" == "/" ] || [ "$real_dst" == "$real_src" ] || [[ "$real_dst" == "$real_src/"* ]]; then
        whiptail --title "Invalid Configuration" --msgbox \
            "Backup Destination cannot be inside or identical to Backup Source Target:\n\nSource: $real_src\nDest:   $real_dst" 11 70
        return 1
    fi

    if [ "$REQUIRE_MOUNT" == "yes" ]; then
        if ! is_on_mounted_drive "$BACKUP_DIR"; then
            whiptail --title "External Drive Not Mounted" --msgbox \
                "Backup Destination is not on a separately mounted drive:\n$BACKUP_DIR\n\nEither mount the drive first, or set 'Require Mounted Drive' to 'no' in Configuration if backing up to a local folder." 12 70
            return 1
        fi
    fi

    return 0
}

# Interactive directory tree browser built with whiptail --menu.
browse_directory() {
    local start_dir="$1"
    local prompt_title="$2"
    local current_dir="$start_dir"

    while [ ! -d "$current_dir" ] && [ "$current_dir" != "/" ]; do
        current_dir="$(dirname "$current_dir")"
    done
    [ -d "$current_dir" ] || current_dir="/"

    while true; do
        local menu_items=()
        menu_items+=("." "[ SELECT THIS DIRECTORY ]")
        if [ "$current_dir" != "/" ]; then
            menu_items+=(".." "[ Up to parent directory ]")
        fi
        menu_items+=("MANUAL" "[ Type or create a custom path ]")

        while IFS= read -r subdir; do
            [ -n "$subdir" ] && menu_items+=("$subdir/" "Folder")
        done < <(find "$current_dir" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' 2>/dev/null | sort)

        local choice
        choice=$(whiptail --title "$prompt_title" \
            --menu "Current Path:\n$current_dir\n\nNavigate folders or select current directory:" 22 74 12 \
            "${menu_items[@]}" 3>&1 1>&2 2>&3) || return 1

        case "$choice" in
            ".")
                echo "$current_dir"
                return 0
                ;;
            "..")
                current_dir="$(dirname "$current_dir")"
                ;;
            "MANUAL")
                local typed
                typed=$(whiptail --inputbox "Enter full directory path:" 10 68 "$current_dir" 3>&1 1>&2 2>&3) || continue
                if [ -n "$typed" ]; then
                    echo "${typed%/}"
                    return 0
                fi
                ;;
            *)
                local next_dir="${current_dir%/}/${choice%/}"
                if [ -r "$next_dir" ] && [ -x "$next_dir" ]; then
                    current_dir="$next_dir"
                else
                    whiptail --title "Permission Denied" --msgbox "Cannot open directory:\n$next_dir" 8 55
                fi
                ;;
        esac
    done
}

# Interactive browser to pick a specific file or subfolder inside a snapshot.
# Outputs the relative path inside the snapshot to stdout.
browse_snapshot_item() {
    local snap_root="$1"
    local rel_path=""

    while true; do
        local current_dir="${snap_root}${rel_path:+/$rel_path}"
        local display_path="/${rel_path}"
        local menu_items=()

        if [ -n "$rel_path" ]; then
            menu_items+=("." "[ RESTORE THIS ENTIRE FOLDER ]")
            menu_items+=(".." "[ Up to parent directory ]")
        fi

        while IFS= read -r dname; do
            [ -n "$dname" ] && menu_items+=("$dname/" "Folder (open or restore)")
        done < <(find "$current_dir" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' 2>/dev/null | sort)

        while IFS= read -r fname; do
            [ -n "$fname" ] && menu_items+=("$fname" "File (select to restore)")
        done < <(find "$current_dir" -maxdepth 1 -mindepth 1 ! -type d -printf '%f\n' 2>/dev/null | sort)

        if [ -z "$rel_path" ] && [ "${#menu_items[@]}" -eq 0 ]; then
            whiptail --title "Empty Snapshot" --msgbox "This snapshot directory is empty." 8 55
            return 1
        fi

        local choice
        choice=$(whiptail --title "Select File or Folder to Restore" \
            --menu "Snapshot Path: $display_path\n\nChoose a file to restore, or open a folder:" 22 76 12 \
            "${menu_items[@]}" 3>&1 1>&2 2>&3) || return 1

        case "$choice" in
            ".")
                echo "$rel_path"
                return 0
                ;;
            "..")
                rel_path="$(dirname "$rel_path")"
                [ "$rel_path" == "." ] && rel_path=""
                ;;
            */)
                local clean_dir="${choice%/}"
                local next_rel="${rel_path:+$rel_path/}$clean_dir"
                local folder_action
                folder_action=$(whiptail --title "Folder Selected: $clean_dir/" \
                    --menu "What would you like to do with '$clean_dir/'?" 13 66 2 \
                    "OPEN" "Browse inside this folder" \
                    "RESTORE" "Restore this entire folder" \
                    3>&1 1>&2 2>&3) || continue
                if [ "$folder_action" == "OPEN" ]; then
                    rel_path="$next_rel"
                else
                    echo "$next_rel"
                    return 0
                fi
                ;;
            *)
                echo "${rel_path:+$rel_path/}$choice"
                return 0
                ;;
        esac
    done
}

# Lists ONLY valid snapshot directories matching YYYY-MM-DD_HH-MM-SS (newest first)
get_snapshots() {
    [ -d "$BACKUP_DIR" ] || return 0
    find "$BACKUP_DIR" -maxdepth 1 -mindepth 1 -type d \
        -regextype posix-extended \
        -regex '.*/[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}' \
        -printf '%f\n' | sort -r
}

# Retrieves the recorded source directory for a given snapshot.
# Returns 0 if recorded in .meta, or 1 if falling back to current SOURCE_DIR.
get_snapshot_source() {
    local snap="$1"
    local meta_file="$BACKUP_DIR/.meta/$snap"
    if [ -f "$meta_file" ]; then
        local recorded
        recorded="$(head -n 1 "$meta_file")"
        if [ -n "$recorded" ]; then
            echo "${recorded%/}"
            return 0
        fi
    fi
    echo "$SOURCE_DIR"
    return 1
}

# Updates 'latest' using a portable relative symlink to the newest valid snapshot
repair_latest_link() {
    [ -d "$BACKUP_DIR" ] || return 0
    local newest
    newest="$(get_snapshots | head -n 1)"
    if [ -n "$newest" ]; then
        ln -sfn "$newest" "$LATEST_LINK"
    else
        rm -f "$LATEST_LINK"
    fi
}

# ==============================================================================
# Feature 1: Incremental Backup Execution & Tiered Retention Pruning
# ==============================================================================
run_backup() {
    validate_backup_destination || return 0

    if [ ! -d "$SOURCE_DIR" ]; then
        whiptail --title "Error" --msgbox "Source directory does not exist:\n$SOURCE_DIR" 9 60
        return 0
    fi

    mapfile -t existing_snaps < <(get_snapshots)
    local snap_count="${#existing_snaps[@]}"
    local latest_snap_name="None (First full backup)"
    if [ "$snap_count" -gt 0 ]; then
        latest_snap_name="${existing_snaps[0]}"
    fi

    local overview_text
    overview_text=$(cat <<EOF
Config Source : $CONFIG_STATUS
Backup Source : $SOURCE_DIR
Backup Dest   : $BACKUP_DIR
Mount Check   : $REQUIRE_MOUNT

Retention     : Daily <= ${KEEP_DAILY_DAYS}d | Weekly <= ${KEEP_WEEKLY_DAYS}d | Monthly <= ${KEEP_MONTHLY_DAYS}d
Safety Floor  : Always keep at least $MIN_SNAPSHOTS newest snapshot(s)
Existing Snaps: $snap_count snapshot(s) found
Latest Snap   : $latest_snap_name

Start incremental backup now?
EOF
)

    whiptail --title "Backup Configuration Overview" --yesno "$overview_text" 20 78 || return 0

    acquire_dest_lock "exclusive" || return 0

    # Clean up any abandoned .inprogress_* directories from interrupted runs
    find "$BACKUP_DIR" -maxdepth 1 -mindepth 1 -type d -name '.inprogress_*' -exec rm -rf -- {} +

    repair_latest_link

    local stamp
    stamp="$(date +%F_%H-%M-%S)"
    local tmp_snapshot="$BACKUP_DIR/.inprogress_$stamp"
    local final_snapshot="$BACKUP_DIR/$stamp"

    local rsync_opts=(-aH --numeric-ids --info=progress2 --stats)
    for pattern in "${RSYNC_EXCLUDES[@]}"; do
        rsync_opts+=(--exclude="$pattern")
    done

    # Hard-link unchanged files against the previous snapshot if one exists
    if [ -L "$LATEST_LINK" ] && [ -d "$(readlink -f "$LATEST_LINK")" ]; then
        local prev_snapshot
        prev_snapshot="$(readlink -f "$LATEST_LINK")"
        rsync_opts+=(--link-dest="$prev_snapshot")
    fi

    clear
    echo "============================================================"
    echo " Starting Incremental Backup: $stamp"
    echo " Source:      $SOURCE_DIR"
    echo " Destination: $final_snapshot"
    echo "============================================================"

    mkdir -p "$tmp_snapshot"
    local rc=0
    rsync "${rsync_opts[@]}" "$SOURCE_DIR/" "$tmp_snapshot/" || rc=$?

    if [ "$rc" -eq 0 ] || [ "$rc" -eq 24 ] || [ "$rc" -eq 23 ]; then
        # Write source metadata before moving snapshot into place so no snapshot
        # can ever exist without its source record if interrupted.
        mkdir -p "$BACKUP_DIR/.meta"
        printf '%s\n' "$SOURCE_DIR" > "$BACKUP_DIR/.meta/$stamp"

        mv "$tmp_snapshot" "$final_snapshot"
        ln -sfn "$stamp" "$LATEST_LINK"

        if [ "$rc" -eq 23 ]; then
            echo -e "\n[WARN] Snapshot created with warnings (some files could not be read, rsync code 23)."
            log_event "BACKUP SUCCESS (WITH WARNINGS rc=23): $stamp from $SOURCE_DIR"
        else
            echo -e "\n[INFO] Snapshot created successfully: $stamp"
            log_event "BACKUP SUCCESS (rc=$rc): $stamp from $SOURCE_DIR"
        fi

        run_retention_cleanup
        release_dest_lock
        echo -e "\nPress ENTER to return to menu..."
        read -r
    else
        rm -rf -- "$tmp_snapshot"
        echo -e "\n[ERROR] rsync failed with exit code $rc. Incomplete snapshot removed."
        log_event "BACKUP FAILED (rc=$rc): $stamp from $SOURCE_DIR"
        release_dest_lock
        echo "Press ENTER to return to menu..."
        read -r
    fi
}

# Evaluates all valid snapshots newest-to-oldest, always preserving at least
# MIN_SNAPSHOTS newest backups, then applying daily, weekly, and monthly tiers.
run_retention_cleanup() {
    echo "[INFO] Running retention policy cleanup..."
    mapfile -t snapshots < <(get_snapshots)
    [ "${#snapshots[@]}" -eq 0 ] && return 0

    local now_epoch
    now_epoch="$(date +%s)"
    declare -A keep_map=()
    declare -A seen_week=()
    declare -A seen_month=()

    local index=0
    for snap in "${snapshots[@]}"; do
        index=$((index + 1))

        if [ "$index" -le "$MIN_SNAPSHOTS" ]; then
            keep_map["$snap"]=1
            continue
        fi

        local date_part="${snap%%_*}"
        local snap_epoch
        snap_epoch="$(date -d "$date_part" +%s 2>/dev/null || true)"
        [ -z "${snap_epoch:-}" ] && continue

        local age_days=$(( (now_epoch - snap_epoch) / 86400 ))

        if [ "$age_days" -le "$KEEP_DAILY_DAYS" ]; then
            keep_map["$snap"]=1
        elif [ "$age_days" -le "$KEEP_WEEKLY_DAYS" ]; then
            local week_key
            week_key="$(date -d "@$snap_epoch" +%G-W%V)"
            if [ -z "${seen_week[$week_key]:-}" ]; then
                seen_week["$week_key"]=1
                keep_map["$snap"]=1
            fi
        elif [ "$age_days" -le "$KEEP_MONTHLY_DAYS" ]; then
            local month_key
            month_key="$(date -d "@$snap_epoch" +%Y-%m)"
            if [ -z "${seen_month[$month_key]:-}" ]; then
                seen_month["$month_key"]=1
                keep_map["$snap"]=1
            fi
        fi
    done

    for snap in "${snapshots[@]}"; do
        if [ -z "${keep_map[$snap]:-}" ]; then
            echo "[INFO] Pruning expired snapshot: $snap"
            rm -rf -- "${BACKUP_DIR:?}/$snap"
            rm -f -- "${BACKUP_DIR:?}/.meta/$snap"
            log_event "PRUNED SNAPSHOT: $snap"
        fi
    done

    repair_latest_link
    echo "[INFO] Retention cleanup complete."
}

# ==============================================================================
# Feature 2: Snapshot Recovery / Restore (Full Snapshot OR Single File/Folder)
# ==============================================================================
recover_backup() {
    validate_backup_destination || return 0
    acquire_dest_lock "shared" || return 0

    mapfile -t snapshots < <(get_snapshots)
    if [ "${#snapshots[@]}" -eq 0 ]; then
        release_dest_lock
        whiptail --title "No Backups Found" --msgbox "No snapshots were found in:\n$BACKUP_DIR" 9 60
        return 0
    fi

    local menu_items=()
    for snap in "${snapshots[@]}"; do
        local orig_src label
        if orig_src="$(get_snapshot_source "$snap")"; then
            label="From: $orig_src"
        else
            label="From: ? (assuming $orig_src)"
        fi
        if [ -L "$LATEST_LINK" ] && [ "$(basename "$(readlink -f "$LATEST_LINK")")" == "$snap" ]; then
            label="[LATEST] $label"
        fi
        menu_items+=("$snap" "$label")
    done

    local selected_snap
    if ! selected_snap=$(whiptail --title "Recover Backup" \
        --menu "Select a snapshot date to restore from:" 20 78 10 \
        "${menu_items[@]}" 3>&1 1>&2 2>&3); then
        release_dest_lock
        return 0
    fi

    local snap_path="$BACKUP_DIR/$selected_snap"
    local recorded_source source_display
    if recorded_source="$(get_snapshot_source "$selected_snap")"; then
        source_display="$recorded_source"
    else
        source_display="? (unrecorded; assuming $recorded_source)"
    fi

    local scope_choice
    if ! scope_choice=$(whiptail --title "Restore Scope ($selected_snap)" \
        --menu "Snapshot source: $source_display\n\nWhat would you like to restore?" 15 76 2 \
        "ITEM" "Restore a SINGLE FILE or SUBFOLDER (browse snapshot)" \
        "FULL" "Restore the ENTIRE snapshot" \
        3>&1 1>&2 2>&3); then
        release_dest_lock
        return 0
    fi

    # --------------------------------------------------------------------------
    # Mode A: Single File or Subfolder Restore
    # --------------------------------------------------------------------------
    if [ "$scope_choice" == "ITEM" ]; then
        local rel_item
        if ! rel_item=$(browse_snapshot_item "$snap_path"); then
            release_dest_lock
            return 0
        fi
        local src_item="$snap_path/$rel_item"

        local item_dest_mode
        if ! item_dest_mode=$(whiptail --title "Destination for: $rel_item" \
            --menu "Where should '$rel_item' be restored?" 16 78 3 \
            "SAFE_COPY" "Restore next to original as '${rel_item}.restored'" \
            "ORIGINAL" "Restore directly to original path (${recorded_source}/${rel_item})" \
            "BROWSE" "Choose a custom destination folder" \
            3>&1 1>&2 2>&3); then
            release_dest_lock
            return 0
        fi

        local dest_target
        if [ "$item_dest_mode" == "SAFE_COPY" ]; then
            dest_target="${recorded_source}/${rel_item}.restored"
            if [ -e "$dest_target" ]; then
                if ! whiptail --title "Confirm Overwrite" --yesno \
                    "A previous restored copy already exists:\n$dest_target\n\nOverwrite it?" 11 68; then
                    release_dest_lock
                    return 0
                fi
            fi
            mkdir -p "$(dirname "$dest_target")"
        elif [ "$item_dest_mode" == "ORIGINAL" ]; then
            dest_target="${recorded_source}/${rel_item}"
            if [ -e "$dest_target" ]; then
                if ! whiptail --title "Confirm Overwrite" --yesno \
                    "Target already exists:\n$dest_target\n\nExisting files will be overwritten with versions from $selected_snap (newer files inside folders will be kept).\n\nProceed?" 13 70; then
                    release_dest_lock
                    return 0
                fi
            fi
            mkdir -p "$(dirname "$dest_target")"
        else
            local custom_dir
            if ! custom_dir=$(browse_directory "$recorded_source" "Select Destination Folder"); then
                release_dest_lock
                return 0
            fi
            dest_target="${custom_dir%/}/$(basename "$rel_item")"
            if [ -e "$dest_target" ]; then
                if ! whiptail --title "Confirm Overwrite" --yesno \
                    "Target already exists:\n$dest_target\n\nOverwrite it?" 11 68; then
                    release_dest_lock
                    return 0
                fi
            fi
            mkdir -p "$(dirname "$dest_target")"
        fi

        clear
        echo "============================================================"
        echo " Restoring Item:     $rel_item"
        echo " From Snapshot:      $selected_snap"
        echo " Destination:        $dest_target"
        echo "============================================================"

        local item_rc=0
        if [ -d "$src_item" ]; then
            mkdir -p "$dest_target"
            rsync -aH --info=progress2 "$src_item/" "$dest_target/" || item_rc=$?
        else
            rsync -aH --info=progress2 "$src_item" "$dest_target" || item_rc=$?
        fi

        if [ "$item_rc" -eq 0 ]; then
            echo -e "\n[INFO] Item restored successfully to: $dest_target"
            log_event "RESTORE ITEM SUCCESS: '$rel_item' from $selected_snap -> $dest_target"
        else
            echo -e "\n[ERROR] Restore failed (rsync exit code $item_rc)."
            log_event "RESTORE ITEM FAILED (rc=$item_rc): '$rel_item' from $selected_snap"
        fi
        release_dest_lock
        echo "Press ENTER to return to menu..."
        read -r
        return 0
    fi

    # --------------------------------------------------------------------------
    # Mode B: Full Snapshot Restore
    # --------------------------------------------------------------------------
    local restore_mode
    if ! restore_mode=$(whiptail --title "Full Restore Destination" \
        --menu "How would you like to restore '$selected_snap'?" 16 76 3 \
        "SAFE" "Restore to ${recorded_source}/RESTORE_${selected_snap}" \
        "BROWSE" "Choose a different restore folder from directory tree" \
        "OVERWRITE" "Restore directly into ${recorded_source} (merges/overwrites)" \
        3>&1 1>&2 2>&3); then
        release_dest_lock
        return 0
    fi

    local target_dir
    if [ "$restore_mode" == "SAFE" ]; then
        target_dir="${recorded_source}/RESTORE_${selected_snap}"
    elif [ "$restore_mode" == "BROWSE" ]; then
        if ! target_dir=$(browse_directory "$recorded_source" "Select Restore Destination Folder"); then
            release_dest_lock
            return 0
        fi
    else
        if ! whiptail --title "Confirm Overwrite" --yesno \
            "WARNING: This will overwrite modified files in:\n$recorded_source\nwith versions from $selected_snap.\n\n(Newer files not in the backup will NOT be deleted.)\n\nProceed?" 13 68; then
            release_dest_lock
            return 0
        fi
        target_dir="$recorded_source"
    fi

    mkdir -p "$target_dir"
    clear
    echo "============================================================"
    echo " Restoring Full Snapshot: $selected_snap"
    echo " Target Directory:        $target_dir"
    echo "============================================================"

    if rsync -aH --info=progress2 "$snap_path/" "$target_dir/"; then
        echo -e "\n[INFO] Restore completed successfully to: $target_dir"
        log_event "RESTORE FULL SUCCESS: $selected_snap -> $target_dir"
    else
        echo -e "\n[ERROR] Restore encountered errors."
        log_event "RESTORE FULL FAILED: $selected_snap -> $target_dir"
    fi
    release_dest_lock
    echo "Press ENTER to return to menu..."
    read -r
}

# ==============================================================================
# Feature 3: Manual Snapshot Deletion
# ==============================================================================
delete_backup() {
    validate_backup_destination || return 0

    mapfile -t snapshots < <(get_snapshots)
    if [ "${#snapshots[@]}" -eq 0 ]; then
        whiptail --title "No Backups Found" --msgbox "No snapshots were found in:\n$BACKUP_DIR" 9 60
        return 0
    fi

    local menu_items=()
    for snap in "${snapshots[@]}"; do
        menu_items+=("$snap" "Delete this snapshot")
    done

    local selected_snap
    selected_snap=$(whiptail --title "Delete Snapshot" \
        --menu "Select a snapshot to permanently delete:" 20 65 10 \
        "${menu_items[@]}" 3>&1 1>&2 2>&3) || return 0

    whiptail --title "Confirm Deletion" --yesno \
        "Are you sure you want to permanently delete snapshot:\n\n  $selected_snap\n\n(Hard-linked files shared with other snapshots will remain intact.)" 12 65 || return 0

    acquire_dest_lock "exclusive" || return 0

    clear
    echo "[INFO] Deleting snapshot $selected_snap..."
    rm -rf -- "${BACKUP_DIR:?}/$selected_snap"
    rm -f -- "${BACKUP_DIR:?}/.meta/$selected_snap"
    repair_latest_link
    log_event "MANUAL DELETE: $selected_snap"

    release_dest_lock
    whiptail --title "Deleted" --msgbox "Snapshot '$selected_snap' has been deleted." 8 55
}

# ==============================================================================
# Feature 4: Interactive Configuration Menu
# ==============================================================================
configure_settings() {
    local done_label="Back to Main Menu"
    [ "${1:-}" == "FIRST_RUN" ] && done_label="Save & Continue to Main Menu"

    while true; do
        local choice
        choice=$(whiptail --title "Configuration Settings" \
            --menu "Status: $CONFIG_STATUS" 20 78 8 \
            "1" "Backup Source Target    [$SOURCE_DIR]" \
            "2" "Backup Destination Dir  [$BACKUP_DIR]" \
            "3" "Require Mounted Drive   [$REQUIRE_MOUNT]" \
            "4" "Keep Daily Backups      [$KEEP_DAILY_DAYS days]" \
            "5" "Keep Weekly Backups     [$KEEP_WEEKLY_DAYS days]" \
            "6" "Keep Monthly Backups    [$KEEP_MONTHLY_DAYS days]" \
            "7" "Minimum Snapshots Floor [$MIN_SNAPSHOTS snapshots]" \
            "8" "$done_label" \
            3>&1 1>&2 2>&3) || break

        case "$choice" in
            1)
                local picked
                picked=$(browse_directory "$SOURCE_DIR" "Select Backup Source Target") || continue
                [ -n "$picked" ] && SOURCE_DIR="${picked%/}"
                ;;
            2)
                local picked
                picked=$(browse_directory "$BACKUP_DIR" "Select Backup Destination Directory") || continue
                if [ -n "$picked" ]; then
                    BACKUP_DIR="${picked%/}"
                    warn_if_fat_filesystem "$BACKUP_DIR"
                    if is_on_mounted_drive "$BACKUP_DIR"; then
                        REQUIRE_MOUNT="yes"
                    else
                        if whiptail --title "Local Directory Detected" --yesno \
                            "'$BACKUP_DIR' is not on a separate mounted drive.\n\nSet 'Require Mounted Drive' to 'no' so local backups are allowed?" 10 68; then
                            REQUIRE_MOUNT="no"
                        fi
                    fi
                fi
                ;;
            3)
                if [ "$REQUIRE_MOUNT" == "yes" ]; then
                    REQUIRE_MOUNT="no"
                else
                    REQUIRE_MOUNT="yes"
                fi
                ;;
            4)
                local val
                val=$(whiptail --inputbox "Keep all daily snapshots younger than X days:" 9 65 "$KEEP_DAILY_DAYS" 3>&1 1>&2 2>&3) || continue
                if [[ "$val" =~ ^[0-9]+$ ]]; then
                    KEEP_DAILY_DAYS="$val"
                    if [ "$KEEP_DAILY_DAYS" -gt "$KEEP_WEEKLY_DAYS" ]; then
                        whiptail --title "Retention Notice" --msgbox \
                            "Note: Daily window (${KEEP_DAILY_DAYS}d) is longer than Weekly window (${KEEP_WEEKLY_DAYS}d), so the weekly tier will be skipped." 9 68
                    fi
                fi
                ;;
            5)
                local val
                val=$(whiptail --inputbox "Keep 1 weekly snapshot per week up to X days old:" 9 65 "$KEEP_WEEKLY_DAYS" 3>&1 1>&2 2>&3) || continue
                if [[ "$val" =~ ^[0-9]+$ ]]; then
                    KEEP_WEEKLY_DAYS="$val"
                    if [ "$KEEP_WEEKLY_DAYS" -lt "$KEEP_DAILY_DAYS" ]; then
                        whiptail --title "Retention Notice" --msgbox \
                            "Note: Weekly window (${KEEP_WEEKLY_DAYS}d) is shorter than Daily window (${KEEP_DAILY_DAYS}d), so the weekly tier will be skipped." 9 68
                    fi
                fi
                ;;
            6)
                local val
                val=$(whiptail --inputbox "Keep 1 monthly snapshot per month up to X days old:" 9 65 "$KEEP_MONTHLY_DAYS" 3>&1 1>&2 2>&3) || continue
                if [[ "$val" =~ ^[0-9]+$ ]]; then
                    KEEP_MONTHLY_DAYS="$val"
                    if [ "$KEEP_MONTHLY_DAYS" -lt "$KEEP_WEEKLY_DAYS" ]; then
                        whiptail --title "Retention Notice" --msgbox \
                            "Note: Monthly window (${KEEP_MONTHLY_DAYS}d) is shorter than Weekly window (${KEEP_WEEKLY_DAYS}d), so the monthly tier will be skipped." 9 68
                    fi
                fi
                ;;
            7)
                local val
                val=$(whiptail --inputbox "Minimum number of newest snapshots to ALWAYS keep (even if older than retention windows):" 10 70 "$MIN_SNAPSHOTS" 3>&1 1>&2 2>&3) || continue
                [[ "$val" =~ ^[0-9]+$ ]] && MIN_SNAPSHOTS="$val"
                ;;
            8)
                break
                ;;
        esac
        save_config
    done

    save_config
}

# ==============================================================================
# Main Entry Point & Event Loop
# ==============================================================================
init_config

while true; do
    MAIN_CHOICE=$(whiptail --title "$TITLE" \
        --menu "Source: $SOURCE_DIR\nDest:   $BACKUP_DIR\n\nChoose an operation:" 18 76 5 \
        "1" "Run Incremental Backup Now" \
        "2" "Recover / Restore (Full Snapshot or Single File)" \
        "3" "Delete an Old Backup Snapshot" \
        "4" "Configure Backup Targets & Retention Policy" \
        "5" "Exit" \
        3>&1 1>&2 2>&3) || exit 0

    case "$MAIN_CHOICE" in
        1) run_backup ;;
        2) recover_backup ;;
        3) delete_backup ;;
        4) configure_settings ;;
        5) exit 0 ;;
    esac
done