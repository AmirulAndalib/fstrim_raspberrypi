#!/bin/bash

# Script to Setup and Configure TRIM (Discard) Support for External USB SSDs
# Usage: sudo ./setup-trim-final.sh [options]
# Author: AmirulAndalib / Refined by AI Assistant
# Version: 3.5 (Fix variable scope issue with command substitution)
# Last Updated: 2025-05-06

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
DEVICE_NAME=""
TIMER_SCHEDULE="$DEFAULT_TIMER_SCHEDULE"
AUTO_INSTALL=0
SELECTED_USB="unknown" # Holds vendor:product ID or "unknown"
VENDOR_ID=""           # Global
PRODUCT_ID=""          # Global
VERBOSE=0
LOG_FILE=""
ENABLE_TIMER=0
DEVICE_TRIM_SUPPORTED=0
DEVICE_MAX_UNMAP_LBA_COUNT=0
DEVICE_DISCARD_MAX_BYTES=0
FSTRIM_TEST_SUCCESS=0
FOUND_MOUNTPOINT=""
UDEV_RULE_CREATED=0

# --- ANSI Color Codes ---
RED="\e[31m"; GREEN="\e[32m"; YELLOW="\e[33m"; BLUE="\e[34m"; GRAY="\e[90m"; BOLD="\e[1m"; RESET="\e[0m"

# --- Logging Function (unchanged) ---
log() {
    local level=$1; shift; local message="$*"; local timestamp; timestamp=$(date '+%Y-%m-%d %H:%M:%S'); local log_prefix="[$timestamp] [$level]"
    if [ -n "$LOG_FILE" ]; then if [[ "$level" != "TRACE" || "$VERBOSE" -gt 1 ]]; then echo "$log_prefix $message" >> "$LOG_FILE"; fi; fi
    local console_output=0; case "$level" in ERROR|SUCCESS|WARNING|INFO) console_output=1 ;; DEBUG) [ "$VERBOSE" -ge 1 ] && console_output=1 ;; TRACE) [ "$VERBOSE" -ge 2 ] && console_output=1 ;; esac
    if [ "$console_output" -eq 1 ]; then
        local color=$RESET; case $level in ERROR) color=$RED ;; WARNING) color=$YELLOW ;; SUCCESS) color=$GREEN ;; INFO) color=$BLUE ;; DEBUG) color=$GRAY ;; TRACE) color=$GRAY ;; esac
        if [ "$level" = "ERROR" ]; then echo -e "${color}${log_prefix} $message${RESET}" >&2; else echo -e "${color}${log_prefix} $message${RESET}"; fi
    fi
}

# --- Help Function (unchanged) ---
show_help() {
    echo -e "${BOLD}External SSD TRIM Configuration Tool (v3.5)${RESET}"
    echo; echo "Usage: sudo $0 [options]"; echo
    echo "Configures TRIM for external USB SSDs via udev rules."
    echo -e "${YELLOW}Persistence is handled primarily via udev rules.${RESET}"; echo
    echo "Required Packages: sg3-utils(or sg3_utils), lsscsi, usbutils, hdparm, util-linux"; echo
    echo "Options:"
    echo "  -d, --device DEV    Specify target block device (e.g., /dev/sda)."
    echo "  -t, --timer SCHED   Set fstrim timer schedule (default: $DEFAULT_TIMER_SCHEDULE)."
    echo "                      Options: daily, weekly, monthly"
    echo "  -a, --auto          Attempt automatic installation of missing required packages."
    echo "  -e, --enable-timer  Enable systemd fstrim.timer service."
    echo "  -u, --select-usb    Interactively select the target USB SSD."
    echo "  -v, --verbose       Enable verbose logging (-vv for TRACE)."
    echo "  -l, --log FILE      Write logs to file."
    echo "  -h, --help          Show this help message and exit."; echo
    echo "Example (Interactive): sudo $0 --select-usb --auto --enable-timer -vv --log /var/log/trim_setup.log"
    echo "Example (Specific):    sudo $0 -d /dev/sdb -t daily -a -e -v"; echo
    echo -e "${YELLOW}NOTE:${RESET} Run with ${BOLD}sudo${RESET}. ${BOLD}Reboot${RESET} strongly recommended."
    echo -e "${RED}WARNING:${RESET} Use with caution."
}

# --- Utility Functions ---

# check_root (unchanged)
check_root() { if [ "$EUID" -ne 0 ]; then log "ERROR" "Must run as root."; exit $E_ROOT; fi; log "DEBUG" "Root check passed."; }

# install_packages (unchanged)
install_packages() {
    local required_cmds=("sg_vpd" "sg_readcap" "lsscsi" "lsusb" "hdparm" "lsblk" "fstrim" "udevadm" "systemctl")
    local missing_cmds=(); declare -A pkg_map; pkg_map["sg_vpd"]="sg3-utils"; pkg_map["sg_readcap"]="sg3-utils"; pkg_map["lsscsi"]="lsscsi"; pkg_map["lsusb"]="usbutils"; pkg_map["hdparm"]="hdparm"; pkg_map["lsblk"]="util-linux"; pkg_map["fstrim"]="util-linux"; pkg_map["udevadm"]="systemd"; pkg_map["systemctl"]="systemd"
    if command -v dnf &> /dev/null || command -v yum &> /dev/null; then pkg_map["sg_vpd"]="sg3_utils"; pkg_map["sg_readcap"]="sg3_utils"; fi
    if ! command -v udevadm &> /dev/null && command -v apt-get &> /dev/null; then pkg_map["udevadm"]="udev"; fi
    log "INFO" "Checking required commands..."; for cmd in "${required_cmds[@]}"; do if ! command -v "$cmd" &> /dev/null; then log "WARNING" "Missing command: $cmd (Package: ${pkg_map[$cmd]})"; missing_cmds+=("$cmd"); else log "TRACE" "Command '$cmd' found."; fi; done
    if [ ${#missing_cmds[@]} -eq 0 ]; then log "INFO" "All required commands available."; return 0; fi
    log "WARNING" "Missing commands: ${missing_cmds[*]}"; local packages_to_install=(); for cmd in "${missing_cmds[@]}"; do local pkg=${pkg_map[$cmd]}; if [[ "$pkg" == "systemd" || "$pkg" == "util-linux" || "$pkg" == "udev" ]]; then if ! command -v "$cmd" &> /dev/null; then log "ERROR" "Core command '$cmd' missing."; exit $E_PKG_MISSING; fi; fi; if [[ -n "$pkg" && "$pkg" != "systemd" && "$pkg" != "util-linux" && "$pkg" != "udev" && ! " ${packages_to_install[@]} " =~ " $pkg " ]]; then packages_to_install+=("$pkg"); fi; done
    if [ ${#packages_to_install[@]} -eq 0 ]; then log "ERROR" "Cannot resolve missing commands."; exit $E_PKG_MISSING; fi
    log "INFO" "Required packages: ${packages_to_install[*]}"; if [ "$AUTO_INSTALL" -ne 1 ]; then log "ERROR" "Run with --auto to install, or install manually."; exit $E_PKG_MISSING; fi
    local pkg_manager=""; local update_cmd=""; local install_cmd=""; log "INFO" "Attempting auto-installation..."; if command -v apt-get &> /dev/null; then pkg_manager="apt"; update_cmd="apt-get update"; install_cmd="apt-get install -y"; elif command -v dnf &> /dev/null; then pkg_manager="dnf"; install_cmd="dnf install -y"; elif command -v yum &> /dev/null; then pkg_manager="yum"; install_cmd="yum install -y"; elif command -v pacman &> /dev/null; then pkg_manager="pacman"; update_cmd="pacman -Sy --noconfirm"; install_cmd="pacman -S --noconfirm"; else log "ERROR" "No supported package manager found."; exit $E_PKG_INSTALL; fi; log "DEBUG" "Using package manager: $pkg_manager"
    if [ -n "$update_cmd" ]; then log "INFO" "Updating package lists..."; if $update_cmd > /tmp/trim_package_update.log 2>&1; then log "DEBUG" "Update successful."; else log "WARNING" "Update failed ($?). Check /tmp/trim_package_update.log."; [ "$VERBOSE" -ge 1 ] && cat /tmp/trim_package_update.log; fi; fi
    log "INFO" "Installing packages: ${packages_to_install[*]}"; if $install_cmd "${packages_to_install[@]}" > /tmp/trim_package_install.log 2>&1; then log "SUCCESS" "Packages installed."; else log "ERROR" "Install failed ($?). Check /tmp/trim_package_install.log."; [ "$VERBOSE" -ge 1 ] && cat /tmp/trim_package_install.log; exit $E_PKG_INSTALL; fi
    for cmd in "${missing_cmds[@]}"; do local pkg=${pkg_map[$cmd]}; if [[ "$pkg" == "systemd" || "$pkg" == "util-linux" || "$pkg" == "udev" ]]; then continue; fi; if ! command -v "$cmd" &> /dev/null; then log "ERROR" "Command '$cmd' still missing after install."; exit $E_PKG_INSTALL; fi; done; log "INFO" "Command verification successful."
}


# Tries various methods to get USB Vendor:Product ID for a device
# **Modifies VENDOR_ID and PRODUCT_ID globals directly.**
# **Does NOT echo anything.**
# Returns 0 on success, 1 on failure.
get_usb_ids() {
    local dev_path=$1
    local vendor_id_local="" # Use local vars to avoid interfering until success
    local product_id_local=""
    local found=0

    # Ensure globals are clear before attempting detection
    VENDOR_ID=""
    PRODUCT_ID=""

    log "DEBUG" "Attempting to get USB Vendor:Product IDs for $dev_path"
    if [ ! -b "$dev_path" ]; then
        log "WARNING" "Invalid device path in get_usb_ids: $dev_path"
        return 1
    fi

    # Method 1: udevadm info
    log "TRACE" "Trying udevadm info for $dev_path"
    local base_dev_name="${dev_path##*/}"
    base_dev_name=${base_dev_name%%[0-9]*}
    local udev_info
    if udev_info=$(udevadm info --query=property --name="$base_dev_name" 2>/dev/null); then
        vendor_id_local=$(echo "$udev_info" | grep -E '^ID_VENDOR_ID=' | head -n1 | cut -d= -f2)
        product_id_local=$(echo "$udev_info" | grep -E '^ID_MODEL_ID=' | head -n1 | cut -d= -f2)
        if ! [[ "$vendor_id_local" =~ ^[0-9a-fA-F]{4}$ && "$product_id_local" =~ ^[0-9a-fA-F]{4}$ ]]; then
            log "TRACE" "Standard IDs invalid/missing. Checking USB IDs."
            vendor_id_local=$(echo "$udev_info" | grep -E '^ID_USB_VENDOR_ID=' | head -n1 | cut -d= -f2)
            product_id_local=$(echo "$udev_info" | grep -E '^ID_USB_MODEL_ID=' | head -n1 | cut -d= -f2)
        fi
        if [[ "$vendor_id_local" =~ ^[0-9a-fA-F]{4}$ && "$product_id_local" =~ ^[0-9a-fA-F]{4}$ ]]; then
            log "DEBUG" "Found USB IDs via udevadm: ${vendor_id_local}:${product_id_local}"
            VENDOR_ID="$vendor_id_local"   # Set global on success
            PRODUCT_ID="$product_id_local" # Set global on success
            return 0 # Return success
        else
             log "TRACE" "udevadm did not provide valid IDs. V='$vendor_id_local', P='$product_id_local'"
             log "TRACE" "Full udevadm info:\n$udev_info"
        fi
    else
         log "TRACE" "udevadm info failed for $base_dev_name ($?)"
    fi

    # Method 2: sysfs path traversal
    local dev_name=${dev_path##*/}
    dev_name=${dev_name%%[0-9]*}
    local sys_dev_link="/sys/class/block/$dev_name"
    log "TRACE" "Trying sysfs traversal from $sys_dev_link"
    if [[ -L "$sys_dev_link" ]]; then
        local current_path; current_path=$(readlink -f "$sys_dev_link")
        log "TRACE" "Sysfs real path: $current_path"
        while [[ "$current_path" != "/" && "$current_path" != "/sys" && "$current_path" != "." ]]; do
            log "TRACE" "Checking sysfs path: $current_path"
            local parent_path=$(dirname "$current_path")
            # Check parent first, often holds the IDs
            if [[ "$parent_path" != "$current_path" ]]; then
                 if [[ -f "$parent_path/idVendor" && -f "$parent_path/idProduct" ]]; then
                     vendor_id_local=$(cat "$parent_path/idVendor" 2>/dev/null)
                     product_id_local=$(cat "$parent_path/idProduct" 2>/dev/null)
                     log "TRACE" "Potential IDs at parent $parent_path: V='$vendor_id_local' P='$product_id_local'"
                     if [[ "$vendor_id_local" =~ ^[0-9a-fA-F]{4}$ && "$product_id_local" =~ ^[0-9a-fA-F]{4}$ ]]; then
                         log "DEBUG" "Found USB IDs via sysfs parent: ${vendor_id_local}:${product_id_local}"
                         VENDOR_ID="$vendor_id_local"; PRODUCT_ID="$product_id_local"; return 0
                     fi
                 fi
            fi
            # Then check current path
            if [[ -f "$current_path/idVendor" && -f "$current_path/idProduct" ]]; then
                 vendor_id_local=$(cat "$current_path/idVendor" 2>/dev/null)
                 product_id_local=$(cat "$current_path/idProduct" 2>/dev/null)
                 log "TRACE" "Potential IDs at $current_path: V='$vendor_id_local' P='$product_id_local'"
                 if [[ "$vendor_id_local" =~ ^[0-9a-fA-F]{4}$ && "$product_id_local" =~ ^[0-9a-fA-F]{4}$ ]]; then
                     log "DEBUG" "Found USB IDs via sysfs current: ${vendor_id_local}:${product_id_local}"
                     VENDOR_ID="$vendor_id_local"; PRODUCT_ID="$product_id_local"; return 0
                 fi
            fi
            current_path=$parent_path # Go up
        done; log "TRACE" "sysfs traversal failed."
    else log "TRACE" "Cannot resolve sysfs link $sys_dev_link"; fi

    # Method 3: lsusb/lsscsi matching
    log "TRACE" "Trying lsusb/lsscsi matching for $dev_name"
    local scsi_info model vendor_scsi
    if scsi_info=$(lsscsi -t | grep "$dev_name" | head -n 1); then
        log "TRACE" "lsscsi info: $scsi_info"
        model=$(echo "$scsi_info" | sed -n 's/.*\] *[^ ]* *[^ ]* *\(.*\) *[^ ]* *\/dev\/sg.* \/dev\/'"$dev_name"'.*/\1/p' | sed 's/ *$//')
        vendor_scsi=$(echo "$scsi_info" | sed -n 's/.*\] *[^ ]* *\([^ ]*\).*/\1/p')
        log "TRACE" "lsscsi parsed: Vendor='$vendor_scsi', Model='$model'"
        if [[ -n "$vendor_scsi" || -n "$model" ]]; then
            while IFS= read -r line; do
                log "TRACE" "Checking lsusb line: $line"
                local usb_id_match; usb_id_match=$(echo "$line" | grep -o 'ID [[:xdigit:]]\{4\}:[[:xdigit:]]\{4\}' | awk '{print $2}')
                if [[ -n "$usb_id_match" ]]; then
                    if ( [[ -n "$vendor_scsi" && $(echo "$line" | grep -iq "$vendor_scsi") ]] || \
                         [[ -n "$model" && $(echo "$line" | grep -iq "$model") ]] ); then
                        log "DEBUG" "Found potential USB ID via lsusb/lsscsi: $usb_id_match"
                        VENDOR_ID=$(echo "$usb_id_match" | cut -d: -f1); PRODUCT_ID=$(echo "$usb_id_match" | cut -d: -f2); return 0
                    fi
                fi
            done < <(lsusb); log "TRACE" "Finished lsusb check."
        fi
    else log "TRACE" "lsscsi gave no info for $dev_name"; fi

    # Failure case
    log "WARNING" "Could not determine USB Vendor/Product IDs for $dev_path."
    return 1
}


# Interactively select a USB block device
select_usb_device() {
    log "INFO" "Scanning for USB block devices..."
    local devices_found=(); local device_lines=(); local line devname tran model vendor size is_block is_partition is_readonly
    local lsblk_cmd="lsblk -dpno NAME,SIZE,VENDOR,MODEL,TRAN"; log "DEBUG" "Running: $lsblk_cmd"
    local lsblk_output; lsblk_output=$($lsblk_cmd 2>&1); local lsblk_status=$?
    if [ $lsblk_status -ne 0 ]; then log "ERROR" "lsblk failed ($lsblk_status)."; log "ERROR" "Output:\n$lsblk_output"; exit $E_DEVICE_NOT_FOUND; fi

    log "TRACE" "--- Start lsblk Processing ---"
    while IFS= read -r line || [ -n "$line" ]; do
        [[ -z "$line" ]] && continue; log "TRACE" "Raw line: '$line'"; devname=$(echo "$line" | awk '{print $1}'); tran=$(echo "$line" | awk '{print $NF}')
        is_block=$(test -b "$devname" && echo true || echo false); is_partition=$( [[ "$devname" =~ [0-9]$ ]] && echo true || echo false)
        ro_flag=$(lsblk -ndo RO "$devname" 2>/dev/null); if [ $? -ne 0 ]; then log "TRACE" "Skip $devname: Can't get RO flag."; continue; fi
        is_readonly=$( [ "$ro_flag" = "1" ] && echo true || echo false)
        log "TRACE" "Check: '$devname'|Tran:'$tran'|Block:$is_block|Part:$is_partition|RO:$is_readonly(Flag:'$ro_flag')"
        if [[ "$tran" != "usb" || "$is_block" != "true" || "$is_partition" == "true" || "$is_readonly" == "true" ]]; then
             log "TRACE" "Skipping $devname: Fails criteria (tran=$tran, is_block=$is_block, is_partition=$is_partition, is_readonly=$is_readonly)."
             continue
        fi
        log "DEBUG" "Found suitable: $devname ($line)"; devices_found+=("$devname"); device_lines+=("$line")
    done <<< "$lsblk_output"; log "TRACE" "--- End lsblk Processing ---"

    if [ ${#devices_found[@]} -eq 0 ]; then log "ERROR" "No suitable USB block devices found (non-partition, writable, USB)."; exit $E_DEVICE_NOT_FOUND; fi

    echo -e "\n${BOLD}Available USB Block Devices:${RESET}"; echo "---------------------------------"
    printf "%-4s %-15s %-10s %-15s %-s\n" "Num" "Device" "Size" "Vendor" "Model"; echo
    for i in "${!devices_found[@]}"; do
        local display_line="${device_lines[$i]}"; local d_devname=$(echo "$display_line" | awk '{print $1}')
        local d_size=$(echo "$display_line" | awk '{print $2}'); local d_vendor=$(echo "$display_line" | awk '{print $3}')
        local d_model_rest=$(echo "$display_line" | awk '{$1=$2=$3=""; NF--; sub(/^[ \t]+/, ""); print $0}')
        printf "%-4s %-15s %-10s %-15s %-s\n" "$((i+1))." "$d_devname" "$d_size" "$d_vendor" "$d_model_rest"
    done; echo

    local selection get_id_status
    while true; do
        read -p "Select device number (1-${#devices_found[@]}): " selection
        if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le "${#devices_found[@]}" ]; then
            DEVICE="${devices_found[$((selection-1))]}"; DEVICE_NAME="${DEVICE##*/}"
            log "INFO" "Selected device: $DEVICE"; log "DEBUG" "Details: ${device_lines[$((selection-1))]}"

            # Call get_usb_ids directly. It sets globals VENDOR_ID, PRODUCT_ID
            get_usb_ids "$DEVICE"
            get_id_status=$? # Capture return status

            if [[ $get_id_status -eq 0 ]]; then
                # Success: Globals VENDOR_ID and PRODUCT_ID should be set. Construct SELECTED_USB.
                SELECTED_USB="${VENDOR_ID}:${PRODUCT_ID}"
                log "INFO" "Detected USB ID: $SELECTED_USB (Vendor: $VENDOR_ID, Product: $PRODUCT_ID)"
            else
                 # Failure or manual entry needed
                 SELECTED_USB="unknown"; VENDOR_ID=""; PRODUCT_ID="" # Clear globals/state
                 echo; echo -e "${YELLOW}Could not determine USB IDs automatically.${RESET}"
                 echo -e "Try 'lsusb' to find the ${BOLD}ID xxxx:xxxx${RESET} value."
                 read -p "Enter vendor:product ID (e.g., 1b1c:1a0e, blank to skip): " manual_usb_id
                 if [[ "$manual_usb_id" =~ ^[0-9a-fA-F]{4}:[0-9a-fA-F]{4}$ ]]; then
                     SELECTED_USB="$manual_usb_id"
                     VENDOR_ID=$(echo "$manual_usb_id" | cut -d: -f1)
                     PRODUCT_ID=$(echo "$manual_usb_id" | cut -d: -f2)
                     log "INFO" "Using manual USB ID: $SELECTED_USB (Vendor: $VENDOR_ID, Product: $PRODUCT_ID)"
                 else
                     log "WARNING" "Invalid or no manual USB ID. Creating generic udev rule."
                 fi
            fi
            break
        else log "ERROR" "Invalid selection."; fi
    done
}

# --- Core TRIM Functions ---

# check_trim_support (unchanged)
check_trim_support() {
    log "INFO" "Checking TRIM/Unmap support for $DEVICE..."; DEVICE_TRIM_SUPPORTED=0; DEVICE_MAX_UNMAP_LBA_COUNT=0
    log "DEBUG" "Running: sg_vpd --page=bl \"$DEVICE\""; local sg_vpd_bl_output; sg_vpd_bl_output=$(sg_vpd --page=bl "$DEVICE" 2>&1); local sg_vpd_bl_status=$?
    if [ $sg_vpd_bl_status -ne 0 ]; then log "WARNING" "sg_vpd -p bl failed ($sg_vpd_bl_status)."; log "TRACE" "Output:\n$sg_vpd_bl_output"; else
        log "TRACE" "sg_vpd -p bl output:\n$sg_vpd_bl_output"; local count_str; count_str=$(echo "$sg_vpd_bl_output" | grep -i "Maximum unmap LBA count:" | sed -n 's/.*:\s*\([0-9]\+\).*/\1/p')
        if [[ "$count_str" =~ ^[0-9]+$ ]]; then DEVICE_MAX_UNMAP_LBA_COUNT=$count_str; else log "WARNING" "Could not parse Max unmap LBA count."; DEVICE_MAX_UNMAP_LBA_COUNT=0; fi
    fi; log "DEBUG" "Max unmap LBA count: $DEVICE_MAX_UNMAP_LBA_COUNT"
    log "DEBUG" "Running: sg_vpd --page=lbpv \"$DEVICE\""; local sg_vpd_lbpv_output; sg_vpd_lbpv_output=$(sg_vpd --page=lbpv "$DEVICE" 2>&1); local sg_vpd_lbpv_status=$?; local lbpu_supported=0
    if [ $sg_vpd_lbpv_status -ne 0 ]; then log "WARNING" "sg_vpd -p lbpv failed ($sg_vpd_lbpv_status)."; log "TRACE" "Output:\n$sg_vpd_lbpv_output"; else
        log "TRACE" "sg_vpd -p lbpv output:\n$sg_vpd_lbpv_output"
        if echo "$sg_vpd_lbpv_output" | grep -Eiq "Unmap command supported \(LBPU\)[[:space:]]*:[[:space:]]*1"; then lbpu_supported=1; elif echo "$sg_vpd_lbpv_output" | grep -Eiq "Unmap command supported \(LBPU\)[[:space:]]*:[[:space:]]*0"; then lbpu_supported=0; else log "WARNING" "Could not determine LBPU status."; lbpu_supported=0; fi
    fi; log "DEBUG" "Unmap command supported (LBPU): $lbpu_supported"
    local hdparm_supported=0; if [[ "$DEVICE_MAX_UNMAP_LBA_COUNT" -eq 0 || "$lbpu_supported" -eq 0 || $sg_vpd_bl_status -ne 0 || $sg_vpd_lbpv_status -ne 0 ]]; then
        log "INFO" "Primary check failed/negative. Trying hdparm..."; log "DEBUG" "Running: hdparm -I \"$DEVICE\""; local hdparm_output; hdparm_output=$(hdparm -I "$DEVICE" 2>&1); local hdparm_status=$?
        if [ $hdparm_status -ne 0 ]; then log "DEBUG" "hdparm -I failed ($hdparm_status)."; log "TRACE" "Output:\n$hdparm_output"; elif echo "$hdparm_output" | grep -q "Data Set Management TRIM supported" || echo "$hdparm_output" | grep -q "Deterministic read ZEROs after TRIM"; then log "INFO" "TRIM support indicated by hdparm."; hdparm_supported=1; log "TRACE" "hdparm relevant lines:\n$(echo "$hdparm_output" | grep -i trim)"; else log "INFO" "TRIM not indicated by hdparm."; log "TRACE" "Full hdparm output:\n$hdparm_output"; fi
    fi
    if [[ "$lbpu_supported" -eq 1 && "$DEVICE_MAX_UNMAP_LBA_COUNT" -gt 0 ]] || [[ "$hdparm_supported" -eq 1 ]]; then
        log "SUCCESS" "Device $DEVICE appears to support TRIM."; DEVICE_TRIM_SUPPORTED=1
        if [[ "$DEVICE_MAX_UNMAP_LBA_COUNT" -eq 0 && "$hdparm_supported" -eq 1 ]]; then log "WARNING" "Using default LBA count (4194304)."; DEVICE_MAX_UNMAP_LBA_COUNT=4194304; fi
    else
        log "ERROR" "Device $DEVICE does not appear to support TRIM."; DEVICE_TRIM_SUPPORTED=0; echo -e "\n${RED}${BOLD}WARNING:${RESET} ${RED}TRIM not supported.${RESET}"; echo -e "${YELLOW}Configuring may have no effect/cause issues.${RESET}"
        local continue_anyway_response=""; read -p "Continue anyway? (y/N): " continue_anyway_response; declare -g continue_anyway="$continue_anyway_response"
        if [[ ! "$continue_anyway" =~ ^[Yy]$ ]]; then log "INFO" "User aborted."; exit $E_TRIM_UNSUPPORTED_ABORT; fi
        log "WARNING" "Continuing despite lack of detected TRIM support."; if [[ "$DEVICE_MAX_UNMAP_LBA_COUNT" -eq 0 ]]; then DEVICE_MAX_UNMAP_LBA_COUNT=4194304; log "WARNING" "Using default LBA count ($DEVICE_MAX_UNMAP_LBA_COUNT)."; fi
    fi
}

# calculate_discard_max (unchanged)
calculate_discard_max() {
    local block_size=512; log "INFO" "Calculating discard_max_bytes..."; log "DEBUG" "Using Max LBA Count: $DEVICE_MAX_UNMAP_LBA_COUNT"
    log "DEBUG" "Running: sg_readcap --long \"$DEVICE\""; local sg_readcap_output; sg_readcap_output=$(sg_readcap --long "$DEVICE" 2>&1); local sg_readcap_status=$?
    if [ $sg_readcap_status -ne 0 ]; then log "WARNING" "sg_readcap failed ($sg_readcap_status). Using default block size 512."; log "TRACE" "Output: $sg_readcap_output"; else
        log "TRACE" "sg_readcap output:\n$sg_readcap_output"; local detected_bs_str; detected_bs_str=$(echo "$sg_readcap_output" | grep -i "Logical block length=" | sed -n 's/.*=[[:space:]]*\([0-9]\+\).*/\1/p')
        if [[ "$detected_bs_str" =~ ^[0-9]+$ ]] && [ "$detected_bs_str" -gt 0 ]; then block_size=$detected_bs_str; else log "WARNING" "Could not parse block size. Using default 512."; fi
    fi; log "DEBUG" "Using block size: $block_size bytes"
    if [[ "$DEVICE_MAX_UNMAP_LBA_COUNT" -gt 0 ]]; then
        if (( DEVICE_MAX_UNMAP_LBA_COUNT > 9223372036854775807 / block_size )); then log "WARNING" "Using 'bc' for large calculation."; DEVICE_DISCARD_MAX_BYTES=$(echo "$DEVICE_MAX_UNMAP_LBA_COUNT * $block_size" | bc); else DEVICE_DISCARD_MAX_BYTES=$((DEVICE_MAX_UNMAP_LBA_COUNT * block_size)); fi
        local max_discard_limit=4294967295; if (( DEVICE_DISCARD_MAX_BYTES > max_discard_limit )); then log "WARNING" "Capping discard_max_bytes at 4GiB."; DEVICE_DISCARD_MAX_BYTES=$max_discard_limit; fi
    else DEVICE_DISCARD_MAX_BYTES=0; log "WARNING" "Max LBA count 0. Setting discard_max_bytes to 0."; fi
    log "INFO" "Calculated discard_max_bytes: $DEVICE_DISCARD_MAX_BYTES"
}

# configure_trim (Now relies only on global VENDOR_ID/PRODUCT_ID)
configure_trim() {
    log "INFO" "Applying TRIM config for $DEVICE via udev..."; DEVICE_NAME=${DEVICE##*/}; DEVICE_NAME=${DEVICE_NAME%%[0-9]*}; local discard_max=$DEVICE_DISCARD_MAX_BYTES
    log "INFO" "Skipping runtime config; relying on udev."; log "INFO" "Creating persistent udev rule..."
    if ! mkdir -p "$UDEV_RULE_DIR"; then log "ERROR" "Failed to create $UDEV_RULE_DIR"; exit $E_UDEV_RULE; fi; log "TRACE" "Udev dir verified: $UDEV_RULE_DIR"
    local rule_file=""; local rule_content=""
    log "DEBUG" "Checking ID availability: VENDOR_ID='${VENDOR_ID}', PRODUCT_ID='${PRODUCT_ID}'" # Check globals
    if [[ -n "$VENDOR_ID" && -n "$PRODUCT_ID" ]]; then # Use globals directly
        rule_file="$UDEV_RULE_DIR/10-usb-ssd-trim-${VENDOR_ID}-${PRODUCT_ID}.rules"; log "INFO" "Creating ID specific rule: $rule_file"
        rule_content=$(cat << EOF
# Udev rule for USB SSD ${VENDOR_ID}:${PRODUCT_ID} - TRIM support (v3.5)
ACTION=="add|change", ATTRS{idVendor}=="$VENDOR_ID", ATTRS{idProduct}=="$PRODUCT_ID", SUBSYSTEM=="block", KERNEL=="sd*[!0-9]", ATTR{queue/discard_max_bytes}="$discard_max"
ACTION=="add|change", ATTRS{idVendor}=="$VENDOR_ID", ATTRS{idProduct}=="$PRODUCT_ID", SUBSYSTEM=="scsi_disk", ATTR{provisioning_mode}="unmap"
EOF
)
    else
        log "WARNING" "USB ID unavailable/incomplete. Creating generic rule for $DEVICE_NAME."; log "WARNING" "Generic rule might affect other devices if names change."
        rule_file="$UDEV_RULE_DIR/11-generic-ssd-trim-${DEVICE_NAME}.rules"; log "INFO" "Creating generic rule: $rule_file"
        rule_content=$(cat << EOF
# Generic Udev rule for TRIM support - kernel name $DEVICE_NAME (v3.5)
ACTION=="add|change", SUBSYSTEM=="block", KERNEL=="$DEVICE_NAME", ATTR{queue/discard_max_bytes}="$discard_max"
ACTION=="add|change", SUBSYSTEM=="block", KERNEL=="$DEVICE_NAME", RUN+="/bin/sh -c 'for p in /sys\$devpath/device/scsi_disk/*/provisioning_mode; do [ -f \\"\$p\\" ] && [ -w \\"\$p\\" ] && echo unmap > \\"\$p\\"; done'"
EOF
) # Note: Escaped quotes needed inside RUN+="" with cat << EOF
    fi
    log "DEBUG" "Writing udev rule: $rule_file"; log "TRACE" "Rule content:\n$rule_content"
    if echo "$rule_content" > "$rule_file"; then log "SUCCESS" "Created udev rule: $rule_file"; UDEV_RULE_CREATED=1; else log "ERROR" "Failed to write rule ($?)"; exit $E_UDEV_RULE; fi
    log "INFO" "Reloading udev rules..."; if udevadm control --reload-rules; then log "DEBUG" "Reload successful."; else log "WARNING" "Reload failed ($?)."; fi
    log "INFO" "Triggering udev events..."; if [ -e "$DEVICE" ]; then if udevadm trigger --action=change --name="$DEVICE"; then log "DEBUG" "Trigger OK for $DEVICE."; else log "WARNING" "Trigger failed for $DEVICE ($?)."; fi; else if udevadm trigger --action=change --subsystem-match=block; then log "DEBUG" "Trigger OK for block devices."; else log "WARNING" "Trigger failed for block ($?)."; fi; fi
    log "INFO" "Persistence via udev rule. Reboot recommended."
}

# configure_trim_timer (unchanged)
configure_trim_timer() {
    if [ "$ENABLE_TIMER" -ne 1 ]; then log "INFO" "Timer setup skipped (--enable-timer not used)."; return 0; fi; log "INFO" "Configuring systemd fstrim.timer ($TIMER_SCHEDULE)..."
    case "$TIMER_SCHEDULE" in daily|weekly|monthly) log "DEBUG" "Schedule '$TIMER_SCHEDULE' valid.";; *) log "ERROR" "Invalid schedule: '$TIMER_SCHEDULE'."; return $E_ARGS ;; esac
    local timer_unit="fstrim.timer"; local service_unit="fstrim.service"; local timer_override_dir="$SYSTEMD_OVERRIDE_DIR/$timer_unit.d"; local timer_override_file="$timer_override_dir/override.conf"
    log "DEBUG" "Checking $service_unit..."; if ! systemctl list-unit-files "$service_unit" | grep -q "$service_unit"; then log "ERROR" "$service_unit not found."; return $E_SYSTEMD; fi; log "TRACE" "$service_unit found."
    log "DEBUG" "Ensuring dir exists: $timer_override_dir"; if ! mkdir -p "$timer_override_dir"; then log "ERROR" "Failed to create $timer_override_dir"; return $E_SYSTEMD; fi
    log "INFO" "Creating override: $timer_override_file"; local override_content; override_content=$(cat << EOF
# Systemd override set by setup-trim-final.sh
[Timer]
OnCalendar=
OnCalendar=$TIMER_SCHEDULE
EOF
)
    log "TRACE" "Override:\n$override_content"; if ! echo "$override_content" > "$timer_override_file"; then log "ERROR" "Failed to write $timer_override_file"; return $E_SYSTEMD; fi; log "DEBUG" "Override written."
    log "INFO" "Reloading systemd..."; if ! systemctl daemon-reload; then log "WARNING" "daemon-reload failed ($?)."; fi
    log "INFO" "Enabling $timer_unit..."; if ! systemctl enable "$timer_unit"; then log "WARNING" "Enable failed ($?)."; fi
    log "INFO" "Restarting $timer_unit..."; if ! systemctl restart "$timer_unit"; then log "WARNING" "Restart failed ($?). Check status/journal."; fi; sleep 1
    local timer_active; timer_active=$(systemctl is-active "$timer_unit" 2>/dev/null || echo "failed-read"); local timer_enabled; timer_enabled=$(systemctl is-enabled "$timer_unit" 2>/dev/null || echo "failed-read"); local timer_sched; timer_sched=$(systemctl show -p Timers "$timer_unit" 2>/dev/null | grep OnCalendar | cut -d= -f2- | head -n 1)
    if [[ "$timer_active" == "active" && "$timer_enabled" == "enabled" ]]; then log "SUCCESS" "$timer_unit active and enabled."; log "INFO" "Schedule: $timer_sched (Expected: $TIMER_SCHEDULE)"; if [[ "$timer_sched" != *"$TIMER_SCHEDULE"* ]]; then log "WARNING" "Schedule mismatch?"; fi; else log "WARNING" "Timer not fully active/enabled."; log "WARNING" "Status: Active=$timer_active, Enabled=$timer_enabled"; fi
}

# test_trim (unchanged)
test_trim() {
    log "INFO" "Attempting fstrim test..."; FSTRIM_TEST_SUCCESS=0; FOUND_MOUNTPOINT=""; local test_mount_point=""
    log "DEBUG" "Searching mount points for ${DEVICE_NAME}* ..."; local base_device_name="$DEVICE_NAME"; local mount_points; mount_points=$(lsblk -rno MOUNTPOINT "/dev/${base_device_name}"* 2>/dev/null | grep -v '^$' | head -n 1)
    if [ -n "$mount_points" ]; then test_mount_point="$mount_points"; log "INFO" "Found mountpoint $test_mount_point. Testing..."; FOUND_MOUNTPOINT="$test_mount_point"; else log "INFO" "Device/partitions not mounted. Cannot test fstrim."; return 0; fi
    log "DEBUG" "Running: fstrim -v \"$test_mount_point\""; local fstrim_output; fstrim_output=$(fstrim -v "$test_mount_point" 2>&1); local fstrim_status=$?
    if [ $fstrim_status -eq 0 ]; then log "SUCCESS" "fstrim successful on $test_mount_point."; log "INFO" "Output: $fstrim_output"; FSTRIM_TEST_SUCCESS=1; return 0; else
        if echo "$fstrim_output" | grep -q -i "the discard operation is not supported"; then log "ERROR" "fstrim FAILED: Discard not supported."; log "ERROR" "Check FS type/mount options ('discard'?). Reboot needed?"; local fs_type; fs_type=$(lsblk -no FSTYPE "$DEVICE" 2>/dev/null | head -n 1); local mount_opts; mount_opts=$(mount | grep "$test_mount_point" | sed 's/.* type .* (\(.*\))/\1/'); log "DEBUG" "FS:'$fs_type'. Opts:'$mount_opts'."; if [[ -n "$mount_opts" && ! "$mount_opts" =~ discard ]]; then log "INFO" "Try: sudo mount -o remount,discard \"$test_mount_point\""; log "INFO" "Add 'discard' to /etc/fstab."; fi; else log "ERROR" "fstrim FAILED ($fstrim_status)."; log "ERROR" "Output: $fstrim_output"; log "ERROR" "Check fsck, mount, dmesg. Reboot needed?"; fi; return 1
    fi
}

# --- Main Execution ---

# --- Argument Parsing (unchanged) ---
_DEVICE=""; _TIMER_SCHEDULE="$DEFAULT_TIMER_SCHEDULE"; _AUTO_INSTALL=0; _ENABLE_TIMER=0; _SELECT_USB=0; _VERBOSE=0; _LOG_FILE=""
VALID_ARGS=$(getopt -o d:t:aeuvl:h --long device:,timer:,auto,enable-timer,select-usb,verbose,log:,help -- "$@")
if [[ $? -ne 0 ]]; then echo "Invalid arguments." >&2; show_help; exit $E_ARGS; fi
eval set -- "$VALID_ARGS"
while true; do case "$1" in -d|--device) _DEVICE="$2"; shift 2;; -t|--timer) _TIMER_SCHEDULE="$2"; shift 2;; -a|--auto) _AUTO_INSTALL=1; shift;; -e|--enable-timer) _ENABLE_TIMER=1; shift;; -u|--select-usb) _SELECT_USB=1; shift;; -v|--verbose) ((_VERBOSE++)); shift;; -l|--log) _LOG_FILE="$2"; shift 2;; -h|--help) show_help; exit $E_SUCCESS;; --) shift; break;; *) log "ERROR" "Arg parsing error!"; exit $E_INTERNAL;; esac; done
DEVICE="$_DEVICE"; TIMER_SCHEDULE="$_TIMER_SCHEDULE"; AUTO_INSTALL=$_AUTO_INSTALL; ENABLE_TIMER=$_ENABLE_TIMER; VERBOSE=$_VERBOSE; LOG_FILE="$_LOG_FILE"
if [ $_SELECT_USB -eq 1 ] && [ -n "$DEVICE" ]; then log "ERROR" "Cannot use both -u and -d."; exit $E_ARGS; fi; if [ $_SELECT_USB -eq 0 ] && [ -z "$DEVICE" ]; then log "ERROR" "Must specify -d or -u."; exit $E_ARGS; fi

# --- Initialization (unchanged) ---
if [ -n "$LOG_FILE" ]; then if [[ "$LOG_FILE" != /* ]]; then LOG_FILE="$PWD/$LOG_FILE"; fi; log_dir=$(dirname "$LOG_FILE"); if ! mkdir -p "$log_dir"; then echo "ERROR: Cannot create log dir '$log_dir'." >&2; exit $E_LOG_FILE; fi; if ! touch "$LOG_FILE"; then echo "ERROR: Cannot create log file '$LOG_FILE'." >&2; exit $E_LOG_FILE; fi; log "INFO" "--- Trim Setup Script v3.5 Started ---"; log "INFO" "Logging to: $LOG_FILE"; else log "INFO" "--- Trim Setup Script v3.5 Started (Console log only) ---"; fi
log "DEBUG" "Config: DEV='$DEVICE', SCH='$TIMER_SCHEDULE', AUTO=$AUTO_INSTALL, TIMER=$ENABLE_TIMER, USB=$_SELECT_USB, VERBOSE=$VERBOSE"

# --- Pre-Checks ---
check_root; install_packages

# --- Device Selection/Validation (uses updated logic) ---
VENDOR_ID=""; PRODUCT_ID=""; SELECTED_USB="unknown" # Reset globals
if [ $_SELECT_USB -eq 1 ]; then
    select_usb_device # Calls get_usb_ids internally, sets globals
else
    log "INFO" "Using specified device: $DEVICE"
    if [[ ! -b "$DEVICE" ]]; then log "ERROR" "Invalid block device: '$DEVICE'."; exit $E_DEVICE_INVALID; fi
    DEVICE_NAME=${DEVICE##*/}; DEVICE_NAME=${DEVICE_NAME%%[0-9]*}
    # Call get_usb_ids directly, check status, construct SELECTED_USB from globals
    get_usb_ids "$DEVICE"
    get_id_status=$?
    if [[ $get_id_status -eq 0 ]]; then
        SELECTED_USB="${VENDOR_ID}:${PRODUCT_ID}"
        log "INFO" "Detected USB ID: $SELECTED_USB (Vendor: $VENDOR_ID, Product: $PRODUCT_ID)"
    else
        log "WARNING" "Could not determine USB ID for $DEVICE. Creating generic rule."
    fi
fi
# Final check log uses globals which should now be correct
log "DEBUG" "Proceeding -> Device: $DEVICE (Name: $DEVICE_NAME), USB ID: $SELECTED_USB (Vendor: $VENDOR_ID, Product: $PRODUCT_ID)"

# --- Core Logic ---
check_trim_support; calculate_discard_max; configure_trim; configure_trim_timer; test_trim

# --- Final Summary (uses updated variable quoting) ---
echo; echo -e "${BOLD}${GREEN}--- TRIM Configuration Summary (v3.5) ---${RESET}"; echo -e "${GRAY}==============================================${RESET}"
echo -e "Target Device:         ${BOLD}$DEVICE${RESET} (Kernel name: ${DEVICE_NAME})"
echo -e "USB Vendor:Product ID: ${BOLD}\"${SELECTED_USB}\"${RESET} (Vendor: \"${VENDOR_ID}\", Product: \"${PRODUCT_ID}\")" # Correct quoting
if [ "$DEVICE_TRIM_SUPPORTED" -eq 1 ]; then echo -e "Firmware TRIM Support: ${GREEN}Detected${RESET} (Max LBA: $DEVICE_MAX_UNMAP_LBA_COUNT)"; else if [[ -v continue_anyway && "$continue_anyway" =~ ^[Yy]$ ]]; then echo -e "Firmware TRIM Support: ${RED}Not Detected${RESET} - ${YELLOW}Proceeded by user.${RESET}"; else echo -e "Firmware TRIM Support: ${RED}Not Detected${RESET}"; fi; fi
echo -e "Calculated discard_max: ${BOLD}${DEVICE_DISCARD_MAX_BYTES}${RESET} bytes"
if [ "$UDEV_RULE_CREATED" -eq 1 ]; then if [[ -n "$VENDOR_ID" && -n "$PRODUCT_ID" ]]; then echo -e "Persistent udev Rule:  ${GREEN}Created (USB ID Specific)${RESET}"; else echo -e "Persistent udev Rule:  ${YELLOW}Created (Generic - by name $DEVICE_NAME)${RESET}"; fi; else echo -e "Persistent udev Rule:  ${RED}Failed to create${RESET}"; fi
if [ "$ENABLE_TIMER" -eq 1 ]; then timer_active=$(systemctl is-active fstrim.timer 2>/dev/null || echo "error"); timer_enabled=$(systemctl is-enabled fstrim.timer 2>/dev/null || echo "error"); timer_sched=$(systemctl show -p Timers fstrim.timer 2>/dev/null | grep OnCalendar | cut -d= -f2- | head -n 1); if [[ "$timer_active" == "active" && "$timer_enabled" == "enabled" ]]; then echo -e "Periodic TRIM Timer:   ${GREEN}Enabled & Active${RESET} (Schedule: ${timer_sched:-$TIMER_SCHEDULE})"; elif [[ "$timer_active" == "error" || "$timer_enabled" == "error" ]]; then echo -e "Periodic TRIM Timer:   ${RED}Error checking status${RESET} (Configured: $TIMER_SCHEDULE)"; else echo -e "Periodic TRIM Timer:   ${YELLOW}Configured${RESET} (Schedule: ${timer_sched:-$TIMER_SCHEDULE}) - Status: Active=${timer_active}, Enabled=${timer_enabled}"; fi; else echo -e "Periodic TRIM Timer:   ${GRAY}Not Enabled${RESET}"; fi
if [ -n "$FOUND_MOUNTPOINT" ]; then if [ "$FSTRIM_TEST_SUCCESS" -eq 1 ]; then echo -e "Runtime fstrim Test:   ${GREEN}Successful on $FOUND_MOUNTPOINT${RESET}"; else echo -e "Runtime fstrim Test:   ${RED}Failed on $FOUND_MOUNTPOINT${RESET}"; fi; else echo -e "Runtime fstrim Test:   ${GRAY}N/A (Not mounted)${RESET}"; fi
echo -e "${GRAY}==============================================${RESET}"; echo -e "${GREEN}${BOLD}Configuration steps completed.${RESET}"; echo
echo -e "${RED}${BOLD}=== IMPORTANT: REBOOT RECOMMENDED ===${RESET}"; echo -e "${YELLOW}Reboot is ${BOLD}strongly recommended${RESET}${YELLOW} for udev rules to apply reliably.${RESET}"; echo
echo -e "${BOLD}After Reboot Verification:${RESET}"; echo -e "1. ${BLUE}Check discard setting:${RESET} cat /sys/block/${DEVICE_NAME}/queue/discard_max_bytes"; echo -e "   (Should match: $DEVICE_DISCARD_MAX_BYTES or limit)"
echo -e "2. ${BLUE}Check provisioning mode:${RESET} cat /sys/block/${DEVICE_NAME}/device/scsi_disk/*/provisioning_mode"; echo -e "   (Should show '${BOLD}unmap${RESET}')"
echo -e "3. ${BLUE}Manual TRIM test:${RESET} sudo fstrim -v /path/to/mountpoint"; echo -e "4. ${BLUE}Timer status (if enabled):${RESET} systemctl status fstrim.timer"; echo
log "INFO" "--- Trim Setup Script Finished ---"; exit $E_SUCCESS
