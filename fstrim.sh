#!/bin/bash

# Script to Setup and Configure TRIM (Discard) Support for External USB SSDs
# Usage: sudo ./setup-trim-final.sh [options]
# Author: AmirulAndalib (Revised extensively based on feedback & best practices)
# Version: 3.0 (Production Candidate)
# Last Updated: 2025-04-06

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
TIMER_SCHEDULE="$DEFAULT_TIMER_SCHEDULE"
AUTO_INSTALL=0
SELECTED_USB="unknown" # Holds vendor:product ID or "unknown"
VERBOSE=0
LOG_FILE=""
ENABLE_TIMER=0
DEVICE_TRIM_SUPPORTED=0 # 0=No/Unknown, 1=Yes
DEVICE_MAX_UNMAP_LBA_COUNT=0
DEVICE_DISCARD_MAX_BYTES=0

# --- ANSI Color Codes ---
RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
BLUE="\e[34m"
GRAY="\e[90m"
BOLD="\e[1m"
RESET="\e[0m"

# --- Logging Function ---
# Levels: TRACE, DEBUG, INFO, SUCCESS, WARNING, ERROR
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
        if [[ "$level" != "TRACE" || "$VERBOSE" -gt 1 ]]; then # Log TRACE only if super verbose maybe? For now, just verbose.
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
    echo -e "${BOLD}External SSD TRIM Configuration Tool (v3.0)${RESET}"
    echo
    echo "Usage: sudo $0 [options]"
    echo
    echo "Configures TRIM (discard/unmap) for external USB SSDs by checking firmware support,"
    echo "creating persistent udev rules, and optionally enabling the systemd fstrim timer."
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
    echo "Example (Interactive): sudo $0 --select-usb --auto --enable-timer -v --log /var/log/trim_setup.log"
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
    local cmd_to_pkg=()
    # Create associative array mapping command to typical package name
    declare -A cmd_to_pkg=(
        [sg_vpd]="sg3-utils" [sg_readcap]="sg3-utils" [lsscsi]="lsscsi"
        [lsusb]="usbutils" [hdparm]="hdparm" [lsblk]="util-linux"
        [fstrim]="util-linux" [udevadm]="systemd" [systemctl]="systemd" # systemd/util-linux usually core packages
    )
    # Adjust for alternative names (e.g., dnf/yum)
    if command -v dnf &> /dev/null || command -v yum &> /dev/null; then
        cmd_to_pkg[sg_vpd]="sg3_utils"
        cmd_to_pkg[sg_readcap]="sg3_utils"
    fi

    log "INFO" "Checking for required commands..."
    for cmd in "${required_cmds[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            log "WARNING" "Required command not found: $cmd (Package: ${cmd_to_pkg[$cmd]})"
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
         pkg=${cmd_to_pkg[$cmd]}
         # Avoid adding core packages like systemd/util-linux unless essential command missing
         if [[ "$pkg" == "systemd" || "$pkg" == "util-linux" ]]; then
              log "ERROR" "Core command '$cmd' from package '$pkg' is missing. This indicates a broken base system. Cannot proceed."
              exit $E_PKG_MISSING
         fi
         # Add package if not already in the list
         if [[ -n "$pkg" && ! " ${packages_to_install[@]} " =~ " $pkg " ]]; then
             packages_to_install+=("$pkg")
         fi
     done

    if [ ${#packages_to_install[@]} -eq 0 ]; then
         log "INFO" "No installable packages identified for missing commands (likely core components)."
         # If only core components were missing, we would have exited above.
         # This path might be hit if mapping is incomplete. Assume user needs to fix manually.
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
        if $update_cmd &> "$LOG_FILE.install_update.log"; then
             log "DEBUG" "Package list update successful."
        else
             log "WARNING" "Package list update failed (exit code $?). Check $LOG_FILE.install_update.log. Continuing install attempt..."
        fi
    fi

    # Install packages
    log "INFO" "Installing packages: ${packages_to_install[*]}"
    if $install_cmd "${packages_to_install[@]}" &> "$LOG_FILE.install_packages.log"; then
         log "SUCCESS" "Packages installed successfully."
    else
         log "ERROR" "Failed to install packages (exit code $?). Check $LOG_FILE.install_packages.log."
         log "ERROR" "Please install manually: ${packages_to_install[*]}"
         exit $E_PKG_INSTALL
    fi

    # Verify commands again after installation
    for cmd in "${missing_cmds[@]}"; do
         pkg=${cmd_to_pkg[$cmd]}
          # Skip verification for core packages handled earlier
         if [[ "$pkg" == "systemd" || "$pkg" == "util-linux" ]]; then continue; fi

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
    local base_dev_path="/dev/${dev_path##*/}"
    base_dev_path=${base_dev_path%%[0-9]*} # Remove trailing numbers

    if udev_info=$(udevadm info --query=property --name="$base_dev_path" 2>/dev/null); then
        vendor_id=$(echo "$udev_info" | grep -E '^ID_VENDOR_ID=' | head -n1 | cut -d= -f2)
        product_id=$(echo "$udev_info" | grep -E '^ID_MODEL_ID=' | head -n1 | cut -d= -f2)
        if [[ "$vendor_id" =~ ^[0-9a-fA-F]{4}$ && "$product_id" =~ ^[0-9a-fA-F]{4}$ ]]; then
            ids="${vendor_id}:${product_id}"
            log "DEBUG" "Found USB IDs via udevadm: $ids"
            echo "$ids"; return 0
        else
             log "TRACE" "udevadm did not provide valid Vendor/Product IDs. Vendor='$vendor_id', Product='$product_id'"
        fi
    else
         log "TRACE" "udevadm info command failed for $base_dev_path (Exit code $?)"
    fi

     # Method 2: sysfs path traversal (More fragile)
    local dev_name=${dev_path##*/}
    dev_name=${dev_name%%[0-9]*} # Use base device name
    local sys_dev_link="/sys/class/block/$dev_name"
    log "TRACE" "Trying sysfs traversal from $sys_dev_link"
    if [[ -L "$sys_dev_link" ]]; then
        local current_path
        current_path=$(readlink -f "$sys_dev_link")
        while [[ "$current_path" != "/" && "$current_path" != "/sys" && "$current_path" != "." ]]; do
            # Look for idVendor/idProduct files in the current directory path component
            if [[ -f "$current_path/idVendor" && -f "$current_path/idProduct" ]]; then
                vendor_id=$(cat "$current_path/idVendor" 2>/dev/null)
                product_id=$(cat "$current_path/idProduct" 2>/dev/null)
                 if [[ "$vendor_id" =~ ^[0-9a-fA-F]{4}$ && "$product_id" =~ ^[0-9a-fA-F]{4}$ ]]; then
                     ids="${vendor_id}:${product_id}"
                     log "DEBUG" "Found USB IDs via sysfs traversal at $current_path: $ids"
                     echo "$ids"; return 0
                 fi
            fi
            # Check one level up in case they are in the parent (common for USB interfaces)
            local parent_path=$(dirname "$current_path")
             if [[ -f "$parent_path/idVendor" && -f "$parent_path/idProduct" ]]; then
                 vendor_id=$(cat "$parent_path/idVendor" 2>/dev/null)
                 product_id=$(cat "$parent_path/idProduct" 2>/dev/null)
                 if [[ "$vendor_id" =~ ^[0-9a-fA-F]{4}$ && "$product_id" =~ ^[0-9a-fA-F]{4}$ ]]; then
                     ids="${vendor_id}:${product_id}"
                     log "DEBUG" "Found USB IDs via sysfs traversal at parent $parent_path: $ids"
                     echo "$ids"; return 0
                 fi
             fi
            current_path=$(dirname "$current_path") # Go up one level
        done
        log "TRACE" "sysfs traversal did not yield IDs."
    else
         log "TRACE" "Could not resolve sysfs link $sys_dev_link"
    fi

    # Method 3: lsusb and lsscsi matching (Least reliable)
    log "TRACE" "Trying lsusb/lsscsi matching for $dev_name"
    local scsi_info model vendor
    if scsi_info=$(lsscsi | grep "$dev_name" | head -n 1); then
        model=$(echo "$scsi_info" | awk '{for (i=3; i<NF-1; i++) printf $i " "; print $(NF-1)}' | sed 's/ *$//') # Extract model name fields
        vendor=$(echo "$scsi_info" | awk '{print $2}') # Extract vendor field
        log "TRACE" "lsscsi info: Vendor='$vendor', Model='$model'"
        if [[ -n "$vendor" || -n "$model" ]]; then
             while IFS= read -r line; do
                  local usb_id=""
                  usb_id=$(echo "$line" | grep -o 'ID [[:xdigit:]]\{4\}:[[:xdigit:]]\{4\}' | awk '{print $2}')
                  if [[ -n "$usb_id" ]]; then
                      # Simple match: check if vendor OR model appears in the lsusb description
                      if ( [[ -n "$vendor" && "$line" == *"$vendor"* ]] || [[ -n "$model" && "$line" == *"$model"* ]] ); then
                           log "DEBUG" "Found potential USB ID match via lsusb/lsscsi: $usb_id (Matched on Vendor/Model string)"
                           echo "$usb_id"; return 0
                      fi
                  fi
             done < <(lsusb)
        fi
    else
        log "TRACE" "lsscsi provided no info for $dev_name"
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
    local line devname tran model vendor size

    # Use lsblk to find devices with transport type "usb"
    # Output format: NAME SIZE VENDOR MODEL TRAN (ensure these columns exist)
    while IFS= read -r line; do
        devname=$(echo "$line" | awk '{print $1}')
        tran=$(echo "$line" | awk '{print $NF}')
        if [[ "$tran" == "usb" && -b "$devname" ]]; then
            # Exclude partitions (e.g., sda1, sdb2) and read-only devices
            if [[ ! "$devname" =~ [0-9]$ ]] && [ "$(lsblk -ndo RO "$devname")" = "0" ]; then
                 devices_found+=("$devname")
                 device_lines+=("$line")
                 log "TRACE" "Found potential USB device: $line"
            fi
        fi
    done < <(lsblk -dpno NAME,SIZE,VENDOR,MODEL,TRAN | sort)

    if [ ${#devices_found[@]} -eq 0 ]; then
        log "ERROR" "No suitable USB block devices found (must be non-partition, writable, type USB)."
        exit $E_DEVICE_NOT_FOUND
    fi

    echo -e "\n${BOLD}Available USB Block Devices:${RESET}"
    echo "---------------------------------"
    printf "%-4s %-15s %-10s %-15s %-s\n" "Num" "Device" "Size" "Vendor" "Model"
    echo "---------------------------------"
    for i in "${!devices_found[@]}"; do
        devname=$(echo "${device_lines[$i]}" | awk '{print $1}')
        size=$(echo "${device_lines[$i]}" | awk '{print $2}')
        vendor=$(echo "${device_lines[$i]}" | awk '{print $3}')
        model=$(echo "${device_lines[$i]}" | awk '{print $4}')
        printf "%-4s %-15s %-10s %-15s %-s\n" "$((i+1))." "$devname" "$size" "$vendor" "$model"
    done
    echo "---------------------------------"

    local selection
    while true; do
        read -p "Select device number (1-${#devices_found[@]}): " selection
        if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le "${#devices_found[@]}" ]; then
            DEVICE="${devices_found[$((selection-1))]}"
            log "INFO" "Selected device: $DEVICE (${device_lines[$((selection-1))]})"
            SELECTED_USB=$(get_usb_ids "$DEVICE") # Attempt to get USB IDs
            if [[ "$SELECTED_USB" == "unknown" ]]; then
                 echo
                 echo -e "${YELLOW}Could not automatically determine USB vendor and product IDs for $DEVICE.${RESET}"
                 echo -e "You can try 'lsusb' in another terminal to find the ${BOLD}ID xxxx:xxxx${RESET} value."
                 read -p "Enter the vendor:product ID (e.g., 1b1c:1a0e, leave blank to skip): " manual_usb_id
                 if [[ "$manual_usb_id" =~ ^[0-9a-fA-F]{4}:[0-9a-fA-F]{4}$ ]]; then
                     SELECTED_USB="$manual_usb_id"
                     log "INFO" "Using manually entered USB ID: $SELECTED_USB"
                 else
                     log "WARNING" "Invalid or no manual USB ID entered. Will create a generic udev rule."
                     SELECTED_USB="unknown" # Ensure it's marked unknown
                 fi
            fi
            log "DEBUG" "Final USB ID for $DEVICE: $SELECTED_USB"
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
    log "DEBUG" "Running: sg_vpd -p bl \"$DEVICE\""
    local sg_vpd_bl_output
    sg_vpd_bl_output=$(sg_vpd -p bl "$DEVICE" 2>&1)
    local sg_vpd_bl_status=$?
    if [ $sg_vpd_bl_status -ne 0 ]; then
        log "WARNING" "sg_vpd -p bl command failed (Exit code $sg_vpd_bl_status). Cannot determine Max Unmap LBA count."
        log "TRACE" "sg_vpd -p bl output: $sg_vpd_bl_output"
    else
        log "TRACE" "sg_vpd -p bl output:\n$sg_vpd_bl_output"
        local count_str
        # Extract number after "Maximum unmap LBA count:"
        count_str=$(echo "$sg_vpd_bl_output" | grep -i "Maximum unmap LBA count:" | sed -n 's/.*:\s*\([0-9]\+\).*/\1/p')
        if [[ "$count_str" =~ ^[0-9]+$ ]]; then
            DEVICE_MAX_UNMAP_LBA_COUNT=$count_str
        else
            log "WARNING" "Could not parse numeric value for 'Maximum unmap LBA count' from sg_vpd output."
            DEVICE_MAX_UNMAP_LBA_COUNT=0
        fi
    fi
    log "DEBUG" "Reported Maximum unmap LBA count: $DEVICE_MAX_UNMAP_LBA_COUNT"

    # Check Unmap command supported (LBPU) using sg_vpd Logical Block Provisioning page (-p lbpv)
    log "DEBUG" "Running: sg_vpd -p lbpv \"$DEVICE\""
    local sg_vpd_lbpv_output
    sg_vpd_lbpv_output=$(sg_vpd -p lbpv "$DEVICE" 2>&1)
    local sg_vpd_lbpv_status=$?
    local lbpu_supported=0 # Assume not supported unless proven otherwise
    if [ $sg_vpd_lbpv_status -ne 0 ]; then
        log "WARNING" "sg_vpd -p lbpv command failed (Exit code $sg_vpd_lbpv_status). Cannot determine LBPU status."
        log "TRACE" "sg_vpd -p lbpv output: $sg_vpd_lbpv_output"
    else
        log "TRACE" "sg_vpd -p lbpv output:\n$sg_vpd_lbpv_output"
        # Look for the line like "Unmap command supported (LBPU): 1"
        if echo "$sg_vpd_lbpv_output" | grep -q "Unmap command supported (LBPU): *1"; then
            lbpu_supported=1
        elif echo "$sg_vpd_lbpv_output" | grep -q "Unmap command supported (LBPU): *0"; then
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
        hdparm_output=$(hdparm -I "$DEVICE" 2>&1)
        local hdparm_status=$?
        if [ $hdparm_status -ne 0 ]; then
             log "WARNING" "hdparm -I command failed (Exit code $hdparm_status). Cannot verify via hdparm."
             log "TRACE" "hdparm output: $hdparm_output"
        elif echo "$hdparm_output" | grep -q "Data Set Management TRIM supported"; then
             log "INFO" "TRIM support indicated by hdparm (Data Set Management)."
             hdparm_supported=1
        else
             log "INFO" "TRIM support not indicated by hdparm."
             log "TRACE" "hdparm -I output:\n$hdparm_output"
        fi
    fi

    # --- Final Decision Logic ---
    # Consider supported if LBPU is 1 AND max unmap count > 0, OR if hdparm reported support
    if [[ "$lbpu_supported" -eq 1 && "$DEVICE_MAX_UNMAP_LBA_COUNT" -gt 0 ]] || [[ "$hdparm_supported" -eq 1 ]]; then
        log "SUCCESS" "Device $DEVICE appears to support TRIM/Unmap/Discard commands."
        DEVICE_TRIM_SUPPORTED=1
        # If primary check failed but hdparm succeeded, use a default non-zero LBA count for discard_max calc
        if [[ "$DEVICE_MAX_UNMAP_LBA_COUNT" -eq 0 && "$hdparm_supported" -eq 1 ]]; then
             log "WARNING" "Using default Max Unmap LBA Count (4194240) for calculation as sg_vpd failed but hdparm detected support."
             DEVICE_MAX_UNMAP_LBA_COUNT=4194240 # Common large value (approx 2GB with 512b blocks)
        fi
    else
        log "ERROR" "Device $DEVICE does not appear to support TRIM/Unmap/Discard based on sg_vpd and hdparm checks."
        DEVICE_TRIM_SUPPORTED=0
        echo -e "\n${RED}${BOLD}WARNING:${RESET} ${RED}TRIM (discard/unmap) commands do not appear to be supported by this device's firmware or the USB adapter.${RESET}"
        echo -e "${YELLOW}Configuring TRIM may have no effect or, in rare cases, cause issues.${RESET}"
        echo -e "${YELLOW}Make sure you have backups of any important data on this drive.${RESET}"
        read -p "Do you want to continue anyway and create the configuration? (y/N): " continue_anyway
        if [[ ! "$continue_anyway" =~ ^[Yy]$ ]]; then
            log "INFO" "User aborted due to lack of detected TRIM support."
            exit $E_TRIM_UNSUPPORTED_ABORT
        fi
        log "WARNING" "User chose to continue despite lack of detected TRIM support. Proceeding with configuration."
        # Use a default non-zero count if we proceed, otherwise discard_max_bytes calculation yields 0
        if [[ "$DEVICE_MAX_UNMAP_LBA_COUNT" -eq 0 ]]; then
             DEVICE_MAX_UNMAP_LBA_COUNT=4194240
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
    log "DEBUG" "Running: sg_readcap -l \"$DEVICE\""
    local sg_readcap_output
    sg_readcap_output=$(sg_readcap -l "$DEVICE" 2>&1)
    local sg_readcap_status=$?
    if [ $sg_readcap_status -ne 0 ]; then
        log "WARNING" "sg_readcap command failed (Exit code $sg_readcap_status). Using default block size 512."
        log "TRACE" "sg_readcap output: $sg_readcap_output"
    else
        log "TRACE" "sg_readcap output:\n$sg_readcap_output"
        local detected_bs_str
        # Extract number after "Logical block length="
        detected_bs_str=$(echo "$sg_readcap_output" | grep -i "Logical block length=" | sed -n 's/.*=\s*\([0-9]\+\).*/\1/p')
        if [[ "$detected_bs_str" =~ ^[0-9]+$ ]] && [ "$detected_bs_str" -gt 0 ]; then
            block_size=$detected_bs_str
        else
            log "WARNING" "Could not parse valid block size from sg_readcap. Using default: 512."
        fi
    fi
    log "DEBUG" "Using block size: $block_size bytes"

    # Calculate discard_max_bytes = LBA count * block size
    if [[ "$DEVICE_MAX_UNMAP_LBA_COUNT" -gt 0 ]]; then
        DEVICE_DISCARD_MAX_BYTES=$((DEVICE_MAX_UNMAP_LBA_COUNT * block_size))
    else
        # If firmware doesn't support it or count is 0, set discard_max_bytes to 0
        DEVICE_DISCARD_MAX_BYTES=0
        log "WARNING" "Max Unmap LBA count is 0. Setting discard_max_bytes to 0 (effectively disabling discard limits)."
    fi

    log "INFO" "Calculated discard_max_bytes: $DEVICE_DISCARD_MAX_BYTES"
}

# Sets runtime values (best effort) and creates persistent udev rule
configure_trim() {
    log "INFO" "Applying TRIM configuration for $DEVICE..."
    local device_name=${DEVICE##*/} # e.g., sda, sdb (no partition)
    device_name=${device_name%%[0-9]*} # Ensure it's the base device name
    local discard_max=$DEVICE_DISCARD_MAX_BYTES

    # 1. Set runtime values (best effort for immediate effect/testing - udev rule is primary)
    # Note: These might fail if permissions are strict or paths don't exist yet.
    log "INFO" "Attempting to set runtime values (best effort)..."
    local prov_path="/sys/block/$device_name/device/scsi_disk/"*"/provisioning_mode" # Globbing
    local discard_path="/sys/block/$device_name/queue/discard_max_bytes"

    local found_prov_path=""
    for p in $prov_path; do
        if [ -f "$p" ]; then
            found_prov_path="$p"
            log "DEBUG" "Found provisioning_mode path for runtime setting: $found_prov_path"
            log "TRACE" "Setting $found_prov_path to 'unmap'"
            echo "unmap" > "$found_prov_path" || log "WARNING" "Failed to write 'unmap' to $found_prov_path"
            break # Use the first one found
        fi
    done
    if [ -z "$found_prov_path" ]; then log "WARNING" "Could not find runtime provisioning_mode path."; fi

    if [ -f "$discard_path" ]; then
         log "TRACE" "Setting $discard_path to '$discard_max'"
         echo "$discard_max" > "$discard_path" || log "WARNING" "Failed to write '$discard_max' to $discard_path"
    else
        log "WARNING" "Runtime discard_max_bytes path not found: $discard_path"
    fi

    # 2. Create persistent udev rule
    log "INFO" "Creating persistent udev rule..."

    # Ensure udev directory exists
    if ! mkdir -p "$UDEV_RULE_DIR"; then
        log "ERROR" "Failed to create udev rules directory: $UDEV_RULE_DIR"
        exit $E_UDEV_RULE
    fi
    log "TRACE" "Udev rule directory verified: $UDEV_RULE_DIR"

    local rule_file=""
    local rule_content=""
    local vendor_id=""
    local product_id=""

    # If we have a specific USB ID, use it for a targeted rule
    if [[ "$SELECTED_USB" != "unknown" ]]; then
        vendor_id=$(echo "$SELECTED_USB" | cut -d: -f1)
        product_id=$(echo "$SELECTED_USB" | cut -d: -f2)
        rule_file="$UDEV_RULE_DIR/10-usb-ssd-trim-${vendor_id}-${product_id}.rules"
        log "INFO" "Creating USB ID specific udev rule: $rule_file"

        # Use ENV variables populated by udev based on device discovery
        # KERNEL=="sd*[!0-9]" matches whole block devices (sda, sdb, not sda1)
        # SUBSYSTEM=="block" for discard_max_bytes attribute
        # SUBSYSTEM=="scsi_disk" for provisioning_mode attribute
        rule_content=$(cat << EOF
# Udev rule generated by setup-trim-final.sh for USB SSD ${vendor_id}:${product_id}
# Target Device Hint (at generation time): $DEVICE
# Rule 1: Set discard_max_bytes on the block device matching the USB ID
ACTION=="add|change", SUBSYSTEM=="block", KERNEL=="sd*[!0-9]", ENV{ID_VENDOR_ID}=="$vendor_id", ENV{ID_MODEL_ID}=="$product_id", ATTR{queue/discard_max_bytes}="$discard_max"

# Rule 2: Set provisioning_mode on the underlying scsi_disk device matching the USB ID
ACTION=="add|change", SUBSYSTEM=="scsi_disk", ENV{ID_VENDOR_ID}=="$vendor_id", ENV{ID_MODEL_ID}=="$product_id", ATTR{provisioning_mode}="unmap"
EOF
)
    else
        # Fallback to generic rule based on kernel name (less reliable)
        log "WARNING" "USB Vendor/Product ID unavailable. Creating generic udev rule based on kernel name ($device_name)."
        log "WARNING" "This generic rule (${BOLD}$device_name${RESET}) might unintentionally affect other devices if kernel names change or are reused."
        rule_file="$UDEV_RULE_DIR/11-generic-ssd-trim-${device_name}.rules"
        log "INFO" "Creating generic udev rule: $rule_file"

        # This rule matches only the specific kernel name (e.g., sda)
        # Setting provisioning_mode via RUN+ is less ideal but necessary without IDs
        # ATTR{...} is preferred when possible.
        rule_content=$(cat << EOF
# Generic Udev rule generated by setup-trim-final.sh for device $device_name
# WARNING: This rule is based on kernel name and might affect other devices if names change.
# Rule 1: Set discard_max_bytes on the block device
ACTION=="add|change", SUBSYSTEM=="block", KERNEL=="$device_name", ATTR{queue/discard_max_bytes}="$discard_max"

# Rule 2: Attempt to set provisioning_mode using RUN command (best effort for generic rule)
# Tries to find the correct path under /sys/block/%k/device/scsi_disk/*/provisioning_mode
ACTION=="add|change", SUBSYSTEM=="block", KERNEL=="$device_name", RUN+="/bin/sh -c 'for p in /sys/block/%k/device/scsi_disk/*/provisioning_mode; do [ -f \"\$p\" ] && echo unmap > \"\$p\"; done'"
EOF
)
    fi

    # Write the rule file
    log "DEBUG" "Writing udev rule content to $rule_file"
    log "TRACE" "Rule content:\n$rule_content"
    if echo -e "$rule_content" > "$rule_file"; then
        log "SUCCESS" "Created udev rule: $rule_file"
    else
        log "ERROR" "Failed to write udev rule file: $rule_file (Exit code $?)"
        exit $E_UDEV_RULE
    fi

    # Reload udev rules
    log "INFO" "Reloading udev rules (udevadm control --reload-rules)..."
    if udevadm control --reload-rules; then
        log "DEBUG" "udevadm control --reload-rules completed successfully."
    else
        log "WARNING" "Failed to reload udev rules (Exit code $?). Rules will likely only apply after reboot or replug."
        # Don't exit, as the rule file might still be valid.
    fi
    log "INFO" "Udev rule created/updated. Reboot is recommended for reliable application."
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
    local timer_override_file="$timer_override_dir/99-trim-script-override.conf" # Use number prefix and descriptive name

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
    local override_content
    override_content=$(cat << EOF
# Systemd override file generated by setup-trim-final.sh
# Sets the schedule for the main fstrim.timer unit.
[Unit]
Description=Periodic TRIM of Filesystems (schedule configured by setup-trim-final.sh)

[Timer]
OnCalendar=
OnCalendar=$TIMER_SCHEDULE
AccuracySec=1h
Persistent=true
# RandomizeDelaySec=600 # Optional: Add random delay up to 10 mins
EOF
)
    log "TRACE" "Override content:\n$override_content"
    if ! echo -e "$override_content" > "$timer_override_file"; then
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

    log "INFO" "Enabling $timer_unit..."
    if ! systemctl enable "$timer_unit"; then
         log "WARNING" "Failed to enable $timer_unit (Exit code $?). It might be masked or another issue occurred."
         # Don't exit, maybe start still works or user can fix manually
    fi

    log "INFO" "Starting $timer_unit..."
    if ! systemctl start "$timer_unit"; then
         log "WARNING" "Failed to start $timer_unit (Exit code $?). Check 'systemctl status $timer_unit' and 'journalctl -u $timer_unit'."
    fi

    # Check final status
    sleep 1 # Give systemd a moment
    local timer_active timer_enabled
    timer_active=$(systemctl is-active "$timer_unit" 2>/dev/null || echo "failed-read")
    timer_enabled=$(systemctl is-enabled "$timer_unit" 2>/dev/null || echo "failed-read")

    if [[ "$timer_active" == "active" && "$timer_enabled" == "enabled" ]]; then
        log "SUCCESS" "$timer_unit is now active and enabled with schedule: $TIMER_SCHEDULE"
    else
        log "WARNING" "Could not fully activate/enable $timer_unit."
        log "WARNING" "Current state - Active: $timer_active, Enabled: $timer_enabled"
        log "WARNING" "Review systemd status: 'systemctl status $timer_unit' and logs: 'journalctl -u $timer_unit'"
    fi
}

# Attempts to run fstrim on mounted filesystems related to the device
test_trim() {
    log "INFO" "Attempting to test TRIM using fstrim..."

    local test_mount_point=""
    # Find mount points associated with the base device (e.g., sda, sda1, sda2...)
    log "DEBUG" "Searching for mount points related to $DEVICE..."
    local base_device_name=${DEVICE##*/}
    base_device_name=${base_device_name%%[0-9]*} # e.g. sda from sda1

    # Use lsblk to find mountpoints for the device and its partitions
    local mount_points
    mount_points=$(lsblk -no MOUNTPOINT "/dev/$base_device_name" 2>/dev/null | grep -v '^$' | head -n 1) # Find first non-empty mountpoint

    if [ -n "$mount_points" ]; then
         test_mount_point="$mount_points"
         log "INFO" "Found related mounted filesystem at $test_mount_point. Testing TRIM there."
    else
         log "INFO" "Device $DEVICE (or its partitions) does not appear to be mounted."
         log "INFO" "Cannot perform specific fstrim test. Test manually after mounting:"
         log "INFO" "  sudo mount $DEVICE /mnt/my_ssd"
         log "INFO" "  sudo fstrim -v /mnt/my_ssd"
         return 0 # Not an error, just can't test directly
    fi

    # Run fstrim in verbose mode on the found mount point
    log "DEBUG" "Running: fstrim -v \"$test_mount_point\""
    local fstrim_output fstrim_status
    fstrim_output=$(fstrim -v "$test_mount_point" 2>&1)
    fstrim_status=$?

    if [ $fstrim_status -eq 0 ]; then
        log "SUCCESS" "fstrim test successful on $test_mount_point."
        log "INFO" "Output: $fstrim_output"
        return 0
    else
        # Check for common "discard operation is not supported" error
        if echo "$fstrim_output" | grep -q "the discard operation is not supported"; then
            log "ERROR" "fstrim test FAILED on $test_mount_point: The discard operation is not supported."
            log "ERROR" "Possible Reasons:"
            log "ERROR" "  1. Filesystem Type: The filesystem on $test_mount_point (check with 'lsblk -f $DEVICE') does not support TRIM."
            log "ERROR" "  2. Mount Options: The filesystem was not mounted with the 'discard' option (if required by FS type or for continuous TRIM)."
            log "ERROR" "  3. Device/Adapter Issue: TRIM commands are still not passing through correctly despite earlier checks/rules (reboot might be needed)."
            log "INFO" "Periodic TRIM via fstrim.timer (recommended) does NOT require the 'discard' mount option."
            log "INFO" "If the timer is enabled, it should work after a reboot if the device truly supports TRIM."
        else
            log "ERROR" "fstrim test FAILED on $test_mount_point (Exit code: $fstrim_status)."
            log "ERROR" "Output: $fstrim_output"
            log "ERROR" "Check filesystem integrity, mount status, and system logs ('dmesg', 'journalctl')."
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
VALID_ARGS=$(getopt -o d:t:aeuvl:h --long device:,timer:,auto,enable-timer,select-usb,verbose,log:,help -- "$@")
if [[ $? -ne 0 ]]; then
    echo "Invalid arguments." >&2
    show_help
    exit $E_ARGS;
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
    # Use tee to log stdout/stderr to file *and* console if verbose
    # exec > >(tee -a "$LOG_FILE") 2> >(tee -a "$LOG_FILE" >&2) # This can be complex; manual logging preferred.
    log "INFO" "--- Trim Setup Script v3.0 Started ---"
    log "INFO" "Logging enabled to file: $LOG_FILE"
else
    log "INFO" "--- Trim Setup Script v3.0 Started (Logging to console only) ---"
fi
log "DEBUG" "Initial Config: DEVICE='$DEVICE', SCHEDULE='$TIMER_SCHEDULE', AUTO_INSTALL=$AUTO_INSTALL, ENABLE_TIMER=$ENABLE_TIMER, SELECT_USB=$_SELECT_USB, VERBOSE=$VERBOSE"

# --- Pre-Checks ---
check_root
install_packages # Checks and potentially installs sg3-utils, lsscsi, usbutils, hdparm

# --- Device Selection/Validation ---
if [ $_SELECT_USB -eq 1 ]; then
    select_usb_device # Sets $DEVICE and $SELECTED_USB
else
    # Validate the specified device
    log "INFO" "Using specified device: $DEVICE"
    if [[ ! -b "$DEVICE" ]]; then
        log "ERROR" "Device path '$DEVICE' is not a valid block device."
        exit $E_DEVICE_INVALID
    fi
    # Attempt to get USB IDs for the specified device
    SELECTED_USB=$(get_usb_ids "$DEVICE")
    if [[ "$SELECTED_USB" == "unknown" ]]; then
        log "WARNING" "Could not determine USB ID for $DEVICE. Will create a generic udev rule."
    else
         log "INFO" "Detected USB ID for $DEVICE: $SELECTED_USB"
    fi
fi
log "DEBUG" "Proceeding with device: $DEVICE, USB ID: $SELECTED_USB"

# --- Core Logic ---
check_trim_support       # Sets DEVICE_TRIM_SUPPORTED, DEVICE_MAX_UNMAP_LBA_COUNT. Exits if user aborts.
calculate_discard_max    # Sets DEVICE_DISCARD_MAX_BYTES
configure_trim           # Creates udev rule, sets runtime values (best effort)
configure_trim_timer     # Configures systemd timer if ENABLE_TIMER=1
test_trim                # Attempts fstrim test if device is mounted

# --- Final Summary ---
echo
echo -e "${BOLD}${GREEN}--- TRIM Configuration Summary ---${RESET}"
echo -e "${GRAY}==============================================${RESET}"
echo -e " Target Device:         ${BOLD}$DEVICE${RESET}"
echo -e " USB Vendor:Product ID: ${BOLD}${SELECTED_USB}${RESET}"

# Report TRIM Support Check Result
if [[ "$DEVICE_TRIM_SUPPORTED" -eq 1 ]]; then
    echo -e " Firmware TRIM Support: ${GREEN}Detected${RESET} (Max LBA Count: $DEVICE_MAX_UNMAP_LBA_COUNT)"
else
    # Check if user decided to continue despite lack of support
    if grep -q "User chose to continue despite lack of detected TRIM support" <<< "$(log INFO '')"; then # Hacky way to check log history? Better to use a flag. Let's assume if SUPPORTED=0 we should mention it.
        echo -e " Firmware TRIM Support: ${RED}Not Detected (or check failed)${RESET} - ${YELLOW}Proceeded at user request.${RESET}"
    else
         echo -e " Firmware TRIM Support: ${RED}Not Detected (or check failed)${RESET}"
    fi
fi
echo -e " Calculated discard_max: ${BOLD}${DEVICE_DISCARD_MAX_BYTES}${RESET} bytes"

# Report udev Rule Status
if grep -q "Created udev rule:" <<< "$(log SUCCESS '')"; then # Check log if rule creation was successful
     if [[ "$SELECTED_USB" != "unknown" ]]; then
         echo -e " Persistent udev Rule:  ${GREEN}Created (USB ID Specific)${RESET}"
     else
         echo -e " Persistent udev Rule:  ${YELLOW}Created (Generic - by kernel name $device_name)${RESET}"
     fi
else
     echo -e " Persistent udev Rule:  ${RED}Failed to create${RESET} (See logs)"
fi

# Report Timer Status
if [ "$ENABLE_TIMER" -eq 1 ]; then
    timer_active=$(systemctl is-active fstrim.timer 2>/dev/null || echo "error")
    timer_enabled=$(systemctl is-enabled fstrim.timer 2>/dev/null || echo "error")
     if [[ "$timer_active" == "active" && "$timer_enabled" == "enabled" ]]; then
        echo -e " Periodic TRIM Timer:   ${GREEN}Enabled & Active (Schedule: $TIMER_SCHEDULE)${RESET}"
     elif [[ "$timer_active" == "error" || "$timer_enabled" == "error" ]]; then
         echo -e " Periodic TRIM Timer:   ${RED}Error checking status${RESET} (Schedule: $TIMER_SCHEDULE)"
     else
         echo -e " Periodic TRIM Timer:   ${YELLOW}Configured (Schedule: $TIMER_SCHEDULE) - Status: $timer_active, Enabled: $timer_enabled${RESET}"
         echo -e "                       ${YELLOW}(Verify status after reboot)${RESET}"
     fi
else
    echo -e " Periodic TRIM Timer:   ${GRAY}Not Enabled (Use --enable-timer)${RESET}"
fi

# Report fstrim Test Result
# Check logs for success/failure message from test_trim
fstrim_test_result="N/A (Device not mounted?)"
if grep -q "fstrim test successful on" <<< "$(log SUCCESS '')"; then
    fstrim_test_result="${GREEN}Successful (on mounted filesystem)${RESET}"
elif grep -q "fstrim test FAILED on" <<< "$(log ERROR '')"; then
    fstrim_test_result="${RED}Failed (on mounted filesystem - see logs)${RESET}"
fi
echo -e " Runtime fstrim Test:   $fstrim_test_result"


echo -e "${GRAY}==============================================${RESET}"
echo -e "${GREEN}${BOLD}Configuration steps completed.${RESET}"
echo
echo -e "${RED}${BOLD}=== IMPORTANT: REBOOT REQUIRED ===${RESET}"
echo -e "${YELLOW}A system reboot is ${BOLD}strongly recommended${RESET} to ensure the udev rules are correctly"
echo -e "${YELLOW}applied and all system services recognize the new device configuration.${RESET}"
echo
echo -e "${BOLD}After Reboot Verification Steps:${RESET}"
echo -e " 1. ${BLUE}Check runtime discard setting:${RESET} cat /sys/block/${DEVICE##*/}/queue/discard_max_bytes"
echo -e "    (Should match calculated value: $DEVICE_DISCARD_MAX_BYTES)"
echo -e " 2. ${BLUE}Check runtime provisioning mode:${RESET} cat /sys/block/${DEVICE##*/}/device/scsi_disk/*/provisioning_mode"
echo -e "    (Should show 'unmap' if path exists)"
echo -e " 3. ${BLUE}Run manual TRIM (if mounted):${RESET} sudo fstrim -v /path/to/mountpoint"
echo -e " 4. ${BLUE}Check timer status (if enabled):${RESET} systemctl status fstrim.timer"
echo

log "INFO" "--- Trim Setup Script Finished ---"
exit $E_SUCCESS
