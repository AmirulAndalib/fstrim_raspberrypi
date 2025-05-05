#!/bin/bash

# Script to Setup and Configure TRIM (Discard) Support for External USB SSDs
# Usage: sudo ./setup-trim-final.sh [options]
# Author: AmirulAndalib / Refined by AI Assistant
# Version: 3.3 (Production Release - Simplified Persistence)
# Last Updated: 2025-05-06 # Adjusted Date

# --- Configuration ---
DEFAULT_TIMER_SCHEDULE="weekly"
UDEV_RULE_DIR="/etc/udev/rules.d"
SYSTEMD_OVERRIDE_DIR="/etc/systemd/system"

# --- Script Exit Codes ---
E_SUCCESS=0
E_ROOT=1
E_ARGS=2
E_PKG_MISSING=3
E_PKG_INSTALL=4
E_DEVICE_NOT_FOUND=5
E_DEVICE_INVALID=6
E_TRIM_UNSUPPORTED_ABORT=7
E_UDEV_RULE=8
E_SYSTEMD=9
E_LOG_FILE=10
E_INTERNAL=99

# --- State Variables ---
DEVICE=""
DEVICE_NAME="" # Just the name part (e.g., sda)
TIMER_SCHEDULE="$DEFAULT_TIMER_SCHEDULE"
AUTO_INSTALL=0
SELECTED_USB="unknown" # Holds vendor:product ID or "unknown"
VENDOR_ID=""
PRODUCT_ID=""
VERBOSE=0
LOG_FILE=""
ENABLE_TIMER=0
DEVICE_TRIM_SUPPORTED=0 # 0=No/Unknown, 1=Yes
DEVICE_MAX_UNMAP_LBA_COUNT=0
DEVICE_DISCARD_MAX_BYTES=0
FSTRIM_TEST_SUCCESS=0 # Track if fstrim test succeeded
FOUND_MOUNTPOINT="" # Store mountpoint where TRIM was tested
UDEV_RULE_CREATED=0 # Track if udev rule was created successfully
# Removed INIT_SCRIPT_CREATED and RCLOCAL_UPDATED flags

# --- ANSI Color Codes ---
RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
BLUE="\e[34m"
GRAY="\e[90m"
BOLD="\e[1m"
RESET="\e[0m"

# --- Logging Function ---
log() {
    local level=$1
    shift
    local message="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local log_prefix="[$timestamp] [$level]"

    # Log to file if specified
    if [ -n "$LOG_FILE" ]; then
        # Ensure file logging happens regardless of verbosity for selected levels
        if [[ "$level" != "TRACE" || "$VERBOSE" -gt 1 ]]; then # Log TRACE only if super verbose
             echo "$log_prefix $message" >> "$LOG_FILE"
        fi
    fi

    # Log to console based on verbosity and level
    local console_output=0
    case "$level" in
        ERROR|SUCCESS|WARNING|INFO) console_output=1 ;;
        DEBUG) [ "$VERBOSE" -ge 1 ] && console_output=1 ;;
        TRACE) [ "$VERBOSE" -ge 2 ] && console_output=1 ;; # TRACE needs -vv
    esac

    if [ "$console_output" -eq 1 ]; then
        local color=$RESET
        case $level in
            ERROR)   color=$RED ;;
            WARNING) color=$YELLOW ;;
            SUCCESS) color=$GREEN ;;
            INFO)    color=$BLUE ;;
            DEBUG)   color=$GRAY ;;
            TRACE)   color=$GRAY ;;
        esac
        # Use stderr for errors
        if [ "$level" = "ERROR" ]; then
            echo -e "${color}${log_prefix} $message${RESET}" >&2
        else
            echo -e "${color}${log_prefix} $message${RESET}"
        fi
    fi
}

# --- Help Function ---
show_help() {
    echo -e "${BOLD}External SSD TRIM Configuration Tool (v3.3)${RESET}" # Version updated
    echo
    echo "Usage: sudo $0 [options]"
    echo
    echo "Configures TRIM (discard/unmap) for external USB SSDs by checking firmware support,"
    echo "creating persistent udev rules, and optionally enabling the systemd fstrim timer."
    echo -e "${YELLOW}Persistence is now handled primarily via udev rules.${RESET}" # Note change
    echo
    echo "Required Packages: sg3-utils (or sg3_utils), lsscsi, usbutils, hdparm, util-linux (for fstrim/lsblk)"
    echo
    echo "Options:"
    echo "  -d, --device DEV    Specify target block device (e.g., /dev/sda). Mandatory if not using -u."
    echo "  -t, --timer SCHED   Set fstrim timer schedule (default: $DEFAULT_TIMER_SCHEDULE)."
    echo "                      Options: daily, weekly, monthly"
    echo "  -a, --auto          Attempt automatic installation of missing required packages."
    echo "  -e, --enable-timer  Enable and start the systemd fstrim.timer service for periodic TRIM."
    echo "  -u, --select-usb    Interactively select the target USB SSD from a list."
    echo "  -v, --verbose       Enable verbose logging (-vv for TRACE)."
    echo "  -l, --log FILE      Write logs to the specified file (absolute path recommended)."
    echo "  -h, --help          Show this help message and exit."
    echo
    echo "Example (Interactive): sudo $0 --select-usb --auto --enable-timer -vv --log /var/log/trim_setup.log" # Added -vv example
    echo "Example (Specific):    sudo $0 -d /dev/sdb -t daily -a -e -v"
    echo
    echo -e "${YELLOW}NOTE:${RESET} Run with ${BOLD}sudo${RESET}. A ${BOLD}reboot${RESET} is strongly recommended after configuration."
    echo -e "${RED}WARNING:${RESET} Modifying system settings can have unintended consequences. Use with caution."
}

# --- Utility Functions ---

check_root() {
    if [ "$EUID" -ne 0 ]; then
        log "ERROR" "This script must be run as root or with sudo."
        exit $E_ROOT
    fi
    log "DEBUG" "Root check passed."
}

# Checks for required commands and optionally installs packages
install_packages() {
    local required_cmds=("sg_vpd" "sg_readcap" "lsscsi" "lsusb" "hdparm" "lsblk" "fstrim" "udevadm" "systemctl")
    local missing_cmds=()
    
    # Declare and initialize the associative array properly
    declare -A pkg_map
    pkg_map["sg_vpd"]="sg3-utils"
    pkg_map["sg_readcap"]="sg3-utils"
    pkg_map["lsscsi"]="lsscsi"
    pkg_map["lsusb"]="usbutils" 
    pkg_map["hdparm"]="hdparm"
    pkg_map["lsblk"]="util-linux"
    pkg_map["fstrim"]="util-linux"
    pkg_map["udevadm"]="systemd" # Usually part of systemd or udev package
    pkg_map["systemctl"]="systemd"
    
    # Adjust for alternative names (e.g., dnf/yum)
    if command -v dnf &> /dev/null || command -v yum &> /dev/null; then
        pkg_map["sg_vpd"]="sg3_utils"
        pkg_map["sg_readcap"]="sg3_utils"
    fi
    # Add check for udev package manager if systemd isn't the provider
    if ! command -v udevadm &> /dev/null && command -v apt-get &> /dev/null; then
         pkg_map["udevadm"]="udev" 
    fi


    log "INFO" "Checking for required commands..."
    for cmd in "${required_cmds[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            log "WARNING" "Required command not found: $cmd (Package: ${pkg_map[$cmd]})"
            missing_cmds+=("$cmd")
        else
             log "TRACE" "Command '$cmd' found."
        fi
    done

    if [ ${#missing_cmds[@]} -eq 0 ]; then
        log "INFO" "All required commands are available."
        return 0
    fi

    log "WARNING" "Missing required commands: ${missing_cmds[*]}"

    # Identify unique packages to install
    local packages_to_install=()
    for cmd in "${missing_cmds[@]}"; do
        pkg=${pkg_map[$cmd]}
        # Avoid adding core packages like systemd/util-linux unless essential command missing
        if [[ "$pkg" == "systemd" || "$pkg" == "util-linux" || "$pkg" == "udev" ]]; then
            # Check if the command IS missing
            if ! command -v "$cmd" &> /dev/null; then
                 log "ERROR" "Core command '$cmd' from package '$pkg' is missing. This indicates a broken base system. Cannot proceed."
                 exit $E_PKG_MISSING
            fi
            # If command exists but was listed as missing earlier (logic error?), just ignore adding the package.
        fi
        # Add package if not already in the list and not a core component we already checked
        if [[ -n "$pkg" && "$pkg" != "systemd" && "$pkg" != "util-linux" && "$pkg" != "udev" && ! " ${packages_to_install[@]} " =~ " $pkg " ]]; then
            packages_to_install+=("$pkg")
        fi
    done

    if [ ${#packages_to_install[@]} -eq 0 ]; then
        # This condition should only be hit if only core component commands were missing, which causes an exit above.
        # Or if pkg_map is incomplete.
        log "ERROR" "Cannot resolve missing commands automatically. Please install manually."
        exit $E_PKG_MISSING
    fi

    log "INFO" "Required packages to install: ${packages_to_install[*]}"
    if [ "$AUTO_INSTALL" -ne 1 ]; then
        log "ERROR" "Run script with --auto option to attempt installation, or install manually."
        exit $E_PKG_MISSING
    fi

    # --- Package Installation Logic ---
    local pkg_manager=""
    local update_cmd=""
    local install_cmd=""
    log "INFO" "Attempting automatic installation (--auto specified)..."

    if command -v apt-get &> /dev/null; then
        pkg_manager="apt-get"; update_cmd="apt-get update"; install_cmd="apt-get install -y"
    elif command -v dnf &> /dev/null; then
        pkg_manager="dnf"; install_cmd="dnf install -y" # No separate update needed usually
    elif command -v yum &> /dev/null; then
        pkg_manager="yum"; install_cmd="yum install -y"
    elif command -v pacman &> /dev/null; then
        pkg_manager="pacman"; update_cmd="pacman -Sy --noconfirm"; install_cmd="pacman -S --noconfirm"
    else
        log "ERROR" "No supported package manager (apt-get, dnf, yum, pacman) found."
        exit $E_PKG_INSTALL
    fi
    log "DEBUG" "Using package manager: $pkg_manager"

    # Update package lists if needed
    if [ -n "$update_cmd" ]; then
        log "INFO" "Updating package lists..."
        # Redirect stderr to stdout for logging
        if $update_cmd > /tmp/trim_package_update.log 2>&1; then
             log "DEBUG" "Package list update successful."
        else
             log "WARNING" "Package list update failed (exit code $?). Check /tmp/trim_package_update.log. Continuing install attempt..."
             # Log the content of the file if verbose
             [ "$VERBOSE" -ge 1 ] && cat /tmp/trim_package_update.log
        fi
    fi

    # Install packages
    log "INFO" "Installing packages: ${packages_to_install[*]}"
     # Redirect stderr to stdout for logging
    if $install_cmd "${packages_to_install[@]}" > /tmp/trim_package_install.log 2>&1; then
         log "SUCCESS" "Packages installed successfully."
    else
         log "ERROR" "Failed to install packages (exit code $?). Check /tmp/trim_package_install.log."
         log "ERROR" "Please install manually: ${packages_to_install[*]}"
         # Log the content of the file if verbose
         [ "$VERBOSE" -ge 1 ] && cat /tmp/trim_package_install.log
         exit $E_PKG_INSTALL
    fi

    # Verify commands again after installation
    for cmd in "${missing_cmds[@]}"; do
        pkg=${pkg_map[$cmd]}
        # Skip verification for core packages handled earlier
        if [[ "$pkg" == "systemd" || "$pkg" == "util-linux" || "$pkg" == "udev" ]]; then continue; fi

        if ! command -v "$cmd" &> /dev/null; then
            log "ERROR" "Command '$cmd' still not found after attempting installation of package '$pkg'."
            exit $E_PKG_INSTALL
        fi
    done
    log "INFO" "Command verification after install successful."
}


# Tries various methods to get USB Vendor:Product ID for a device
get_usb_ids() {
    local dev_path=$1
    local vendor_id=""
    local product_id=""
    local ids="unknown" # Default to unknown

    log "DEBUG" "Attempting to get USB Vendor:Product IDs for $dev_path"
    if [ ! -b "$dev_path" ]; then
        log "WARNING" "Invalid device path provided to get_usb_ids: $dev_path"
        echo "$ids"; return 1
    fi

    # Method 1: udevadm info (Most reliable)
    log "TRACE" "Trying udevadm info for $dev_path"
    # Ensure we query the device itself, not a partition
    local base_dev_name="${dev_path##*/}" # e.g. sda1 -> sda1
    base_dev_name=${base_dev_name%%[0-9]*} # e.g. sda1 -> sda
    local base_dev_path="/dev/$base_dev_name" # e.g. /dev/sda

    if udev_info=$(udevadm info --query=property --name="$base_dev_name" 2>/dev/null); then # Use name only
        vendor_id=$(echo "$udev_info" | grep -E '^ID_VENDOR_ID=' | head -n1 | cut -d= -f2)
        product_id=$(echo "$udev_info" | grep -E '^ID_MODEL_ID=' | head -n1 | cut -d= -f2)
        if [[ "$vendor_id" =~ ^[0-9a-fA-F]{4}$ && "$product_id" =~ ^[0-9a-fA-F]{4}$ ]]; then
            ids="${vendor_id}:${product_id}"
            log "DEBUG" "Found USB IDs via udevadm: $ids"
            VENDOR_ID="$vendor_id"
            PRODUCT_ID="$product_id"
            echo "$ids"; return 0
        else
             log "TRACE" "udevadm did not provide valid Vendor/Product IDs. Vendor='$vendor_id', Product='$product_id'"
             log "TRACE" "Full udevadm info for $base_dev_name:\n$udev_info" # Log full output on failure
        fi
    else
         log "TRACE" "udevadm info command failed for $base_dev_name (Exit code $?)"
    fi

    # Method 2: sysfs path traversal
    local dev_name=${dev_path##*/}
    dev_name=${dev_name%%[0-9]*} # Use base device name
    local sys_dev_link="/sys/class/block/$dev_name"
    log "TRACE" "Trying sysfs traversal from $sys_dev_link"
    if [[ -L "$sys_dev_link" ]]; then
        local current_path
        current_path=$(readlink -f "$sys_dev_link")
        log "TRACE" "Sysfs real path: $current_path"
        while [[ "$current_path" != "/" && "$current_path" != "/sys" && "$current_path" != "." ]]; do
            log "TRACE" "Checking sysfs path component: $current_path"
            # Look for idVendor/idProduct files in the current directory path component
            if [[ -f "$current_path/idVendor" && -f "$current_path/idProduct" ]]; then
                vendor_id=$(cat "$current_path/idVendor" 2>/dev/null)
                product_id=$(cat "$current_path/idProduct" 2>/dev/null)
                log "TRACE" "Found potential IDs at $current_path: V='$vendor_id' P='$product_id'"
                 if [[ "$vendor_id" =~ ^[0-9a-fA-F]{4}$ && "$product_id" =~ ^[0-9a-fA-F]{4}$ ]]; then
                     ids="${vendor_id}:${product_id}"
                     log "DEBUG" "Found USB IDs via sysfs traversal at $current_path: $ids"
                     VENDOR_ID="$vendor_id"
                     PRODUCT_ID="$product_id"
                     echo "$ids"; return 0
                 fi
            fi
            # Check one level up in case they are in the parent (common for USB interfaces)
            local parent_path=$(dirname "$current_path")
             if [[ "$parent_path" != "$current_path" ]]; then # Avoid infinite loop at /
                log "TRACE" "Checking sysfs parent path component: $parent_path"
                if [[ -f "$parent_path/idVendor" && -f "$parent_path/idProduct" ]]; then
                    vendor_id=$(cat "$parent_path/idVendor" 2>/dev/null)
                    product_id=$(cat "$parent_path/idProduct" 2>/dev/null)
                    log "TRACE" "Found potential IDs at parent $parent_path: V='$vendor_id' P='$product_id'"
                    if [[ "$vendor_id" =~ ^[0-9a-fA-F]{4}$ && "$product_id" =~ ^[0-9a-fA-F]{4}$ ]]; then
                        ids="${vendor_id}:${product_id}"
                        log "DEBUG" "Found USB IDs via sysfs traversal at parent $parent_path: $ids"
                        VENDOR_ID="$vendor_id"
                        PRODUCT_ID="$product_id"
                        echo "$ids"; return 0
                    fi
                fi
             fi
            current_path=$(dirname "$current_path") # Go up one level
        done
        log "TRACE" "sysfs traversal did not yield IDs."
    else
         log "TRACE" "Could not resolve sysfs link $sys_dev_link"
    fi

    # Method 3: lsusb and lsscsi matching
    log "TRACE" "Trying lsusb/lsscsi matching for $dev_name"
    local scsi_info model vendor
    # Use `lsscsi -t` to potentially get transport protocol explicitly
    if scsi_info=$(lsscsi -t | grep "$dev_name" | head -n 1); then
        log "TRACE" "lsscsi -t info: $scsi_info"
        # Extract model and vendor more robustly
        # Assumes format like [H:C:T:L] type vendor model rev /dev/sgX transport ... /dev/sdX
        model=$(echo "$scsi_info" | sed -n 's/.*\] *[^ ]* *[^ ]* *\(.*\) *[^ ]* *\/dev\/sg.* \/dev\/'"$dev_name"'.*/\1/p' | sed 's/ *$//')
        vendor=$(echo "$scsi_info" | sed -n 's/.*\] *[^ ]* *\([^ ]*\).*/\1/p')
        log "TRACE" "lsscsi parsed: Vendor='$vendor', Model='$model'"
        if [[ -n "$vendor" || -n "$model" ]]; then
             # Read lsusb output line by line
             while IFS= read -r line; do
                  log "TRACE" "Checking lsusb line: $line"
                  local usb_id=""
                  # Extract ID xxxx:xxxx
                  usb_id=$(echo "$line" | grep -o 'ID [[:xdigit:]]\{4\}:[[:xdigit:]]\{4\}' | awk '{print $2}')
                  if [[ -n "$usb_id" ]]; then
                      # Simple match: check if vendor OR model appears in the lsusb description
                      # Make matching case-insensitive for robustness
                      if ( [[ -n "$vendor" && $(echo "$line" | grep -iq "$vendor") ]] || \
                           [[ -n "$model" && $(echo "$line" | grep -iq "$model") ]] ); then
                           log "DEBUG" "Found potential USB ID match via lsusb/lsscsi: $usb_id (Matched on Vendor/Model string: '$vendor' / '$model')"
                           VENDOR_ID=$(echo "$usb_id" | cut -d: -f1)
                           PRODUCT_ID=$(echo "$usb_id" | cut -d: -f2)
                           echo "$usb_id"; return 0
                      fi
                  fi
             done < <(lsusb)
             log "TRACE" "Finished checking lsusb output."
        fi
    else
        log "TRACE" "lsscsi -t provided no info containing $dev_name"
    fi

    log "WARNING" "Could not automatically determine USB Vendor/Product IDs for $dev_path."
    echo "$ids" # Return "unknown"
    return 1
}


# Interactively select a USB block device
select_usb_device() {
    log "INFO" "Scanning for USB block devices using lsblk..."
    local devices_found=()
    local device_lines=()
    local line devname tran model vendor size is_block is_partition is_readonly
    local lsblk_cmd="lsblk -dpno NAME,SIZE,VENDOR,MODEL,TRAN"

    log "DEBUG" "Running command: $lsblk_cmd"
    local lsblk_output
    lsblk_output=$($lsblk_cmd 2>&1)
    local lsblk_status=$?

    if [ $lsblk_status -ne 0 ]; then
        log "ERROR" "lsblk command failed (Exit code $lsblk_status). Cannot scan for devices."
        log "ERROR" "Output:\n$lsblk_output"
        exit $E_DEVICE_NOT_FOUND
    fi

    log "TRACE" "--- Start lsblk Output Processing ---"
    while IFS= read -r line || [ -n "$line" ]; do # Handle lines, including last one if no newline
        # Skip empty lines
        [[ -z "$line" ]] && continue
        log "TRACE" "Raw lsblk output line: '$line'"

        # Attempt to parse fields robustly (assuming space delimited)
        devname=$(echo "$line" | awk '{print $1}')
        size=$(echo "$line" | awk '{print $2}')
        vendor=$(echo "$line" | awk '{print $3}')
        model=$(echo "$line" | awk '{print $4}')
        tran=$(echo "$line" | awk '{print $NF}') # Assume TRAN is last

        # Perform checks
        is_block=$(test -b "$devname" && echo true || echo false)
        is_partition=$( [[ "$devname" =~ [0-9]$ ]] && echo true || echo false)
        # Get RO flag, handle potential errors from lsblk if device disappears
        ro_flag=$(lsblk -ndo RO "$devname" 2>/dev/null)
        if [ $? -ne 0 ]; then
             log "TRACE" "Skipping $devname: Could not get RO flag (device might have vanished)."
             continue
        fi
        is_readonly=$( [ "$ro_flag" = "1" ] && echo true || echo false)


        log "TRACE" "Checking Device: '$devname' | Tran: '$tran' | IsBlock: $is_block | IsPartition: $is_partition | IsReadOnly: $is_readonly (RO Flag: '$ro_flag')"

        # Apply Filters
        if [[ "$tran" != "usb" ]]; then
             log "TRACE" "Skipping $devname: Transport is not 'usb' (it's '$tran')."
             continue
        fi
        if [[ "$is_block" != "true" ]]; then
             log "TRACE" "Skipping $devname: Not a block device."
             continue
        fi
         if [[ "$is_partition" == "true" ]]; then
             log "TRACE" "Skipping $devname: Is a partition."
             continue
         fi
        if [[ "$is_readonly" == "true" ]]; then
             log "TRACE" "Skipping $devname: Is read-only."
             continue
        fi

        # If all checks pass, add it
        log "DEBUG" "Found suitable USB device: $devname (Line: $line)"
        devices_found+=("$devname")
        device_lines+=("$line") # Store the original line for display

    done <<< "$lsblk_output" # Use <<< for process substitution
    log "TRACE" "--- End lsblk Output Processing ---"


    if [ ${#devices_found[@]} -eq 0 ]; then
        log "ERROR" "No suitable USB block devices found."
        log "ERROR" "Criteria: Transport='usb', Type=block, Not a partition, Writable."
        log "ERROR" "Check 'lsblk -dpno NAME,SIZE,VENDOR,MODEL,TRAN' output manually."
        exit $E_DEVICE_NOT_FOUND
    fi

    echo -e "\n${BOLD}Available USB Block Devices:${RESET}"
    echo "---------------------------------"
    # Use stored lines for display to preserve original formatting/fields
    printf "%-4s %-15s %-10s %-15s %-s\n" "Num" "Device" "Size" "Vendor" "Model" # Header
    echo

    for i in "${!devices_found[@]}"; do
        # Reparse the stored line for display
        local display_line="${device_lines[$i]}"
        local d_devname=$(echo "$display_line" | awk '{print $1}')
        local d_size=$(echo "$display_line" | awk '{print $2}')
        local d_vendor=$(echo "$display_line" | awk '{print $3}')
        local d_model=$(echo "$display_line" | awk '{print $4}')
        # Combine remaining fields if model had spaces
        local d_model_rest=$(echo "$display_line" | awk '{$1=$2=$3=""; sub(/^[ \t]+/, ""); print $0}' | sed 's/ usb$//') # Get rest except TRAN

        printf "%-4s %-15s %-10s %-15s %-s\n" "$((i+1))." "$d_devname" "$d_size" "$d_vendor" "$d_model_rest"

    done

    echo

    local selection
    while true; do
        read -p "Select device number (1-${#devices_found[@]}): " selection
        if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le "${#devices_found[@]}" ]; then
            DEVICE="${devices_found[$((selection-1))]}"
            DEVICE_NAME="${DEVICE##*/}"
            log "INFO" "Selected device: $DEVICE"
            log "DEBUG" "Selected device details: ${device_lines[$((selection-1))]}"

            # Get the USB IDs
            local usb_id
            usb_id=$(get_usb_ids "$DEVICE")

            if [[ "$usb_id" != "unknown" ]]; then
                SELECTED_USB="$usb_id"
                log "DEBUG" "Final USB ID for $DEVICE: $SELECTED_USB"
            else
                 echo
                 echo -e "${YELLOW}Could not automatically determine USB vendor and product IDs for $DEVICE.${RESET}"
                 echo -e "You can try 'lsusb' in another terminal to find the ${BOLD}ID xxxx:xxxx${RESET} value."
                 read -p "Enter the vendor:product ID (e.g., 1b1c:1a0e, leave blank to skip): " manual_usb_id
                 if [[ "$manual_usb_id" =~ ^[0-9a-fA-F]{4}:[0-9a-fA-F]{4}$ ]]; then
                     SELECTED_USB="$manual_usb_id"
                     VENDOR_ID=$(echo "$manual_usb_id" | cut -d: -f1)
                     PRODUCT_ID=$(echo "$manual_usb_id" | cut -d: -f2)
                     log "INFO" "Using manually entered USB ID: $SELECTED_USB"
                 else
                     log "WARNING" "Invalid or no manual USB ID entered. Will create a generic udev rule."
                     SELECTED_USB="unknown" # Ensure it's marked unknown
                     VENDOR_ID=""
                     PRODUCT_ID=""
                 fi
            fi
            break
        else
            log "ERROR" "Invalid selection. Please enter a number between 1 and ${#devices_found[@]}."
        fi
    done
}

# --- Core TRIM Functions ---

# Checks if the selected device firmware supports TRIM commands
check_trim_support() {
    log "INFO" "Checking TRIM/Unmap support for $DEVICE..."
    DEVICE_TRIM_SUPPORTED=0 # Reset status
    DEVICE_MAX_UNMAP_LBA_COUNT=0

    # Check Maximum unmap LBA count using sg_vpd Block Limits page (-p bl)
    log "DEBUG" "Running: sg_vpd --page=bl \"$DEVICE\"" # Use long option for clarity
    local sg_vpd_bl_output
    sg_vpd_bl_output=$(sg_vpd --page=bl "$DEVICE" 2>&1)
    local sg_vpd_bl_status=$?
    if [ $sg_vpd_bl_status -ne 0 ]; then
        log "WARNING" "sg_vpd --page=bl command failed (Exit code $sg_vpd_bl_status). Cannot determine Max Unmap LBA count."
        log "TRACE" "sg_vpd --page=bl output:\n$sg_vpd_bl_output"
    else
        log "TRACE" "sg_vpd --page=bl output:\n$sg_vpd_bl_output"
        local count_str
        # Extract number after "Maximum unmap LBA count:" (case-insensitive)
        count_str=$(echo "$sg_vpd_bl_output" | grep -i "Maximum unmap LBA count:" | sed -n 's/.*:\s*\([0-9]\+\).*/\1/p')
        if [[ "$count_str" =~ ^[0-9]+$ ]]; then
            DEVICE_MAX_UNMAP_LBA_COUNT=$count_str
        else
            log "WARNING" "Could not parse numeric value for 'Maximum unmap LBA count' from sg_vpd output."
            log "TRACE" "Value parsed: '$count_str'"
            DEVICE_MAX_UNMAP_LBA_COUNT=0
        fi
    fi
    log "DEBUG" "Reported Maximum unmap LBA count: $DEVICE_MAX_UNMAP_LBA_COUNT"

    # Check Unmap command supported (LBPU) using sg_vpd Logical Block Provisioning page (-p lbpv)
    log "DEBUG" "Running: sg_vpd --page=lbpv \"$DEVICE\""
    local sg_vpd_lbpv_output
    sg_vpd_lbpv_output=$(sg_vpd --page=lbpv "$DEVICE" 2>&1)
    local sg_vpd_lbpv_status=$?
    local lbpu_supported=0 # Assume not supported unless proven otherwise
    if [ $sg_vpd_lbpv_status -ne 0 ]; then
        log "WARNING" "sg_vpd --page=lbpv command failed (Exit code $sg_vpd_lbpv_status). Cannot determine LBPU status."
        log "TRACE" "sg_vpd --page=lbpv output:\n$sg_vpd_lbpv_output"
    else
        log "TRACE" "sg_vpd --page=lbpv output:\n$sg_vpd_lbpv_output"
        # Look for the line like "Unmap command supported (LBPU): 1" (case-insensitive, ignoring spaces around :)
        if echo "$sg_vpd_lbpv_output" | grep -Eiq "Unmap command supported \(LBPU\)[[:space:]]*:[[:space:]]*1"; then
            lbpu_supported=1
        elif echo "$sg_vpd_lbpv_output" | grep -Eiq "Unmap command supported \(LBPU\)[[:space:]]*:[[:space:]]*0"; then
             lbpu_supported=0
        else
             log "WARNING" "Could not determine LBPU status from sg_vpd output (Expected '... (LBPU): 1' or '... (LBPU): 0'). Assuming not supported."
             lbpu_supported=0
        fi
    fi
    log "DEBUG" "Reported Unmap command supported (LBPU): $lbpu_supported"

    # Check hdparm as a fallback/confirmation if sg_vpd indicates no support or failed
    local hdparm_supported=0
    if [[ "$DEVICE_MAX_UNMAP_LBA_COUNT" -eq 0 || "$lbpu_supported" -eq 0 || $sg_vpd_bl_status -ne 0 || $sg_vpd_lbpv_status -ne 0 ]]; then
        log "INFO" "Primary TRIM check (sg_vpd) indicates no/limited support or failed. Trying hdparm as fallback..."
        log "DEBUG" "Running: hdparm -I \"$DEVICE\""
        local hdparm_output
        # hdparm can be slow, capture output efficiently
        hdparm_output=$(hdparm -I "$DEVICE" 2>&1)
        local hdparm_status=$?
        if [ $hdparm_status -ne 0 ]; then
             # hdparm often fails on USB adapters, don't make this a strong warning unless verbose
             log "DEBUG" "hdparm -I command failed (Exit code $hdparm_status). Cannot verify via hdparm."
             log "TRACE" "hdparm output:\n$hdparm_output"
        # Check for "Data Set Management TRIM supported" or "Deterministic read ZEROs after TRIM"
        elif echo "$hdparm_output" | grep -q "Data Set Management TRIM supported" || \
             echo "$hdparm_output" | grep -q "Deterministic read ZEROs after TRIM"; then
             log "INFO" "TRIM support indicated by hdparm."
             hdparm_supported=1
             log "TRACE" "hdparm -I relevant lines:\n$(echo "$hdparm_output" | grep -i trim)"
        else
             log "INFO" "TRIM support not indicated by hdparm."
             log "TRACE" "Full hdparm -I output:\n$hdparm_output"
        fi
    fi

    # --- Final Decision Logic ---
    # Consider supported if LBPU is 1 AND max unmap count > 0, OR if hdparm reported support
    if [[ "$lbpu_supported" -eq 1 && "$DEVICE_MAX_UNMAP_LBA_COUNT" -gt 0 ]] || [[ "$hdparm_supported" -eq 1 ]]; then
        log "SUCCESS" "Device $DEVICE appears to support TRIM/Unmap/Discard commands."
        DEVICE_TRIM_SUPPORTED=1
        # If primary check failed but hdparm succeeded, use a default non-zero LBA count for discard_max calc
        if [[ "$DEVICE_MAX_UNMAP_LBA_COUNT" -eq 0 && "$hdparm_supported" -eq 1 ]]; then
             log "WARNING" "Using default Max Unmap LBA Count (e.g., 4194304) for calculation as sg_vpd failed/was zero but hdparm detected support."
             # Use a reasonable default like 2GB/512 = 4194304 or just leave it high if unsure
             DEVICE_MAX_UNMAP_LBA_COUNT=4194304 # Default to 2GiB worth of 512b blocks
        fi
    else
        log "ERROR" "Device $DEVICE does not appear to support TRIM/Unmap/Discard based on sg_vpd and hdparm checks."
        DEVICE_TRIM_SUPPORTED=0
        echo -e "\n${RED}${BOLD}WARNING:${RESET} ${RED}TRIM (discard/unmap) commands do not appear to be supported by this device's firmware or the USB adapter.${RESET}"
        echo -e "${YELLOW}Configuring TRIM may have no effect or, in rare cases, cause issues.${RESET}"
        echo -e "${YELLOW}Make sure you have backups of any important data on this drive.${RESET}"
        # Store response in a variable declared outside scope
        local continue_anyway_response=""
        read -p "Do you want to continue anyway and create the configuration? (y/N): " continue_anyway_response
        # Make global variable accessible
        declare -g continue_anyway="$continue_anyway_response"
        if [[ ! "$continue_anyway" =~ ^[Yy]$ ]]; then
            log "INFO" "User aborted due to lack of detected TRIM support."
            exit $E_TRIM_UNSUPPORTED_ABORT
        fi
        log "WARNING" "User chose to continue despite lack of detected TRIM support. Proceeding with configuration."
        # Use a default non-zero count if we proceed, otherwise discard_max_bytes calculation yields 0
        if [[ "$DEVICE_MAX_UNMAP_LBA_COUNT" -eq 0 ]]; then
             DEVICE_MAX_UNMAP_LBA_COUNT=4194304 # Default to 2GiB worth of 512b blocks
             log "WARNING" "Using default Max Unmap LBA Count ($DEVICE_MAX_UNMAP_LBA_COUNT) for calculation."
        fi
    fi
}

# Calculates discard_max_bytes based on device capabilities
calculate_discard_max() {
    local block_size=512 # Default assumption

    log "INFO" "Calculating discard_max_bytes for $DEVICE..."
    log "DEBUG" "Using Max Unmap LBA Count: $DEVICE_MAX_UNMAP_LBA_COUNT"

    # Get logical block size using sg_readcap -l
    log "DEBUG" "Running: sg_readcap --long \"$DEVICE\"" # Use long option
    local sg_readcap_output
    sg_readcap_output=$(sg_readcap --long "$DEVICE" 2>&1)
    local sg_readcap_status=$?
    if [ $sg_readcap_status -ne 0 ]; then
        log "WARNING" "sg_readcap command failed (Exit code $sg_readcap_status). Using default block size 512."
        log "TRACE" "sg_readcap output: $sg_readcap_output"
    else
        log "TRACE" "sg_readcap output:\n$sg_readcap_output"
        local detected_bs_str
        # Extract number after "Logical block length=" (case-insensitive, ignore spaces around =)
        detected_bs_str=$(echo "$sg_readcap_output" | grep -i "Logical block length=" | sed -n 's/.*=[[:space:]]*\([0-9]\+\).*/\1/p')
        if [[ "$detected_bs_str" =~ ^[0-9]+$ ]] && [ "$detected_bs_str" -gt 0 ]; then
            block_size=$detected_bs_str
        else
            log "WARNING" "Could not parse valid block size from sg_readcap. Using default: 512."
            log "TRACE" "Parsed block size value: '$detected_bs_str'"
        fi
    fi
    log "DEBUG" "Using block size: $block_size bytes"

    # Calculate discard_max_bytes = LBA count * block size
    # Check for potential arithmetic overflow if counts are huge (bash limitation)
    # Max bash integer is 9223372036854775807
    # If LBA count * block_size exceeds this, we might get errors or wrap around.
    # Example: 2^32 blocks * 4096 bytes/block = 16TB (well within limits)
    # Example: 2^48 blocks * 4096 bytes/block = 1 PiB (still okay)
    # Unlikely to be an issue unless LBA count > ~2^50 with 4k blocks.
    if [[ "$DEVICE_MAX_UNMAP_LBA_COUNT" -gt 0 ]]; then
        # Use external tool like 'bc' for potentially huge numbers if necessary, but try bash first
        if (( DEVICE_MAX_UNMAP_LBA_COUNT > 9223372036854775807 / block_size )); then
             log "WARNING" "Potential integer overflow in bash calculation. Using 'bc'."
             DEVICE_DISCARD_MAX_BYTES=$(echo "$DEVICE_MAX_UNMAP_LBA_COUNT * $block_size" | bc)
        else
             DEVICE_DISCARD_MAX_BYTES=$((DEVICE_MAX_UNMAP_LBA_COUNT * block_size))
        fi

        # Sanity Check: discard_max_bytes shouldn't be excessively large (e.g. > 1 PiB?)
        # Often capped by kernel or device anyway. Set a reasonable upper limit? (e.g. 4GB for safety?)
        # Let's cap it at 2^32 - 1 (4GiB - 1), common limit.
        local max_discard_limit=4294967295
        if (( DEVICE_DISCARD_MAX_BYTES > max_discard_limit )); then
            log "WARNING" "Calculated discard_max_bytes ($DEVICE_DISCARD_MAX_BYTES) exceeds 4GiB limit. Capping at $max_discard_limit."
            DEVICE_DISCARD_MAX_BYTES=$max_discard_limit
        fi

    else
        # If firmware doesn't support it or count is 0, set discard_max_bytes to 0
        DEVICE_DISCARD_MAX_BYTES=0
        log "WARNING" "Max Unmap LBA count is 0 or unsupported. Setting discard_max_bytes to 0 (effectively disabling kernel discard limits)."
    fi

    log "INFO" "Calculated discard_max_bytes: $DEVICE_DISCARD_MAX_BYTES"
}

# Sets runtime values (best effort) and creates persistent udev rule
configure_trim() {
    log "INFO" "Applying TRIM configuration for $DEVICE using udev..."
    local device_name=${DEVICE##*/} # e.g., sda, sdb (no partition)
    device_name=${device_name%%[0-9]*} # Ensure it's the base device name
    DEVICE_NAME="$device_name"  # Store for later use
    local discard_max=$DEVICE_DISCARD_MAX_BYTES

    # --- Removed Runtime Setting Section ---
    # Runtime settings are less reliable than udev and can be temporary.
    # udev handles applying settings when the device is plugged in.
    # We'll rely on udev rules + reload/trigger + reboot.
    log "INFO" "Skipping direct runtime configuration. Relying on udev rules."

    # --- Create persistent udev rule ---
    log "INFO" "Creating persistent udev rule..."

    # Ensure udev directory exists
    if ! mkdir -p "$UDEV_RULE_DIR"; then
        log "ERROR" "Failed to create udev rules directory: $UDEV_RULE_DIR"
        exit $E_UDEV_RULE
    fi
    log "TRACE" "Udev rule directory verified: $UDEV_RULE_DIR"

    local rule_file=""
    local rule_content=""

    # If we have a specific USB ID, use it for a targeted rule (preferred)
    if [[ "$SELECTED_USB" != "unknown" && -n "$VENDOR_ID" && -n "$PRODUCT_ID" ]]; then
        rule_file="$UDEV_RULE_DIR/10-usb-ssd-trim-${VENDOR_ID}-${PRODUCT_ID}.rules"
        log "INFO" "Creating USB ID specific udev rule: $rule_file"

        # Combined rule for provisioning_mode and discard_max_bytes
        # Using ATTR for provisioning_mode is cleaner if supported by the kernel/udev version
        # Using KERNEL=="sd*[!0-9]" ensures we only apply to the base device, not partitions
        rule_content=$(cat << EOF
# Udev rule for USB SSD ${VENDOR_ID}:${PRODUCT_ID} - TRIM support
# Created by setup-trim-final.sh (v3.3) for device matching $DEVICE
# Applies settings to the base block device (e.g., sda, not sda1)

ACTION=="add|change", ATTRS{idVendor}=="$VENDOR_ID", ATTRS{idProduct}=="$PRODUCT_ID", SUBSYSTEM=="block", KERNEL=="sd*[!0-9]", ATTR{queue/discard_max_bytes}="$discard_max"
# Attempt setting provisioning_mode directly via ATTR on scsi_disk subsystem.
# This might require the kernel to expose it this way.
ACTION=="add|change", ATTRS{idVendor}=="$VENDOR_ID", ATTRS{idProduct}=="$PRODUCT_ID", SUBSYSTEM=="scsi_disk", ATTR{provisioning_mode}="unmap"

# Fallback using RUN if the ATTR{provisioning_mode} doesn't work directly.
# This targets the specific device path more reliably.
# ACTION=="add|change", ATTRS{idVendor}=="$VENDOR_ID", ATTRS{idProduct}=="$PRODUCT_ID", SUBSYSTEM=="block", KERNEL=="$device_name", RUN+="/bin/sh -c 'echo unmap > /sys/block/%k/device/scsi_disk/*/provisioning_mode 2>/dev/null || true'"
EOF
)
        # Note: The commented RUN fallback is an alternative if ATTR doesn't work.
        # For simplicity and standard practice, we'll rely on the ATTR methods first.

    else
        # Fallback to generic rule based on kernel name (less reliable if names change)
        log "WARNING" "USB Vendor/Product ID unavailable. Creating generic udev rule based on kernel name ($device_name)."
        log "WARNING" "This rule might affect other devices if kernel names change upon reboot or reconnection."
        rule_file="$UDEV_RULE_DIR/11-generic-ssd-trim-${device_name}.rules"
        log "INFO" "Creating generic udev rule: $rule_file"

        rule_content=$(cat << EOF
# Generic Udev rule for TRIM support - device matching kernel name $device_name
# Created by setup-trim-final.sh (v3.3) for device $DEVICE
# WARNING: This rule is based on kernel name and might affect other devices if names change.

ACTION=="add|change", SUBSYSTEM=="block", KERNEL=="$device_name", ATTR{queue/discard_max_bytes}="$discard_max"
# Attempt setting provisioning_mode directly via ATTR on scsi_disk subsystem if possible
# This requires finding the correct scsi_disk path, which is hard generically here.
# Falling back to RUN command for provisioning_mode in generic case.
ACTION=="add|change", SUBSYSTEM=="block", KERNEL=="$device_name", RUN+="/bin/sh -c 'for p in /sys\$devpath/device/scsi_disk/*/provisioning_mode; do [ -f \"\$p\" ] && [ -w \"\$p\" ] && echo unmap > \"\$p\"; done'"
EOF
)
        # Note: Using /sys$devpath is generally better than hardcoding /sys/block/$device_name within RUN.
        # $devpath is provided by udev during rule execution.
    fi

    # Write the rule file
    log "DEBUG" "Writing udev rule content to $rule_file"
    log "TRACE" "Rule content:\n$rule_content"
    if echo "$rule_content" > "$rule_file"; then
        log "SUCCESS" "Created udev rule: $rule_file"
        UDEV_RULE_CREATED=1
    else
        log "ERROR" "Failed to write udev rule file: $rule_file (Exit code $?)"
        # Attempt to show filesystem details if logging is on
        [ "$VERBOSE" -ge 1 ] && ls -ld "$UDEV_RULE_DIR" && df "$UDEV_RULE_DIR"
        exit $E_UDEV_RULE
    fi

    # Reload udev rules and trigger changes
    log "INFO" "Reloading udev rules (udevadm control --reload-rules)..."
    if udevadm control --reload-rules; then
        log "DEBUG" "udevadm rules reload successful."
    else
        log "WARNING" "Failed to reload udev rules (udevadm control exit code $?). Changes may only apply after reboot."
    fi

    log "INFO" "Triggering udev events for block devices (udevadm trigger)..."
    # Trigger for the specific device if possible, otherwise all block devices
    if [ -e "$DEVICE" ]; then
        if udevadm trigger --action=change --name="$DEVICE"; then
             log "DEBUG" "udevadm trigger successful for $DEVICE."
        else
             log "WARNING" "Failed to trigger udev for $DEVICE (udevadm trigger exit code $?). Might need reboot."
        fi
    else
         if udevadm trigger --action=change --subsystem-match=block; then
              log "DEBUG" "udevadm trigger successful for block subsystem."
         else
              log "WARNING" "Failed to trigger udev for block subsystem (udevadm trigger exit code $?). Might need reboot."
         fi
    fi


    # --- Removed rc.local and init.d sections ---
    log "INFO" "Persistence relies on the created udev rule(s)."
    log "INFO" "Reboot recommended for changes to be fully effective system-wide."
}


# Configures the systemd fstrim timer using override files
configure_trim_timer() {
    if [ "$ENABLE_TIMER" -ne 1 ]; then
         log "INFO" "Automatic TRIM timer setup skipped (Use --enable-timer to activate)."
         return 0
    fi

    log "INFO" "Configuring systemd fstrim.timer for schedule: $TIMER_SCHEDULE"

    # Validate schedule
    case "$TIMER_SCHEDULE" in
        daily|weekly|monthly) log "DEBUG" "Timer schedule '$TIMER_SCHEDULE' is valid." ;;
        *) log "ERROR" "Invalid timer schedule: '$TIMER_SCHEDULE'. Use 'daily', 'weekly', or 'monthly'."; return $E_ARGS ;;
    esac

    local timer_unit="fstrim.timer"
    local service_unit="fstrim.service"
    local timer_override_dir="$SYSTEMD_OVERRIDE_DIR/$timer_unit.d"
    # Use a simple override file name
    local timer_override_file="$timer_override_dir/override.conf"

    # Check if the base fstrim service unit exists
    log "DEBUG" "Checking for $service_unit..."
    if ! systemctl list-unit-files "$service_unit" | grep -q "$service_unit"; then
         # This is unexpected on most systems with util-linux installed
         log "ERROR" "$service_unit not found. This service is usually part of 'util-linux'."
         log "ERROR" "Cannot configure timer without the service. Ensure 'util-linux' is correctly installed."
         return $E_SYSTEMD # Use a generic systemd error code here
    fi
    log "TRACE" "$service_unit found."

    # Create the override directory
    log "DEBUG" "Ensuring override directory exists: $timer_override_dir"
    if ! mkdir -p "$timer_override_dir"; then
        log "ERROR" "Failed to create systemd override directory: $timer_override_dir"
        return $E_SYSTEMD
    fi

    # Create the override file to set the schedule
    log "INFO" "Creating/updating timer schedule override: $timer_override_file"
    # Content focuses only on overriding the schedule
    local override_content
    override_content=$(cat << EOF
# Systemd override file modified by setup-trim-final.sh
# Sets the schedule for the main fstrim.timer unit.
[Timer]
# Clear existing schedule entries first
OnCalendar=
# Set the new schedule
OnCalendar=$TIMER_SCHEDULE
# Keep other settings like AccuracySec, Persistent from the original unit if desired
# AccuracySec=1h
# Persistent=true
EOF
)
    log "TRACE" "Override content:\n$override_content"
    if ! echo "$override_content" > "$timer_override_file"; then
        log "ERROR" "Failed to write timer override file: $timer_override_file"
        return $E_SYSTEMD
    fi
    log "DEBUG" "Timer override file written successfully."

    # Reload daemon, enable and start the timer
    log "INFO" "Reloading systemd daemon..."
    if ! systemctl daemon-reload; then
        log "WARNING" "systemctl daemon-reload failed (Exit code $?). Configuration might be stale."
        # Continue, maybe enable/start still works
    fi

    # Enable the timer first (idempotent)
    log "INFO" "Enabling $timer_unit..."
    if ! systemctl enable "$timer_unit"; then
         log "WARNING" "Failed to enable $timer_unit (Exit code $?). It might be masked or another issue occurred. Check 'systemctl list-unit-files'."
         # Don't exit, maybe start still works or user can fix manually
    fi

    # Restart the timer to apply the new schedule immediately
    log "INFO" "Restarting $timer_unit to apply schedule..."
    if ! systemctl restart "$timer_unit"; then
         log "WARNING" "Failed to restart $timer_unit (Exit code $?). Check 'systemctl status $timer_unit' and 'journalctl -u $timer_unit'."
    fi

    # Check final status
    sleep 1 # Give systemd a moment
    local timer_active timer_enabled timer_sched
    timer_active=$(systemctl is-active "$timer_unit" 2>/dev/null || echo "failed-read")
    timer_enabled=$(systemctl is-enabled "$timer_unit" 2>/dev/null || echo "failed-read")
    # Try to get the current schedule
    timer_sched=$(systemctl show -p Timers "$timer_unit" 2>/dev/null | grep OnCalendar | cut -d= -f2- | head -n 1)


    if [[ "$timer_active" == "active" && "$timer_enabled" == "enabled" ]]; then
        log "SUCCESS" "$timer_unit is now active and enabled."
        log "INFO" "Current schedule: $timer_sched (Expected: $TIMER_SCHEDULE)"
         # Check if schedule matches expected
         if [[ "$timer_sched" == *"$TIMER_SCHEDULE"* ]]; then
              log "DEBUG" "Timer schedule appears correctly set."
         else
              log "WARNING" "Timer schedule '$timer_sched' might not match desired '$TIMER_SCHEDULE'. Verify override file and 'systemctl status $timer_unit'."
         fi
    else
        log "WARNING" "Could not fully activate/enable $timer_unit."
        log "WARNING" "Current state - Active: $timer_active, Enabled: $timer_enabled"
        log "WARNING" "Review systemd status: 'systemctl status $timer_unit' and logs: 'journalctl -u $timer_unit'"
    fi
}

# Attempts to run fstrim on mounted filesystems related to the device
test_trim() {
    log "INFO" "Attempting to test TRIM using fstrim..."
    FSTRIM_TEST_SUCCESS=0 # Reset test success flag
    FOUND_MOUNTPOINT="" # Reset mountpoint

    local test_mount_point=""
    # Find mount points associated with the base device OR its partitions
    log "DEBUG" "Searching for mount points related to device $DEVICE_NAME* ..."
    local base_device_name="$DEVICE_NAME" # e.g. sda

    # Use lsblk to find mountpoints for the device and its partitions
    # -r uses raw format, -o MOUNTPOINT only, -n no header
    # grep for the base device name to include partitions like sda1, sda2
    local mount_points
    mount_points=$(lsblk -rno MOUNTPOINT "/dev/${base_device_name}"* 2>/dev/null | grep -v '^$' | head -n 1) # Find first non-empty mountpoint

    if [ -n "$mount_points" ]; then
         test_mount_point="$mount_points"
         log "INFO" "Found related mounted filesystem at $test_mount_point. Testing TRIM there."
         FOUND_MOUNTPOINT="$test_mount_point"
    else
         log "INFO" "Device $DEVICE (or its partitions like ${base_device_name}1) does not appear to be mounted."
         log "INFO" "Cannot perform specific fstrim test. Test manually after mounting."
         return 0 # Not an error, just can't test directly
    fi

    # Run fstrim in verbose mode on the found mount point
    log "DEBUG" "Running: fstrim -v \"$test_mount_point\""
    local fstrim_output
    fstrim_output=$(fstrim -v "$test_mount_point" 2>&1)
    local fstrim_status=$?

    if [ $fstrim_status -eq 0 ]; then
        log "SUCCESS" "fstrim test successful on $test_mount_point."
        log "INFO" "Output: $fstrim_output"
        FSTRIM_TEST_SUCCESS=1
        return 0
    else
        # Check for common "discard operation is not supported" error
        if echo "$fstrim_output" | grep -q -i "the discard operation is not supported"; then
            log "ERROR" "fstrim test FAILED on $test_mount_point: The discard operation is not supported."
            log "ERROR" "Possible Reasons:"
            log "ERROR" "  1. Filesystem Type: The filesystem (check with 'lsblk -f $DEVICE') might not support TRIM (e.g., FAT32, older ext versions)."
            log "ERROR" "  2. Mount Options: Filesystem needs to be mounted with the 'discard' option (check 'mount | grep $test_mount_point')."
            log "ERROR" "  3. Device/Adapter/Rule Issue: TRIM commands are still not passing through correctly. A REBOOT is often needed after udev changes."
            log "ERROR" "  4. Kernel Support: Older kernels might have limitations."

            # Try to get filesystem type and mount options for better diagnostics
            local fs_type mount_opts
            fs_type=$(lsblk -no FSTYPE "$DEVICE" 2>/dev/null | head -n 1)
            mount_opts=$(mount | grep "$test_mount_point" | sed 's/.* type .* (\(.*\))/\1/')
            log "DEBUG" "Filesystem type: '$fs_type'. Mount options: '$mount_opts'."

            # Suggest remount if applicable
            if [[ -n "$mount_opts" && ! "$mount_opts" =~ discard ]]; then
                log "INFO" "The filesystem is mounted without the 'discard' option. You can try remounting:"
                log "INFO" "sudo mount -o remount,discard \"$test_mount_point\""
                log "INFO" "Then run 'sudo fstrim -v \"$test_mount_point\"' again."
                log "INFO" "To make this permanent, add 'discard' to the options in /etc/fstab."
            fi
        else
            # Generic failure
            log "ERROR" "fstrim test FAILED on $test_mount_point (Exit code: $fstrim_status)."
            log "ERROR" "Output: $fstrim_output"
            log "ERROR" "Check filesystem integrity ('fsck'), mount status, kernel logs ('dmesg'), and ensure udev rules have applied (REBOOT RECOMMENDED)."
        fi
        return 1 # Indicate test failure
    fi
}

# --- Main Execution ---

# --- Argument Parsing ---
# Define default values again here for getopt clarity
_DEVICE=""
_TIMER_SCHEDULE="$DEFAULT_TIMER_SCHEDULE"
_AUTO_INSTALL=0
_ENABLE_TIMER=0
_SELECT_USB=0
_VERBOSE=0
_LOG_FILE=""

# Use getopt for robust parsing
# Ensure long options are properly terminated
VALID_ARGS=$(getopt -o d:t:aeuvl:h --long device:,timer:,auto,enable-timer,select-usb,verbose,log:,help -- "$@")
if [[ $? -ne 0 ]]; then
    echo "Invalid arguments." >&2
    show_help
    exit $E_ARGS
fi

eval set -- "$VALID_ARGS"
while true; do
    case "$1" in
        -d | --device) _DEVICE="$2"; shift 2 ;;
        -t | --timer) _TIMER_SCHEDULE="$2"; shift 2 ;;
        -a | --auto) _AUTO_INSTALL=1; shift ;;
        -e | --enable-timer) _ENABLE_TIMER=1; shift ;;
        -u | --select-usb) _SELECT_USB=1; shift ;;
        -v | --verbose) ((_VERBOSE++)); shift ;; # Allow -v, -vv
        -l | --log) _LOG_FILE="$2"; shift 2 ;;
        -h | --help) show_help; exit $E_SUCCESS ;;
        --) shift; break ;;
        *) log "ERROR" "Internal error parsing arguments via getopt!"; exit $E_INTERNAL ;;
    esac
done

# Assign parsed values to state variables
DEVICE="$_DEVICE"
TIMER_SCHEDULE="$_TIMER_SCHEDULE"
AUTO_INSTALL=$_AUTO_INSTALL
ENABLE_TIMER=$_ENABLE_TIMER
VERBOSE=$_VERBOSE
LOG_FILE="$_LOG_FILE"

# Handle device selection logic
if [ $_SELECT_USB -eq 1 ] && [ -n "$DEVICE" ]; then
    log "ERROR" "Cannot use both --select-usb (-u) and --device (-d) options together."
    exit $E_ARGS
elif [ $_SELECT_USB -eq 0 ] && [ -z "$DEVICE" ]; then
     log "ERROR" "Must specify a target device using --device (-d) or interactive selection with --select-usb (-u)."
     exit $E_ARGS
fi

# --- Initialization ---
# Initialize logging (handle potential path issues)
if [ -n "$LOG_FILE" ]; then
    # Attempt to make log file absolute path if not already
    if [[ "$LOG_FILE" != /* ]]; then LOG_FILE="$PWD/$LOG_FILE"; fi
    log_dir=$(dirname "$LOG_FILE")
    # Try creating directory, check for error
    if ! mkdir -p "$log_dir"; then
         echo "ERROR: Failed to create log directory '$log_dir'. Check permissions." >&2
         # Try logging to /tmp as fallback? Or just exit? Exit is safer.
         exit $E_LOG_FILE
    fi
    # Try touching file, check for error
    if ! touch "$LOG_FILE"; then
        echo "ERROR: Failed to create/touch log file '$LOG_FILE'. Check permissions." >&2
        exit $E_LOG_FILE
    fi
     # Clear log file at start? Optional.
     # > "$LOG_FILE"
    log "INFO" "--- Trim Setup Script v3.3 Started ---"
    log "INFO" "Logging enabled to file: $LOG_FILE"
else
    log "INFO" "--- Trim Setup Script v3.3 Started (Logging to console only) ---"
fi
log "DEBUG" "Initial Config: DEVICE='$DEVICE', SCHEDULE='$TIMER_SCHEDULE', AUTO_INSTALL=$AUTO_INSTALL, ENABLE_TIMER=$ENABLE_TIMER, SELECT_USB=$_SELECT_USB, VERBOSE=$VERBOSE"

# --- Pre-Checks ---
check_root
install_packages # Checks and potentially installs sg3-utils, lsscsi, usbutils, hdparm

# --- Device Selection/Validation ---
if [ $_SELECT_USB -eq 1 ]; then
    select_usb_device # Sets $DEVICE and $SELECTED_USB, VENDOR_ID, PRODUCT_ID
else
    # Validate the specified device
    log "INFO" "Using specified device: $DEVICE"
    if [[ ! -b "$DEVICE" ]]; then
        log "ERROR" "Device path '$DEVICE' is not a valid block device."
        exit $E_DEVICE_INVALID
    fi
    # Set DEVICE_NAME from DEVICE (extract just the name portion)
    DEVICE_NAME=${DEVICE##*/}
    DEVICE_NAME=${DEVICE_NAME%%[0-9]*} # Remove any partition numbers

    # Attempt to get USB IDs for the specified device
    local usb_id
    usb_id=$(get_usb_ids "$DEVICE") # Sets VENDOR_ID, PRODUCT_ID internally if found
    if [[ "$usb_id" != "unknown" ]]; then
        SELECTED_USB="$usb_id"
        log "INFO" "Detected USB ID for $DEVICE: $SELECTED_USB"
    else
        log "WARNING" "Could not determine USB ID for $DEVICE. Will create a generic udev rule."
        SELECTED_USB="unknown"
        VENDOR_ID="" # Ensure they are blank if unknown
        PRODUCT_ID=""
    fi
fi
log "DEBUG" "Proceeding with device: $DEVICE ($DEVICE_NAME), USB ID: $SELECTED_USB ($VENDOR_ID:$PRODUCT_ID)"

# --- Core Logic ---
check_trim_support       # Sets DEVICE_TRIM_SUPPORTED, DEVICE_MAX_UNMAP_LBA_COUNT. Exits if user aborts.
calculate_discard_max    # Sets DEVICE_DISCARD_MAX_BYTES
configure_trim           # Creates udev rule, reloads/triggers udev
configure_trim_timer     # Configures systemd timer if ENABLE_TIMER=1
test_trim                # Attempts fstrim test if device is mounted

# --- Final Summary ---
echo
echo -e "${BOLD}${GREEN}--- TRIM Configuration Summary (v3.3) ---${RESET}"
echo -e "${GRAY}==============================================${RESET}"
echo -e "Target Device:         ${BOLD}$DEVICE${RESET} (Kernel name: ${DEVICE_NAME})"
echo -e "USB Vendor:Product ID: ${BOLD}$SELECTED_USB${RESET}"

# Report TRIM Support Check Result
# Need to access the global variable set in check_trim_support if user aborted
if [ "$DEVICE_TRIM_SUPPORTED" -eq 1 ]; then
    echo -e "Firmware TRIM Support: ${GREEN}Detected${RESET} (Max LBA Count: $DEVICE_MAX_UNMAP_LBA_COUNT)"
else
    # Check if user decided to continue despite lack of support
    # Use the globally declared 'continue_anyway' variable
    if [[ -v continue_anyway && "$continue_anyway" =~ ^[Yy]$ ]]; then
        echo -e "Firmware TRIM Support: ${RED}Not Detected${RESET} - ${YELLOW}Proceeded at user request.${RESET}"
    else
         # This case means either not supported AND user aborted (script would have exited)
         # OR not supported and user chose 'N' (script would have exited)
         # OR the check somehow failed without prompting (shouldn't happen)
         # So if we reach here and support is 0, it must be the aborted case, but we didn't exit? Check logic.
         # If script reaches here and DEVICE_TRIM_SUPPORTED is 0, it means user *must* have typed Y/y.
         # Let's adjust the logic slightly for clarity.
         if [ -v continue_anyway ]; then # If the prompt was shown
             echo -e "Firmware TRIM Support: ${RED}Not Detected${RESET} - ${YELLOW}Proceeded at user request.${RESET}"
         else # Should not happen if check fails, but as a fallback
             echo -e "Firmware TRIM Support: ${RED}Not Detected${RESET}"
         fi
    fi
fi
echo -e "Calculated discard_max: ${BOLD}${DEVICE_DISCARD_MAX_BYTES}${RESET} bytes"

# Report udev Rule Status
if [ "$UDEV_RULE_CREATED" -eq 1 ]; then
     if [[ "$SELECTED_USB" != "unknown" && -n "$VENDOR_ID" && -n "$PRODUCT_ID" ]]; then
         echo -e "Persistent udev Rule:  ${GREEN}Created (USB ID Specific)${RESET}"
     else
         echo -e "Persistent udev Rule:  ${YELLOW}Created (Generic - by kernel name $DEVICE_NAME)${RESET}"
     fi
else
     echo -e "Persistent udev Rule:  ${RED}Failed to create${RESET} (See logs)"
fi

# Report Timer Status
if [ "$ENABLE_TIMER" -eq 1 ]; then
    # Re-check status for summary
    timer_active=$(systemctl is-active fstrim.timer 2>/dev/null || echo "error")
    timer_enabled=$(systemctl is-enabled fstrim.timer 2>/dev/null || echo "error")
    timer_sched=$(systemctl show -p Timers fstrim.timer 2>/dev/null | grep OnCalendar | cut -d= -f2- | head -n 1)

     if [[ "$timer_active" == "active" && "$timer_enabled" == "enabled" ]]; then
        echo -e "Periodic TRIM Timer:   ${GREEN}Enabled & Active${RESET} (Schedule: ${timer_sched:-$TIMER_SCHEDULE})"
     elif [[ "$timer_active" == "error" || "$timer_enabled" == "error" ]]; then
         echo -e "Periodic TRIM Timer:   ${RED}Error checking status${RESET} (Configured Schedule: $TIMER_SCHEDULE)"
     else
         # It might be enabled but inactive (will run on schedule)
         echo -e "Periodic TRIM Timer:   ${YELLOW}Configured${RESET} (Schedule: ${timer_sched:-$TIMER_SCHEDULE}) - Status: Active=${timer_active}, Enabled=${timer_enabled}"
     fi
else
    echo -e "Periodic TRIM Timer:   ${GRAY}Not Enabled (Use --enable-timer)${RESET}"
fi

# Report fstrim Test Result
if [ -n "$FOUND_MOUNTPOINT" ]; then # Only report if a mountpoint was found
    if [ "$FSTRIM_TEST_SUCCESS" -eq 1 ]; then
        echo -e "Runtime fstrim Test:   ${GREEN}Successful on $FOUND_MOUNTPOINT${RESET}"
    else
        echo -e "Runtime fstrim Test:   ${RED}Failed on $FOUND_MOUNTPOINT${RESET} (See logs/output above)"
    fi
else
    echo -e "Runtime fstrim Test:   ${GRAY}N/A (Device/Partitions not mounted)${RESET}"
fi

echo -e "${GRAY}==============================================${RESET}"
echo -e "${GREEN}${BOLD}Configuration steps completed.${RESET}"
echo
echo -e "${RED}${BOLD}=== IMPORTANT: REBOOT RECOMMENDED ===${RESET}"
echo -e "${YELLOW}A system reboot is ${BOLD}strongly recommended${RESET}${YELLOW} to ensure the udev rules are correctly"
echo -e "applied by the kernel and all system services.${RESET}"
echo
echo -e "${BOLD}After Reboot Verification Steps:${RESET}"
echo -e "1. ${BLUE}Check runtime discard setting:${RESET}"
echo -e "   cat /sys/block/${DEVICE_NAME}/queue/discard_max_bytes"
echo -e "   (Should ideally match calculated value: $DEVICE_DISCARD_MAX_BYTES, but might be capped by kernel/device)"
echo
echo -e "2. ${BLUE}Check runtime provisioning mode:${RESET}"
echo -e "   cat /sys/block/${DEVICE_NAME}/device/scsi_disk/*/provisioning_mode"
echo -e "   (Should show '${BOLD}unmap${RESET}' if path exists and rule worked. Path structure might vary.)"
echo
echo -e "3. ${BLUE}Run manual TRIM test (if mounted):${RESET}"
echo -e "   sudo fstrim -v /path/to/mountpoint"
echo -e "   (Replace with actual mount point, e.g., from 'lsblk')"
echo
echo -e "4. ${BLUE}Check fstrim timer status (if enabled):${RESET}"
echo -e "   systemctl status fstrim.timer"
echo -e "   journalctl -u fstrim.timer"
echo

log "INFO" "--- Trim Setup Script Finished ---"
exit $E_SUCCESS
