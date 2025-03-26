#!/bin/bash

# Script to setup and configure TRIM support for external SSDs
# Usage: sudo ./setup-trim.sh [options]
# Author: AmirulAndalib
# Version: 2.0

set -e

# Default values
DEVICE="/dev/sda"
TIMER_SCHEDULE="weekly"
AUTO_INSTALL=0
SELECTED_USB=""
VERBOSE=0
LOG_FILE=""
ENABLE_TIMER=0

# ANSI color codes
RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
BLUE="\e[34m"
GRAY="\e[90m"
BOLD="\e[1m"
RESET="\e[0m"

# Function to handle logging
log() {
    local level=$1
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Always log to file if LOG_FILE is set
    if [ -n "$LOG_FILE" ]; then
        echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
    fi
    
    # Only show detailed logs if VERBOSE is enabled
    if [ "$VERBOSE" -eq 1 ] || [ "$level" != "DEBUG" ]; then
        case $level in
            "ERROR")
                echo -e "${RED}[$timestamp] $message${RESET}" >&2
                ;;
            "WARNING")
                echo -e "${YELLOW}[$timestamp] $message${RESET}"
                ;;
            "SUCCESS")
                echo -e "${GREEN}[$timestamp] $message${RESET}"
                ;;
            "INFO")
                echo -e "${BLUE}[$timestamp] $message${RESET}"
                ;;
            "DEBUG")
                echo -e "${GRAY}[$timestamp] $message${RESET}"
                ;;
        esac
    fi
}

# Function to display help
show_help() {
    echo -e "${BOLD}TRIM Configuration Tool for External SSDs${RESET}"
    echo
    echo "Usage: $0 [options]"
    echo
    echo "Options:"
    echo "  -d, --device        Specify device (default: /dev/sda)"
    echo "  -t, --timer         Set TRIM timer schedule (default: weekly)"
    echo "                      Options: daily, weekly, monthly"
    echo "  -a, --auto          Automatically install required packages"
    echo "  -e, --enable-timer  Enable fstrim timer service"
    echo "  -u, --select-usb    Select USB device from list"
    echo "  -v, --verbose       Enable verbose logging"
    echo "  -l, --log FILE      Write logs to specified file"
    echo "  -h, --help          Show this help message"
    echo
    echo "Example: $0 -d /dev/sdb -t daily --auto --enable-timer --verbose"
}

# Function to check if running as root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        log "ERROR" "This script must be run as root or with sudo"
        exit 1
    fi
}

# Function to install required packages
install_packages() {
    log "INFO" "Installing required packages..."
    
    # Check for package managers and install packages
    if command -v apt-get &> /dev/null; then
        log "DEBUG" "Using apt-get package manager"
        apt-get update &> /dev/null || {
            log "ERROR" "Failed to update package lists"
            exit 1
        }
        
        apt-get install -y sg3-utils lsscsi &> /dev/null || {
            log "ERROR" "Failed to install required packages"
            exit 1
        }
        
    elif command -v dnf &> /dev/null; then
        log "DEBUG" "Using dnf package manager"
        dnf install -y sg3_utils lsscsi &> /dev/null || {
            log "ERROR" "Failed to install required packages"
            exit 1
        }
        
    elif command -v yum &> /dev/null; then
        log "DEBUG" "Using yum package manager"
        yum install -y sg3_utils lsscsi &> /dev/null || {
            log "ERROR" "Failed to install required packages"
            exit 1
        }
        
    elif command -v pacman &> /dev/null; then
        log "DEBUG" "Using pacman package manager"
        pacman -Sy --noconfirm sg3_utils lsscsi &> /dev/null || {
            log "ERROR" "Failed to install required packages"
            exit 1
        }
        
    else
        log "ERROR" "No supported package manager found"
        exit 1
    fi
    
    log "SUCCESS" "Required packages installed successfully"
}

# Function to list available block devices
list_block_devices() {
    log "INFO" "Scanning for available block devices..."
    echo -e "\n${BOLD}Available Block Devices:${RESET}"
    echo "-----------------------"
    
    # Create an array of block devices
    local devices=()
    while IFS= read -r line; do
        devices+=("$line")
    done < <(lsblk -dpno NAME,SIZE,MODEL,VENDOR,TRAN | sort)
    
    if [ ${#devices[@]} -eq 0 ]; then
        log "ERROR" "No block devices found"
        exit 1
    fi
    
    # Display devices with numbers
    for i in "${!devices[@]}"; do
        echo -e "$((i+1)). ${devices[$i]}"
    done
    
    echo
    read -p "Select device number (1-${#devices[@]}, or 0 to keep current selection '$DEVICE'): " selection
    
    if [[ "$selection" =~ ^[0-9]+$ ]]; then
        if [ "$selection" -eq 0 ]; then
            log "INFO" "Keeping current device selection: $DEVICE"
        elif [ "$selection" -ge 1 ] && [ "$selection" -le "${#devices[@]}" ]; then
            selected_line="${devices[$((selection-1))]}"
            DEVICE=$(echo "$selected_line" | awk '{print $1}')
            log "INFO" "Selected device: $DEVICE (${selected_line})"
        else
            log "ERROR" "Invalid selection: $selection"
            exit 1
        fi
    else
        log "ERROR" "Invalid input: $selection"
        exit 1
    fi
}

# Function to select USB device
select_usb_device() {
    log "INFO" "Scanning for USB devices..."
    echo -e "\n${BOLD}Available USB Devices:${RESET}"
    echo "----------------------"
    
    # Create array of USB block devices
    local devices=()
    while IFS= read -r line; do
        if [[ "$line" == *usb* ]]; then
            devices+=("$line")
        fi
    done < <(lsblk -dpno NAME,SIZE,MODEL,VENDOR,TRAN | sort)
    
    if [ ${#devices[@]} -eq 0 ]; then
        log "WARNING" "No USB block devices found"
        
        # Fallback to lsusb
        log "INFO" "Checking for USB devices with lsusb..."
        if ! command -v lsusb &> /dev/null; then
            if [ "$AUTO_INSTALL" -eq 1 ]; then
                log "INFO" "Installing usbutils package..."
                apt-get install -y usbutils &> /dev/null || {
                    log "ERROR" "Failed to install usbutils package"
                    exit 1
                }
            else
                log "ERROR" "lsusb command not found. Run with --auto to install automatically."
                exit 1
            fi
        fi
        
        mapfile -t usb_devices < <(lsusb)
        
        if [ ${#usb_devices[@]} -eq 0 ]; then
            log "ERROR" "No USB devices found"
            exit 1
        fi
        
        # Display devices with numbers
        for i in "${!usb_devices[@]}"; do
            echo "$((i+1)). ${usb_devices[$i]}"
        done
        
        # Get user selection
        echo
        read -p "Select USB device number (1-${#usb_devices[@]}): " selection
        
        if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le "${#usb_devices[@]}" ]; then
            selected_line="${usb_devices[$((selection-1))]}"
            SELECTED_USB=$(echo "$selected_line" | grep -o "ID [[:xdigit:]]\+:[[:xdigit:]]\+" | cut -d' ' -f2)
            log "INFO" "Selected USB device: $selected_line"
            log "DEBUG" "USB ID: $SELECTED_USB"
            
            echo
            read -p "Enter the block device path for this USB device (e.g., /dev/sdb): " DEVICE
            
            if [ ! -b "$DEVICE" ]; then
                log "ERROR" "Invalid block device path: $DEVICE"
                exit 1
            fi
        else
            log "ERROR" "Invalid selection: $selection"
            exit 1
        fi
    else
        # Display devices with numbers
        for i in "${!devices[@]}"; do
            echo "$((i+1)). ${devices[$i]}"
        done
        
        # Get user selection
        echo
        read -p "Select USB device number (1-${#devices[@]}): " selection
        
        if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le "${#devices[@]}" ]; then
            selected_line="${devices[$((selection-1))]}"
            DEVICE=$(echo "$selected_line" | awk '{print $1}')
            log "INFO" "Selected USB device: $DEVICE (${selected_line})"
            
            # Try to get USB ID for udev rule
            local sys_path="/sys/block/${DEVICE##*/}/device/../../idVendor"
            if [ -f "$sys_path" ]; then
                local vendor_id=$(cat "${sys_path}")
                local product_id=$(cat "/sys/block/${DEVICE##*/}/device/../../idProduct")
                SELECTED_USB="${vendor_id}:${product_id}"
                log "DEBUG" "USB ID: $SELECTED_USB"
            fi
        else
            log "ERROR" "Invalid selection: $selection"
            exit 1
        fi
    fi
}

# Function to check TRIM support
check_trim_support() {
    log "INFO" "Checking TRIM support for $DEVICE..."
    
    # Check that device exists
    if [ ! -b "$DEVICE" ]; then
        log "ERROR" "Device $DEVICE does not exist or is not a block device"
        exit 1
    fi
    
    # Check if device is mounted
    if mount | grep -q "^$DEVICE"; then
        log "WARNING" "Device $DEVICE is currently mounted. This might affect TRIM operations."
    fi
    
    # Check firmware TRIM support using sg_vpd
    if ! command -v sg_vpd &> /dev/null; then
        log "ERROR" "sg_vpd command not found. Required for TRIM support checking."
        exit 1
    fi
    
    log "DEBUG" "Running sg_vpd check for unmap count..."
    UNMAP_COUNT=$(sg_vpd -p bl "$DEVICE" 2>&1 || echo "Error")
    
    if [[ "$UNMAP_COUNT" == *"Error"* ]]; then
        log "WARNING" "sg_vpd command failed. Continuing with limited checks."
        UNMAP_COUNT=0
    else
        UNMAP_COUNT=$(echo "$UNMAP_COUNT" | grep -i "Maximum unmap LBA count" | awk '{print $5}')
        if [ -z "$UNMAP_COUNT" ]; then
            UNMAP_COUNT=0
        fi
    fi
    log "DEBUG" "Unmap count: $UNMAP_COUNT"
    
    log "DEBUG" "Checking unmap support..."
    UNMAP_SUPPORTED_OUTPUT=$(sg_vpd -p lbpv "$DEVICE" 2>&1 || echo "Error")
    
    if [[ "$UNMAP_SUPPORTED_OUTPUT" == *"Error"* ]]; then
        log "WARNING" "sg_vpd lbpv command failed. Continuing with limited checks."
        UNMAP_SUPPORTED=0
    else
        UNMAP_SUPPORTED=$(echo "$UNMAP_SUPPORTED_OUTPUT" | grep -i "Unmap command supported" | grep -o "[01]")
        if [ -z "$UNMAP_SUPPORTED" ]; then
            UNMAP_SUPPORTED=0
        fi
    fi
    log "DEBUG" "Unmap supported: $UNMAP_SUPPORTED"
    
    # Alternative check for TRIM support using hdparm
    if [ "$UNMAP_COUNT" -eq 0 ] || [ "$UNMAP_SUPPORTED" -ne 1 ]; then
        log "WARNING" "Primary TRIM check failed, trying alternative method with hdparm..."
        
        if ! command -v hdparm &> /dev/null; then
            if [ "$AUTO_INSTALL" -eq 1 ]; then
                log "INFO" "Installing hdparm..."
                apt-get install -y hdparm &> /dev/null || {
                    log "ERROR" "Failed to install hdparm"
                }
            fi
        fi
        
        if command -v hdparm &> /dev/null; then
            HDPARM_OUTPUT=$(hdparm -I "$DEVICE" 2>&1 || echo "Error")
            if [[ "$HDPARM_OUTPUT" == *"Error"* ]]; then
                log "WARNING" "hdparm command failed. Unable to verify TRIM support."
            elif [[ "$HDPARM_OUTPUT" == *"Data Set Management TRIM supported"* ]]; then
                log "INFO" "TRIM support detected via hdparm"
                UNMAP_SUPPORTED=1
                UNMAP_COUNT=65535  # Default reasonable value
            else
                log "WARNING" "TRIM support not detected via hdparm"
            fi
        fi
    fi
    
    # Final check
    if [ "$UNMAP_COUNT" -eq 0 ] || [ "$UNMAP_SUPPORTED" -ne 1 ]; then
        log "ERROR" "Device does not appear to support TRIM in firmware"
        echo -e "\n${RED}${BOLD}WARNING:${RESET} ${RED}TRIM is not supported by this device.${RESET}"
        echo -e "${YELLOW}You can continue at your own risk, but TRIM may not work properly.${RESET}"
        echo
        
        read -p "Do you want to continue anyway? (y/N): " continue_anyway
        if [[ ! "$continue_anyway" =~ ^[Yy]$ ]]; then
            log "INFO" "User chose to abort due to lack of TRIM support"
            exit 0
        fi
        
        log "WARNING" "Continuing despite lack of TRIM support"
    else
        log "SUCCESS" "Device supports TRIM capabilities"
    fi
}

# Function to configure TRIM
configure_trim() {
    log "INFO" "Configuring TRIM for $DEVICE..."
    
    # Get block size
    log "DEBUG" "Getting block size..."
    if command -v sg_readcap &> /dev/null; then
        BLOCK_SIZE_OUTPUT=$(sg_readcap -l "$DEVICE" 2>&1 || echo "Error")
        
        if [[ "$BLOCK_SIZE_OUTPUT" == *"Error"* ]]; then
            log "WARNING" "sg_readcap command failed. Using default block size."
            BLOCK_SIZE=512
        else
            BLOCK_SIZE=$(echo "$BLOCK_SIZE_OUTPUT" | grep -i "block size" | awk '{print $3}')
            if [ -z "$BLOCK_SIZE" ]; then
                BLOCK_SIZE=512
                log "WARNING" "Could not determine block size, using default: $BLOCK_SIZE"
            fi
        fi
    else
        BLOCK_SIZE=512
        log "WARNING" "sg_readcap command not found. Using default block size: $BLOCK_SIZE"
    fi
    
    log "DEBUG" "Block size: $BLOCK_SIZE"
    
    if [ "$UNMAP_COUNT" -gt 0 ]; then
        DISCARD_MAX=$((UNMAP_COUNT * BLOCK_SIZE))
        log "DEBUG" "Calculated discard_max_bytes: $DISCARD_MAX"
    else
        # Default to 128MB if unmap count is unknown
        DISCARD_MAX=$((128 * 1024 * 1024))
        log "DEBUG" "Using default discard_max_bytes: $DISCARD_MAX"
    fi
    
    # Find and set provisioning mode
    DEVICE_NAME=${DEVICE##*/}
    log "DEBUG" "Looking for provisioning_mode path for device: $DEVICE_NAME"
    
    PROV_PATHS=(
        "/sys/block/$DEVICE_NAME/device/scsi_disk/"*"/provisioning_mode"
        "/sys/class/scsi_disk/"*"/device/provisioning_mode"
        "/sys/devices/"*"/scsi_disk/"*"/provisioning_mode"
    )
    
    PROV_PATH=""
    for path in "${PROV_PATHS[@]}"; do
        log "DEBUG" "Checking path pattern: $path"
        for expanded_path in $(eval echo "$path" 2>/dev/null || echo ""); do
            if [ -f "$expanded_path" ]; then
                PROV_PATH="$expanded_path"
                log "DEBUG" "Found provisioning_mode path: $PROV_PATH"
                break 2
            fi
        done
    done
    
    if [ -z "$PROV_PATH" ]; then
        log "WARNING" "Could not find provisioning_mode path"
        
        # Try to find the correct path by listing all provisioning_mode files
        log "DEBUG" "Searching for any provisioning_mode file..."
        FOUND_PATHS=$(find /sys -name "provisioning_mode" -type f 2>/dev/null || echo "")
        
        if [ -n "$FOUND_PATHS" ]; then
            # Try to find the best match
            while IFS= read -r path; do
                if [[ "$path" == *"$DEVICE_NAME"* ]]; then
                    PROV_PATH="$path"
                    log "DEBUG" "Found matching provisioning_mode path: $PROV_PATH"
                    break
                fi
            done <<< "$FOUND_PATHS"
            
            # If no device-specific match found, use the first one
            if [ -z "$PROV_PATH" ]; then
                PROV_PATH=$(echo "$FOUND_PATHS" | head -n 1)
                log "WARNING" "Using first available provisioning_mode path: $PROV_PATH"
            fi
        fi
        
        # If still not found, try to create it
        if [ -z "$PROV_PATH" ]; then
            log "WARNING" "No provisioning_mode path found. Attempting to create one..."
            
            SCSI_HOST=$(ls -d /sys/class/scsi_host/host* 2>/dev/null | head -n 1)
            if [ -n "$SCSI_HOST" ]; then
                log "DEBUG" "Found SCSI host: $SCSI_HOST"
                mkdir -p "${SCSI_HOST}/device/scsi_disk/${DEVICE_NAME}" 2>/dev/null || true
                PROV_PATH="${SCSI_HOST}/device/scsi_disk/${DEVICE_NAME}/provisioning_mode"
                touch "$PROV_PATH" 2>/dev/null || true
                log "DEBUG" "Attempted to create provisioning_mode path: $PROV_PATH"
            fi
        fi
    fi
    
    if [ -n "$PROV_PATH" ] && [ -f "$PROV_PATH" ]; then
        log "DEBUG" "Setting provisioning_mode to unmap"
        echo "unmap" > "$PROV_PATH" 2>/dev/null || {
            log "WARNING" "Failed to write to provisioning_mode. May require manual intervention."
        }
        
        # Verify the change
        CURRENT_MODE=$(cat "$PROV_PATH" 2>/dev/null || echo "unknown")
        log "DEBUG" "Current provisioning_mode: $CURRENT_MODE"
        
        if [ "$CURRENT_MODE" = "unmap" ]; then
            log "SUCCESS" "Successfully set provisioning_mode to unmap"
        else
            log "WARNING" "Failed to set provisioning_mode to unmap. Current value: $CURRENT_MODE"
        fi
    else
        log "WARNING" "Provisioning_mode path not found or not writable"
    fi
    
    # Set discard_max_bytes
    DISCARD_PATH="/sys/block/$DEVICE_NAME/queue/discard_max_bytes"
    log "DEBUG" "Setting discard_max_bytes in: $DISCARD_PATH"
    if [ -f "$DISCARD_PATH" ]; then
        echo "$DISCARD_MAX" > "$DISCARD_PATH" 2>/dev/null || {
            log "WARNING" "Failed to write to discard_max_bytes"
        }
        
        # Verify the change
        CURRENT_DISCARD=$(cat "$DISCARD_PATH" 2>/dev/null || echo "0")
        log "DEBUG" "Current discard_max_bytes: $CURRENT_DISCARD"
        
        if [ "$CURRENT_DISCARD" -gt 0 ]; then
            log "SUCCESS" "Successfully set discard_max_bytes to $CURRENT_DISCARD"
        else
            log "WARNING" "Failed to set discard_max_bytes or value is 0"
        fi
    else
        log "WARNING" "discard_max_bytes path not found: $DISCARD_PATH"
    fi
    
    # Create udev rule if USB device was selected
    if [ -n "$SELECTED_USB" ]; then
        VENDOR_ID=$(echo "$SELECTED_USB" | cut -d: -f1)
        PRODUCT_ID=$(echo "$SELECTED_USB" | cut -d: -f2)
        
        if [ -n "$VENDOR_ID" ] && [ -n "$PRODUCT_ID" ]; then
            RULE_FILE="/etc/udev/rules.d/10-trim-$VENDOR_ID-$PRODUCT_ID.rules"
            log "INFO" "Creating udev rule in: $RULE_FILE"
            
            cat > "$RULE_FILE" << EOF
# Enable TRIM for USB device with vendor:product ID $VENDOR_ID:$PRODUCT_ID
ACTION=="add|change", ATTRS{idVendor}=="$VENDOR_ID", ATTRS{idProduct}=="$PRODUCT_ID", SUBSYSTEM=="scsi_disk", ATTR{provisioning_mode}="unmap"
EOF
            
            log "DEBUG" "Reloading udev rules"
            udevadm control --reload-rules 2>/dev/null || {
                log "WARNING" "Failed to reload udev rules"
            }
            udevadm trigger 2>/dev/null || {
                log "WARNING" "Failed to trigger udev rules"
            }
            log "SUCCESS" "Created and activated udev rule for persistent TRIM support"
        else
            log "WARNING" "Invalid USB vendor/product ID. Skipping udev rule creation."
        fi
    fi
}

# Function to configure TRIM timer
configure_trim_timer() {
    if [ "$ENABLE_TIMER" -eq 1 ]; then
        log "INFO" "Configuring TRIM timer schedule: $TIMER_SCHEDULE"
        
        # Check if systemd is available
        if ! command -v systemctl &> /dev/null; then
            log "ERROR" "systemd is not available. Cannot configure timer."
            return 1
        fi
        
        # Check if fstrim timer exists
        FSTRIM_SERVICE=$(systemctl list-unit-files fstrim.timer 2>/dev/null || echo "")
        if [ -z "$FSTRIM_SERVICE" ]; then
            log "WARNING" "fstrim.timer service not found. Creating custom timer."
            
            # Create fstrim service if it doesn't exist
            mkdir -p /etc/systemd/system
            
            cat > "/etc/systemd/system/fstrim.service" << EOF
[Unit]
Description=Discard unused blocks

[Service]
Type=oneshot
ExecStart=/usr/sbin/fstrim -av

[Install]
WantedBy=multi-user.target
EOF
        fi
        
        # Configure timer based on schedule
        case "$TIMER_SCHEDULE" in
            daily|weekly|monthly)
                # Create or update timer file
                TIMER_FILE="/etc/systemd/system/fstrim.timer"
                log "DEBUG" "Creating/updating timer file: $TIMER_FILE"
                
                cat > "$TIMER_FILE" << EOF
[Unit]
Description=Discard unused blocks

[Timer]
OnCalendar=$TIMER_SCHEDULE
AccuracySec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF
                
                systemctl daemon-reload 2>/dev/null || {
                    log "WARNING" "Failed to reload systemd daemon"
                }
                
                systemctl enable fstrim.timer 2>/dev/null || {
                    log "WARNING" "Failed to enable fstrim timer"
                }
                
                systemctl start fstrim.timer 2>/dev/null || {
                    log "WARNING" "Failed to start fstrim timer"
                }
                
                TIMER_STATUS=$(systemctl is-active fstrim.timer 2>/dev/null || echo "unknown")
                
                if [ "$TIMER_STATUS" = "active" ]; then
                    log "SUCCESS" "Configured and started automatic TRIM schedule: $TIMER_SCHEDULE"
                else
                    log "WARNING" "Timer service may not be active. Current status: $TIMER_STATUS"
                fi
                ;;
                
            *)
                log "ERROR" "Invalid timer schedule: $TIMER_SCHEDULE. Valid options: daily, weekly, monthly"
                return 1
                ;;
        esac
    else
        log "INFO" "TRIM timer not enabled (use --enable-timer to activate scheduled TRIMs)"
    fi
}

# Function to test TRIM
test_trim() {
    log "INFO" "Testing TRIM functionality..."
    
    # Check if fstrim is available
    if ! command -v fstrim &> /dev/null; then
        log "ERROR" "fstrim command not found. Cannot test TRIM."
        return 1
    fi
    
    # Find mount point for the device
    MOUNT_POINT=$(findmnt -n -o TARGET "$DEVICE" 2>/dev/null)
    
    if [ -n "$MOUNT_POINT" ]; then
        log "INFO" "Device is mounted at $MOUNT_POINT. Testing TRIM on this mount point."
        TRIM_OUTPUT=$(fstrim -v "$MOUNT_POINT" 2>&1) || {
            log "ERROR" "TRIM test failed on $MOUNT_POINT"
            return 1
        }
        
        log "SUCCESS" "TRIM test output: $TRIM_OUTPUT"
    else
        log "INFO" "Device is not mounted. Testing system-wide TRIM."
        TRIM_OUTPUT=$(fstrim -av 2>&1) || {
            log "WARNING" "System-wide TRIM test returned errors"
        }
        
        log "INFO" "TRIM test output: $TRIM_OUTPUT"
    fi
    
    return 0
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -d|--device)
            DEVICE="$2"
            shift 2
            ;;
        -t|--timer)
            TIMER_SCHEDULE="$2"
            shift 2
            ;;
        -a|--auto)
            AUTO_INSTALL=1
            shift
            ;;
        -e|--enable-timer)
            ENABLE_TIMER=1
            shift
            ;;
        -u|--select-usb)
            # We'll call select_usb_device later
            SELECTED_USB="pending"
            shift
            ;;
        -v|--verbose)
            VERBOSE=1
            shift
            ;;
        -l|--log)
            LOG_FILE="$2"
            shift 2
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            log "ERROR" "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

# MAIN EXECUTION STARTS HERE

# Initialize log file if specified
if [ -n "$LOG_FILE" ]; then
    # Create log directory if it doesn't exist
    log_dir=$(dirname "$LOG_FILE")
    mkdir -p "$log_dir" 2>/dev/null || {
        echo "Error: Failed to create log directory $log_dir"
        exit 1
    }
    touch "$LOG_FILE" 2>/dev/null || {
        echo "Error: Failed to create log file $LOG_FILE"
        exit 1
    }
    log "INFO" "Started logging to $LOG_FILE"
fi

# Display banner
echo -e "${BOLD}${BLUE}TRIM Configuration Tool${RESET}"
echo -e "${GRAY}===================================================${RESET}"
echo

# Check if running as root
check_root

# Check if packages are installed
MISSING_PKGS=0
for pkg in sg_vpd lsscsi; do
    if ! command -v $pkg &> /dev/null; then
        MISSING_PKGS=1
        log "DEBUG" "Missing required command: $pkg"
    fi
done

if [ "$MISSING_PKGS" -eq 1 ]; then
    if [ "$AUTO_INSTALL" -eq 1 ]; then
        install_packages
    else
        log "ERROR" "Required packages not found. Run with --auto to install automatically."
        exit 1
    fi
fi

# Handle device selection
if [ "$SELECTED_USB" = "pending" ]; then
    select_usb_device
elif [ "$DEVICE" = "/dev/sda" ]; then
    # If using the default device, ask if user wants to select another one
    echo -e "${YELLOW}Currently using default device: $DEVICE${RESET}"
    read -p "Do you want to select a different device? (y/N): " select_different
    
    if [[ "$select_different" =~ ^[Yy]$ ]]; then
        list_block_devices
    fi
fi

# Check TRIM support
check_trim_support

# Configure TRIM
configure_trim

# Ask about timer if not specified in the options
if [ "$ENABLE_TIMER" -eq 0 ]; then
    echo
    read -p "Do you want to enable automatic TRIM schedule? (y/N): " enable_timer
    
    if [[ "$enable_timer" =~ ^[Yy]$ ]]; then
        ENABLE_TIMER=1
        
        echo -e "\n${BOLD}Select TRIM schedule:${RESET}"
        echo "1. Daily"
        echo "2. Weekly (recommended)"
        echo "3. Monthly"
        echo
        read -p "Select schedule (1-3, default: 2): " schedule_selection
        
        case "$schedule_selection" in
            1) TIMER_SCHEDULE="daily" ;;
            3) TIMER_SCHEDULE="monthly" ;;
            *) TIMER_SCHEDULE="weekly" ;;
        esac
    fi
fi

# Configure TRIM timer if enabled
if [ "$ENABLE_TIMER" -eq 1 ]; then
    configure_trim_timer
fi

# Test TRIM functionality
test_trim

# Display summary
echo
echo -e "${BOLD}${GREEN}TRIM Configuration Summary${RESET}"
echo -e "${GRAY}===================================================${RESET}"
echo -e "Device: ${BOLD}$DEVICE${RESET}"
echo -e "TRIM Support: ${BOLD}$([ "$UNMAP_SUPPORTED" -eq 1 ] && echo "${GREEN}Enabled${RESET}" || echo "${RED}Limited/Not Supported${RESET}")${RESET}"

if [ -n "$PROV_PATH" ]; then
    curr_prov=$(cat "$PROV_PATH" 2>/dev/null || echo "unknown")
    echo -e "Provisioning Mode: ${BOLD}$curr_prov${RESET}"
fi

if [ -n "$DISCARD_PATH" ]; then
    curr_discard=$(cat "$DISCARD_PATH" 2>/dev/null || echo "unknown")
    echo -e "Discard Max Bytes: ${BOLD}$curr_discard${RESET}"
fi

if [ -n "$SELECTED_USB" ] && [ "$SELECTED_USB" != "pending" ]; then
    echo -e "USB Device: ${BOLD}$SELECTED_USB${RESET}"
    echo -e "Persistent Configuration: ${BOLD}${GREEN}udev rule created${RESET}"
fi

if [ "$ENABLE_TIMER" -eq 1 ]; then
    timer_status=$(systemctl is-active fstrim.timer 2>/dev/null || echo "unknown")
    echo -e "TRIM Schedule: ${BOLD}$TIMER_SCHEDULE (Status: $timer_status)${RESET}"
else
    echo -e "TRIM Schedule: ${BOLD}${YELLOW}Not enabled${RESET}"
fi

echo -e "${GRAY}===================================================${RESET}"
echo -e "${GREEN}${BOLD}TRIM setup completed!${RESET}"
echo
echo -e "${YELLOW}NOTE: You may need to reboot for all changes to take effect.${RESET}"

log "INFO" "Script execution completed successfully"
exit 0
