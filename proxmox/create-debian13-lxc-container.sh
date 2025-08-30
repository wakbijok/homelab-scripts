#!/bin/bash

# Debian 13 LXC Container Creator for Proxmox
# Creates Debian 13 template using DAB and deploys LXC container with console fixes
# Usage: ./create-debian13-lxc-container.sh

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_prompt() {
    echo -e "${BLUE}[INPUT]${NC} $1"
}

print_step() {
    echo -e "${BLUE}==== $1 ====${NC}"
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   print_error "This script must be run as root"
   exit 1
fi

# Check if DAB is installed
if ! command -v dab &> /dev/null; then
    print_info "Installing DAB (Debian Appliance Builder)..."
    apt-get update
    apt-get install -y dab
fi

# Welcome message
print_step "Debian 13 LXC Container Creator"
echo "This script creates a Debian 13 template using DAB and then creates an LXC container from it."
echo "Note: Console issues may occur due to AppArmor compatibility."
echo ""

# Template storage selection first
print_step "Template Storage Selection"
print_info "Available storages for templates (directory-based storages):"
TEMPLATE_STORAGES=$(pvesm status -content vztmpl | grep -v "^NAME" | awk '{print $1 " (" $2 ")"}')

if [[ -z "$TEMPLATE_STORAGES" ]]; then
    print_warning "No template-capable storages found. Showing all directory storages:"
    pvesm status | grep -E "dir|nfs|cifs" | awk '{print $1 " (" $2 ")"}'
    echo ""
    print_info "Note: Template storage must support directory-based files (not block storage like RBD)"
else
    echo "$TEMPLATE_STORAGES"
fi
echo ""

read -p "$(print_prompt "Storage for template (default: local): ")" TEMPLATE_STORAGE
TEMPLATE_STORAGE=${TEMPLATE_STORAGE:-local}

# Verify template storage exists and can store templates
if ! pvesm status | grep -q "^$TEMPLATE_STORAGE"; then
    print_error "Template storage '$TEMPLATE_STORAGE' not found!"
    exit 1
fi

# Check if storage can handle templates (not block storage)
STORAGE_TYPE=$(pvesm status | grep "^$TEMPLATE_STORAGE" | awk '{print $2}')
if [[ "$STORAGE_TYPE" =~ ^(rbd|zfs)$ ]]; then
    print_error "Storage '$TEMPLATE_STORAGE' ($STORAGE_TYPE) cannot store template files!"
    print_info "Template storage must be directory-based (dir, nfs, cifs, etc.)"
    exit 1
fi

# Get storage path
get_storage_path() {
    local storage="$1"
    local resolved_path=""
    
    if [[ "$storage" == "local" ]]; then
        echo "/var/lib/vz/template/cache"
        return 0
    fi
    
    # Method 1: Try to get path from storage configuration
    if grep -q "^$storage:" /etc/pve/storage.cfg; then
        local storage_type=$(grep "^$storage:" /etc/pve/storage.cfg | grep -oP 'type\s+\K\w+' || echo "unknown")
        
        case "$storage_type" in
            "dir")
                resolved_path=$(grep -A 5 "^$storage:" /etc/pve/storage.cfg | grep -oP 'path\s+\K.*' | head -1)
                if [[ -n "$resolved_path" ]]; then
                    resolved_path="$resolved_path/template/cache"
                fi
                ;;
            "cifs"|"nfs")
                # Try to find mount point from df
                resolved_path=$(df -t cifs,nfs | awk -v storage="$storage" '$1 ~ storage || $6 ~ storage {print $6}' | head -1)
                if [[ -n "$resolved_path" ]]; then
                    resolved_path="$resolved_path/template/cache"
                fi
                ;;
        esac
    fi
    
    # Method 2: Check if storage is mounted and try common patterns
    if [[ -z "$resolved_path" ]]; then
        for pattern in "/mnt/pve/$storage" "/mnt/$storage" "/var/lib/vz/$storage" "/media/$storage"; do
            if [[ -d "$pattern" ]]; then
                resolved_path="$pattern/template/cache"
                break
            fi
        done
    fi
    
    if [[ -n "$resolved_path" ]]; then
        echo "$resolved_path"
        return 0
    else
        return 1
    fi
}

print_info "Resolving template storage path for '$TEMPLATE_STORAGE'..."
if TEMPLATE_STORAGE_PATH=$(get_storage_path "$TEMPLATE_STORAGE"); then
    print_info "Resolved path: $TEMPLATE_STORAGE_PATH"
else
    print_warning "Unable to automatically resolve storage path for '$TEMPLATE_STORAGE'"
    print_info "Please provide the full path where templates should be stored:"
    read -p "$(print_prompt "Template storage path: ")" TEMPLATE_STORAGE_PATH
    
    if [[ -z "$TEMPLATE_STORAGE_PATH" ]]; then
        print_error "Template storage path is required"
        exit 1
    fi
    
    # Append template/cache if user didn't include it
    if [[ ! "$TEMPLATE_STORAGE_PATH" =~ template.cache$ ]]; then
        TEMPLATE_STORAGE_PATH="$TEMPLATE_STORAGE_PATH/template/cache"
    fi
    
    print_info "Using manual path: $TEMPLATE_STORAGE_PATH"
fi

# Check for existing Debian 13 templates in selected storage
print_step "Template Check in Selected Storage"
DEBIAN13_TEMPLATES=$(find "$TEMPLATE_STORAGE_PATH" -name "*debian*13*" -o -name "*trixie*" 2>/dev/null || true)

USE_EXISTING=false
TEMPLATE_PATH=""

if [[ -n "$DEBIAN13_TEMPLATES" ]]; then
    TEMPLATE_PATH=$(echo "$DEBIAN13_TEMPLATES" | head -1)
    print_info "Found existing Debian 13 template: $(basename "$TEMPLATE_PATH")"
    print_info "Using existing template automatically"
    USE_EXISTING=true
else
    print_info "No existing Debian 13 template found"
    print_info "Will create new template using official DAB configuration"
fi

# Container storage selection
print_step "Container Storage"
print_info "Available storages:"
pvesm status | grep -E "^(NAME|local|datastore|tank)" || pvesm status | head -10
echo ""
read -p "$(print_prompt "Storage for container (default: local): ")" CONTAINER_STORAGE
CONTAINER_STORAGE=${CONTAINER_STORAGE:-local}

# Verify storage exists
if ! pvesm status | grep -q "^$CONTAINER_STORAGE"; then
    print_error "Storage '$CONTAINER_STORAGE' not found!"
    exit 1
fi

print_step "Container Configuration"

# Container hostname
read -p "$(print_prompt "Container hostname: ")" HOSTNAME
if [[ -z "$HOSTNAME" ]]; then
    print_error "Hostname is required!"
    exit 1
fi

# Get next available container ID using Proxmox API
NEXT_AVAILABLE_ID=$(pvesh get cluster/nextid)
if [[ -z "$NEXT_AVAILABLE_ID" ]]; then
    print_error "Unable to get next available container ID"
    exit 1
fi

while true; do
    read -p "$(print_prompt "Container ID (default: $NEXT_AVAILABLE_ID): ")" CTID
    CTID=${CTID:-$NEXT_AVAILABLE_ID}
    if [[ "$CTID" =~ ^[0-9]+$ ]] && [[ $CTID -ge 100 ]] && [[ $CTID -le 999999999 ]]; then
        if pct status "$CTID" &>/dev/null || qm status "$CTID" &>/dev/null; then
            print_error "ID $CTID already exists (LXC container or VM)!"
            # Get next available ID again
            NEXT_AVAILABLE_ID=$(pvesh get cluster/nextid)
            continue
        fi
        break
    else
        print_error "Please enter a valid container ID (100-999999999)"
    fi
done

# Privileged vs Unprivileged
while true; do
    read -p "$(print_prompt "Container type - [P]rivileged or [U]nprivileged (default: U): ")" CONTAINER_TYPE
    CONTAINER_TYPE=${CONTAINER_TYPE:-U}
    case ${CONTAINER_TYPE^^} in
        P|PRIVILEGED)
            PRIVILEGED="1"
            print_warning "Privileged containers have security implications!"
            break
            ;;
        U|UNPRIVILEGED)
            PRIVILEGED="0"
            break
            ;;
        *)
            print_error "Please enter P or U"
            ;;
    esac
done

# Root password with confirmation
while true; do
    read -s -p "$(print_prompt "Root password: ")" ROOT_PASSWORD
    echo ""
    if [[ ${#ROOT_PASSWORD} -lt 8 ]]; then
        print_error "Password must be at least 8 characters long"
        continue
    fi
    
    read -s -p "$(print_prompt "Confirm password: ")" ROOT_PASSWORD_CONFIRM
    echo ""
    
    if [[ "$ROOT_PASSWORD" == "$ROOT_PASSWORD_CONFIRM" ]]; then
        break
    else
        print_error "Passwords do not match. Please try again."
    fi
done

# Disk size
read -p "$(print_prompt "Disk size in GB (default: 8): ")" DISK_SIZE
DISK_SIZE=${DISK_SIZE:-8}

# Network configuration
print_step "Network Configuration"

# Network bridge
print_info "Available network bridges:"
ip link show | grep "^[0-9].*: vmbr" | cut -d: -f2 | sed 's/^ //' | sort
echo ""
read -p "$(print_prompt "Network bridge (default: vmbr0): ")" NET_BRIDGE
NET_BRIDGE=${NET_BRIDGE:-vmbr0}

# IP configuration
while true; do
    read -p "$(print_prompt "IP configuration - [D]HCP or [S]tatic (default: D): ")" IP_TYPE
    IP_TYPE=${IP_TYPE:-D}
    case ${IP_TYPE^^} in
        D|DHCP)
            NET_CONFIG="dhcp"
            break
            ;;
        S|STATIC)
            read -p "$(print_prompt "IP address (e.g., 192.168.1.100/24): ")" IP_ADDR
            read -p "$(print_prompt "Gateway (e.g., 192.168.1.1): ")" GATEWAY
            NET_CONFIG="ip=$IP_ADDR,gw=$GATEWAY"
            break
            ;;
        *)
            print_error "Please enter D or S"
            ;;
    esac
done

# VLAN (optional)
read -p "$(print_prompt "VLAN tag (optional, press Enter to skip): ")" VLAN
if [[ -n "$VLAN" ]]; then
    NET_CONFIG="$NET_CONFIG,tag=$VLAN"
fi

# MTU (optional)
read -p "$(print_prompt "MTU (optional, press Enter to skip): ")" MTU
if [[ -n "$MTU" ]]; then
    NET_CONFIG="$NET_CONFIG,mtu=$MTU"
fi

# DNS configuration
read -p "$(print_prompt "DNS servers (default: 1.1.1.1,8.8.8.8): ")" DNS_SERVERS
DNS_SERVERS=${DNS_SERVERS:-1.1.1.1,8.8.8.8}

read -p "$(print_prompt "DNS search domain (optional, press Enter to skip): ")" DNS_SEARCH

# Summary
print_step "Configuration Summary"
if [[ "$USE_EXISTING" = true ]]; then
    echo "Template: $(basename "$TEMPLATE_PATH") (existing)"
else
    echo "Template: Will create versioned template from DAB config"
    echo "Template Storage: $TEMPLATE_STORAGE"
fi
echo "Container Storage: $CONTAINER_STORAGE"
echo "Hostname: $HOSTNAME"
echo "Container ID: $CTID"
echo "Type: $([ "$PRIVILEGED" = "1" ] && echo "Privileged" || echo "Unprivileged")"
echo "Disk Size: ${DISK_SIZE}GB"
echo "Network: $NET_BRIDGE ($NET_CONFIG)"
echo "DNS: $DNS_SERVERS"
[[ -n "$DNS_SEARCH" ]] && echo "DNS Search: $DNS_SEARCH"
echo ""

read -p "$(print_prompt "Continue with container creation? [y/N]: ")" CONFIRM
if [[ ! "${CONFIRM^^}" =~ ^(Y|YES)$ ]]; then
    print_info "Aborted by user"
    exit 0
fi

# Create template only if not using existing - SINGLE TEMPLATE CREATION
if [[ "$USE_EXISTING" = false ]]; then
    print_info "Creating Debian 13 template..."
    
    # Create working directory
    WORK_DIR="/tmp/dab-debian13-$$"
    mkdir -p "$WORK_DIR/debian-13-standard"
    cd "$WORK_DIR/debian-13-standard"
    
    # Download and parse DAB configuration
    if ! wget -q https://raw.githubusercontent.com/proxmox/dab-pve-appliances/refs/heads/master/debian-13-trixie-std-64/dab.conf; then
        print_error "Failed to download DAB configuration"
        exit 1
    fi
    
    # Parse version information from dab.conf
    DAB_NAME=$(grep -E "^Name:" dab.conf | cut -d' ' -f2- | tr -d ' ')
    DAB_VERSION=$(grep -E "^Version:" dab.conf | cut -d' ' -f2- | tr -d ' ')
    DAB_ARCH=$(grep -E "^Architecture:" dab.conf | cut -d' ' -f2- | tr -d ' ')
    
    if [[ -n "$DAB_NAME" && -n "$DAB_VERSION" && -n "$DAB_ARCH" ]]; then
        VERSIONED_TEMPLATE_NAME="${DAB_NAME}_${DAB_VERSION}_${DAB_ARCH}"
    else
        VERSIONED_TEMPLATE_NAME="debian-13-standard_$(date +%Y%m%d)"
    fi
    
    print_info "Building template: $VERSIONED_TEMPLATE_NAME"
    
    # Build template (silent)
    dab init >/dev/null 2>&1
    dab bootstrap >/dev/null 2>&1
    dab finalize >/dev/null 2>&1
    
    # Find and move template
    TEMPLATE_FILE=$(find . -name "*.tar.zst" -o -name "*.tar.gz" -o -name "*.tar.xz" | head -1)
    if [[ -z "$TEMPLATE_FILE" ]]; then
        print_error "Template file not found!"
        rm -rf "$WORK_DIR"
        exit 1
    fi
    
    TEMPLATE_PATH="$TEMPLATE_STORAGE_PATH/${VERSIONED_TEMPLATE_NAME}.tar.zst"
    mkdir -p "$TEMPLATE_STORAGE_PATH"
    
    # Backup existing if present
    if [[ -f "$TEMPLATE_PATH" ]]; then
        mv "$TEMPLATE_PATH" "${TEMPLATE_PATH}.backup.$(date +%s)"
    fi
    
    mv "$TEMPLATE_FILE" "$TEMPLATE_PATH"
    
    # Cleanup
    cd /
    rm -rf "$WORK_DIR"
    rm -f /tmp/dab-debian13-* 2>/dev/null || true
    
    TEMPLATE_SIZE=$(du -h "$TEMPLATE_PATH" | cut -f1)
    print_info "Template created: $VERSIONED_TEMPLATE_NAME (Size: $TEMPLATE_SIZE)"
fi

print_step "Creating Container"

# Build pct create command
PCT_CMD="pct create $CTID $TEMPLATE_PATH"
PCT_CMD="$PCT_CMD --hostname $HOSTNAME"
PCT_CMD="$PCT_CMD --password"
PCT_CMD="$PCT_CMD --storage $CONTAINER_STORAGE"
PCT_CMD="$PCT_CMD --rootfs ${DISK_SIZE}"
PCT_CMD="$PCT_CMD --cores 1"
PCT_CMD="$PCT_CMD --memory 512"
PCT_CMD="$PCT_CMD --net0 name=eth0,bridge=$NET_BRIDGE,$NET_CONFIG"
PCT_CMD="$PCT_CMD --nameserver $DNS_SERVERS"
PCT_CMD="$PCT_CMD --ostype debian"
PCT_CMD="$PCT_CMD --arch amd64"

if [[ "$PRIVILEGED" = "1" ]]; then
    PCT_CMD="$PCT_CMD --unprivileged 0"
else
    PCT_CMD="$PCT_CMD --unprivileged 1"
fi

if [[ -n "$DNS_SEARCH" ]]; then
    PCT_CMD="$PCT_CMD --searchdomain $DNS_SEARCH"
fi

print_info "Creating container with command:"
echo "$PCT_CMD"

# Create container with password input (handle special characters properly)
{
    echo "$ROOT_PASSWORD"
    echo "$ROOT_PASSWORD"  # Confirmation if needed
} | $PCT_CMD

# Set AppArmor profile BEFORE starting container (based on findings)
print_info "Configuring AppArmor profile and features before start..."

# Set AppArmor to unconfined by editing container configuration directly
CONFIG_FILE="/etc/pve/lxc/${CTID}.conf"
if [[ -f "$CONFIG_FILE" ]]; then
    # Add nesting feature
    echo "features: nesting=1" >> "$CONFIG_FILE"
    
    # Add or update AppArmor profile in config
    if grep -q "lxc.apparmor.profile" "$CONFIG_FILE"; then
        sed -i 's/lxc.apparmor.profile.*/lxc.apparmor.profile: unconfined/' "$CONFIG_FILE"
    else
        echo "lxc.apparmor.profile: unconfined" >> "$CONFIG_FILE"
    fi
    print_info "AppArmor profile set to unconfined and nesting enabled"
else
    print_warning "Could not find container config file: $CONFIG_FILE"
fi

# Start container
print_info "Starting container..."
pct start "$CTID"

# Wait for container to boot
print_info "Waiting for container to boot..."
sleep 10

# Apply console fix for AppArmor compatibility issues
print_step "Applying Console Compatibility Fixes"
print_warning "Applying fixes for known AppArmor/console issues with Debian 13"

# Fix getty services (similar to upgrade script)
pct exec "$CTID" -- bash -c "
    # Remove ImportCredential directives that cause issues
    if [ -f /lib/systemd/system/console-getty.service ]; then
        sed -i '/^ImportCredential=/d' /lib/systemd/system/console-getty.service
    fi
    if [ -f /lib/systemd/system/container-getty@.service ]; then
        sed -i '/^ImportCredential=/d' /lib/systemd/system/container-getty@.service
    fi
    
    # Reload systemd
    systemctl daemon-reload
    
    # Enable and restart getty services
    systemctl enable console-getty.service
    systemctl enable container-getty@1.service
    systemctl restart console-getty.service 2>/dev/null || true
    systemctl restart container-getty@1.service 2>/dev/null || true
"

# Update packages
print_info "Updating packages in container..."
pct exec "$CTID" -- bash -c "
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get upgrade -y
    apt-get install -y curl wget sudo vim
    echo 'Container setup completed' > /etc/motd
"

# Container configuration is already complete - no restart needed

# Final status
print_step "Container Creation Completed"
print_info "Container ID: $CTID"
print_info "Container Status: $(pct status "$CTID")"
print_info "Template Used: $(basename "$TEMPLATE_PATH")"
print_info ""
print_info "Container is ready to use!"
print_warning "Note: Console access may require additional testing due to Debian 13 AppArmor compatibility"
print_info ""
print_info "Access container:"
print_info "  pct enter $CTID"
print_info ""
print_info "Or via console (if working):"
print_info "  pct console $CTID"