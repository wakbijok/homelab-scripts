#!/bin/bash
# LXC Debian 13 (Trixie) Upgrade Script
# Upgrades LXC containers from Debian 12 (bookworm) to Debian 13 (trixie)
# 
# IMPORTANT: This script must be run directly on a Proxmox node
# PREREQUISITE: Containers must be organized in resource pools before running

set -euo pipefail

# Default configuration
BACKUP_STORAGE=""
RESOURCE_POOL=""
LOG_FILE="/tmp/lxc-upgrade-$(date +%Y%m%d-%H%M%S).log"

# Load configuration if available
if [[ -f "$(dirname "$0")/../config.sh" ]]; then
    source "$(dirname "$0")/../config.sh"
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" | tee -a "$LOG_FILE"
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1" | tee -a "$LOG_FILE"
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1" | tee -a "$LOG_FILE"
}

info() {
    echo -e "${BLUE}[INFO]${NC} $1" | tee -a "$LOG_FILE"
}

usage() {
    cat << EOF
LXC Debian 13 Upgrade Script

PREREQUISITES:
    - Script must be run directly on a Proxmox node
    - LXC containers must be organized in resource pools
    - Passwordless access to containers (if needed)

Usage: $0 [OPTIONS] [VMID1 VMID2 ...]

Upgrade LXC containers from Debian 12 to Debian 13.

OPTIONS:
    -n, --dry-run           Show what would be done without executing
    -f, --force             Skip confirmation prompts
    -s, --skip-backup       Skip backup creation (not recommended)
    --security-mode MODE    AppArmor security mode: 'unconfined' or 'custom' (default: unconfined)
    -h, --help              Show this help message

EXAMPLES:
    $0                  # Interactive mode - select pool and containers (unconfined)
    $0 --security-mode custom 301  # Upgrade with custom AppArmor profile (recommended)
    $0 --dry-run        # Show what would be upgraded
    $0 -f --skip-backup 301  # Force upgrade container 301 without backup

BEFORE RUNNING:
    1. Ensure all containers are organized in resource pools
       Example: pvesh set /pools/Media-Server -vms 300,301,302,303,304,305,306,308
    
    2. Verify backup storage is available
       Example: pvesm status
EOF
}

check_prerequisites() {
    info "Checking prerequisites..."
    
    # Check if running on Proxmox node
    if ! command -v pvesh >/dev/null 2>&1; then
        error "This script must be run on a Proxmox node (pvesh command not found)"
        error "Please run this script directly on one of your Proxmox nodes"
        exit 1
    fi
    
    # Check if pct command is available
    if ! command -v pct >/dev/null 2>&1; then
        error "Proxmox container tools not found (pct command not found)"
        exit 1
    fi
    
    success "Running on Proxmox node - prerequisites OK"
}

get_containers_in_pool() {
    local pool=$1
    
    # Get all pool members first to show what's being filtered
    local json_data
    json_data=$(pvesh get /pools/$pool --output-format json 2>/dev/null) || {
        error "Failed to get pool members from pool $pool" >&2
        return 1
    }
    
    # Show VMs that will be skipped (informational)
    local vm_count=0
    if command -v jq >/dev/null 2>&1; then
        vm_count=$(echo "$json_data" | jq -r '.members[] | select(.type == "qemu") | "\(.vmid):\(.name):\(.node)"' 2>/dev/null | wc -l)
        if [[ $vm_count -gt 0 ]]; then
            warning "Skipping $vm_count VM(s) in pool $pool (this script only processes LXC containers):" >&2
            echo "$json_data" | jq -r '.members[] | select(.type == "qemu") | "  - VM \(.vmid) (\(.name)) on \(.node)"' 2>/dev/null >&2
        fi
        
        # Return LXC containers
        echo "$json_data" | jq -r '.members[] | select(.type == "lxc") | "\(.vmid):\(.name):\(.node)"' 2>/dev/null && return 0
    fi
    
    # Fallback: manual parsing
    # Check for VMs to skip (manual detection)
    local vm_lines
    vm_lines=$(echo "$json_data" | grep -o '"id":"qemu/[0-9]*"[^}]*"name":"[^"]*"[^}]*"node":"[^"]*"' || true)
    if [[ -n "$vm_lines" ]]; then
        vm_count=$(echo "$vm_lines" | wc -l)
        warning "Skipping $vm_count VM(s) in pool $pool (this script only processes LXC containers):" >&2
        echo "$vm_lines" | while read -r line; do
            local vmid=$(echo "$line" | sed -n 's/.*"id":"qemu\/\([0-9]*\)".*/\1/p')
            local name=$(echo "$line" | sed -n 's/.*"name":"\([^"]*\)".*/\1/p')
            local node=$(echo "$line" | sed -n 's/.*"node":"\([^"]*\)".*/\1/p')
            warning "  - VM $vmid ($name) on $node" >&2
        done
    fi
    
    # Extract LXC containers using sed and grep (bash-only parsing)
    echo "$json_data" | grep -o '"id":"lxc/[0-9]*"[^}]*"name":"[^"]*"[^}]*"node":"[^"]*"' | while read -r line; do
        local vmid=$(echo "$line" | sed -n 's/.*"id":"lxc\/\([0-9]*\)".*/\1/p')
        local name=$(echo "$line" | sed -n 's/.*"name":"\([^"]*\)".*/\1/p')
        local node=$(echo "$line" | sed -n 's/.*"node":"\([^"]*\)".*/\1/p')
        echo "${vmid}:${name}:${node}"
    done
}

check_container_debian_version() {
    local vmid=$1
    local node=${2:-}
    
    local version
    if [[ -n "$node" ]]; then
        # For containers on remote nodes, SSH to the node first using IP address
        local node_ip
        node_ip=$(get_node_ip "$node")
        version=$(ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o BatchMode=yes "root@$node_ip" "pct exec $vmid -- cat /etc/debian_version 2>/dev/null") || {
            info "Failed to check Debian version for container $vmid on node $node (might be stopped or unreachable)"
            echo "unknown"
            return 0
        }
    else
        # Local container
        version=$(pct exec $vmid -- cat /etc/debian_version 2>/dev/null) || {
            info "Failed to check Debian version for container $vmid (might be stopped)"
            echo "unknown"
            return 0
        }
    fi
    
    echo "$version"
}

# Helper function to resolve node names to IP addresses
get_node_ip() {
    local node_name=$1
    
    # Check if it's already an IP address
    if [[ $node_name =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$node_name"
        return 0
    fi
    
    # First try to get IP from corosync configuration (most reliable)
    local node_ip
    node_ip=$(awk "/name: $node_name/,/ring0_addr:/" /etc/pve/corosync.conf 2>/dev/null | grep "ring0_addr:" | awk '{print $2}' | head -1)
    
    if [[ -n "$node_ip" && "$node_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$node_ip"
        return 0
    fi
    
    # Fallback: try pvesh get /nodes (alternative API method)  
    node_ip=$(pvesh get /nodes --output-format json 2>/dev/null | grep -A3 "\"node\":\"$node_name\"" | grep "\"ip\":" | cut -d'"' -f4 | head -1)
    
    if [[ -n "$node_ip" && "$node_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$node_ip"
        return 0
    fi
    
    # If all else fails, try the hostname (might work in some DNS-configured environments)
    warning "Could not resolve IP for node $node_name, trying hostname"
    echo "$node_name"
}

# Helper function to execute commands in containers (local or remote)
pct_exec_with_node() {
    local vmid=$1
    local node_name=$2
    shift 2  # Remove vmid and node_name from arguments
    
    local current_node
    current_node=$(hostname)
    
    if [[ -n "$node_name" && "$node_name" != "$current_node" ]]; then
        # Remote container - SSH to node using IP address
        local node_ip
        node_ip=$(get_node_ip "$node_name")
        # Use printf %q to properly quote the command for SSH
        local quoted_cmd
        printf -v quoted_cmd '%q ' "$@"
        ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o BatchMode=yes "root@$node_ip" "pct exec $vmid -- $quoted_cmd"
    else
        # Local container
        pct exec $vmid -- "$@"
    fi
}

create_backup() {
    local vmid=$1
    local container_name=$2
    local node_name=$3
    
    if [[ $SKIP_BACKUP == true ]]; then
        warning "Skipping backup for container $vmid ($container_name) as requested"
        return 0
    fi
    
    info "Creating backup for container $vmid ($container_name) on node $node_name..."
    info "Backup command: vzdump $vmid --storage $BACKUP_STORAGE --compress gzip --mode snapshot"
    info "This may take a few minutes depending on container size..."
    
    local current_node
    current_node=$(hostname)
    
    local backup_cmd="vzdump $vmid --storage \"$BACKUP_STORAGE\" --compress gzip --mode snapshot --notes \"Pre-Debian-13-upgrade-backup-$(date +%Y%m%d-%H%M%S)\""
    
    if [[ -n "$node_name" && "$node_name" != "$current_node" ]]; then
        # Remote backup - SSH to the node where container resides
        local node_ip
        node_ip=$(get_node_ip "$node_name")
        info "Running backup on remote node $node_name ($node_ip)..."
        
        ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o BatchMode=yes "root@$node_ip" "$backup_cmd" 2>&1 | while IFS= read -r line; do
            echo "$line"
            # Log important progress lines
            if [[ "$line" =~ (INFO|ERROR|archive) ]]; then
                info "Backup: $line"
            fi
        done
        
        local backup_status=${PIPESTATUS[0]}
    else
        # Local backup
        info "Running backup on local node..."
        eval "$backup_cmd" 2>&1 | while IFS= read -r line; do
            echo "$line"
            if [[ "$line" =~ (INFO|ERROR|archive) ]]; then
                info "Backup: $line"
            fi
        done
        
        local backup_status=${PIPESTATUS[0]}
    fi
    
    if [[ $backup_status -ne 0 ]]; then
        error "Backup failed for container $vmid (exit code: $backup_status)"
        return 1
    fi
    
    # Verify backup was created on the correct node
    info "Verifying backup was created..."
    local backup_list
    if [[ -n "$node_name" && "$node_name" != "$current_node" ]]; then
        local node_ip
        node_ip=$(get_node_ip "$node_name")
        backup_list=$(ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o BatchMode=yes "root@$node_ip" "pvesh get /nodes/$node_name/storage/$BACKUP_STORAGE/content --content backup | grep \"vzdump-lxc-$vmid\" | tail -1" 2>/dev/null)
    else
        backup_list=$(pvesh get /nodes/$current_node/storage/$BACKUP_STORAGE/content --content backup | grep "vzdump-lxc-$vmid" | tail -1)
    fi
    
    if [[ -n "$backup_list" ]]; then
        success "Backup completed and verified for container $vmid"
        info "Backup details: $backup_list"
    else
        warning "Backup completed but verification failed - this may be normal in some cluster configurations"
        warning "Please verify manually that backup was created in $BACKUP_STORAGE"
    fi
}

wait_for_upgrade_completion() {
    local vmid=$1
    local node_name=${2:-}
    local max_wait=1800  # 30 minutes max
    local wait_count=0
    
    info "Waiting for all apt/dpkg processes to complete in container $vmid..."
    
    while [[ $wait_count -lt $max_wait ]]; do
        if ! pct_exec_with_node $vmid "$node_name" pgrep -f "apt|dpkg" >/dev/null 2>&1; then
            success "All upgrade processes completed in container $vmid"
            return 0
        fi
        
        if [[ $((wait_count % 60)) -eq 0 ]]; then
            info "Still waiting for upgrade processes to complete... ($((wait_count/60)) minutes elapsed)"
            info "Checking active processes..."
            pct_exec_with_node $vmid "$node_name" ps aux | grep -E "(apt|dpkg)" | grep -v grep || true
        fi
        
        sleep 1
        ((wait_count++))
    done
    
    error "Timeout waiting for upgrade processes to complete in container $vmid"
    return 1
}

fix_apparmor_profile_pre_upgrade() {
    local vmid=$1
    local container_name=$2
    
    # Check if config file exists locally, if not skip AppArmor fix
    local config_file="/etc/pve/lxc/$vmid.conf"
    if [[ ! -f "$config_file" ]]; then
        warning "Config file $config_file not accessible from this node"
        warning "Skipping AppArmor pre-configuration - will handle during upgrade if needed"
        return 0
    fi
    
    info "Pre-configuring AppArmor profile for container $vmid ($container_name)..."
    
    # Check current AppArmor profile
    local current_profile
    current_profile=$(grep "lxc.apparmor.profile" "$config_file" | head -1 | cut -d':' -f2 | xargs 2>/dev/null || echo "")
    
    if [[ "$current_profile" == "unconfined" ]]; then
        info "Container $vmid already has unconfined AppArmor profile"
        return 0
    fi
    
    # Add unconfined profile without restarting container
    grep -v "lxc.apparmor.profile" "$config_file" > "$config_file.tmp" && \
    echo "lxc.apparmor.profile: unconfined" >> "$config_file.tmp" && \
    mv "$config_file.tmp" "$config_file" || {
        error "Failed to update AppArmor profile for container $vmid"
        return 1
    }
    
    success "AppArmor profile pre-configured for container $vmid (will take effect after next restart)"
}

fix_apparmor_profile() {
    local vmid=$1
    local container_name=$2
    local config_file="/etc/pve/lxc/$vmid.conf"
    
    info "Fixing AppArmor profile for container $vmid ($container_name)..."
    
    # Check current AppArmor profile
    local current_profile
    current_profile=$(grep "lxc.apparmor.profile" "$config_file" | head -1 | cut -d':' -f2 | xargs 2>/dev/null || echo "")
    
    if [[ "$current_profile" == "unconfined" ]]; then
        info "Container $vmid already has unconfined AppArmor profile"
        return 0
    fi
    
    # Backup config file
    cp "$config_file" "$config_file.apparmor-backup-$(date +%Y%m%d-%H%M%S)" || {
        warning "Failed to backup config file for container $vmid"
    }
    
    # Update AppArmor configuration
    grep -v "lxc.apparmor" "$config_file" > "$config_file.tmp" && \
    echo "lxc.apparmor.profile: unconfined" >> "$config_file.tmp" && \
    mv "$config_file.tmp" "$config_file" || {
        warning "Failed to update AppArmor profile for container $vmid"
        return 1
    }
    
    success "AppArmor profile updated to unconfined for container $vmid"
    
    # Restart container to apply AppArmor changes
    local was_running=false
    if pct status "$vmid" | grep -q "status: running"; then
        was_running=true
        info "Restarting container $vmid to apply AppArmor changes..."
        pct stop "$vmid" || {
            warning "Graceful stop failed, forcing stop..."
            pct shutdown "$vmid" --forceStop 1
        }
        sleep 2
        pct start "$vmid" || {
            error "Failed to restart container $vmid"
            return 1
        }
        
        # Wait for container to be ready
        local max_wait=30
        local wait_count=0
        while [[ $wait_count -lt $max_wait ]]; do
            if pct status "$vmid" | grep -q "status: running"; then
                break
            fi
            sleep 1
            ((wait_count++))
        done
        
        # Verify AppArmor profile is actually applied
        sleep 5  # Give container time to fully initialize
        local actual_profile
        actual_profile=$(pct exec "$vmid" -- cat /proc/self/attr/current 2>/dev/null || echo "unknown")
        if [[ "$actual_profile" == "unconfined" ]]; then
            success "AppArmor profile verified as unconfined for container $vmid"
        else
            warning "AppArmor profile verification failed for container $vmid (got: $actual_profile)"
            # Try to fix it again
            info "Re-applying AppArmor configuration..."
            grep -v "lxc.apparmor" "$config_file" > "$config_file.tmp" && \
            echo "lxc.apparmor.profile = unconfined" >> "$config_file.tmp" && \
            mv "$config_file.tmp" "$config_file"
        fi
    else
        warning "Container $vmid is not running - AppArmor changes will take effect on next start"
    fi
}

fix_getty_services() {
    local vmid=$1
    local container_name=$2
    
    info "Fixing getty services for Debian 13 compatibility in container $vmid ($container_name)..."
    
    # Create override directories
    pct exec "$vmid" -- mkdir -p /etc/systemd/system/console-getty.service.d || {
        warning "Failed to create console-getty override directory"
        return 1
    }
    
    pct exec "$vmid" -- mkdir -p /etc/systemd/system/container-getty@.service.d || {
        warning "Failed to create container-getty override directory"
        return 1
    }
    
    # Create override for console-getty.service to remove ImportCredential
    pct exec "$vmid" -- tee /etc/systemd/system/console-getty.service.d/lxc-override.conf > /dev/null << 'EOF' || {
[Service]
# Remove ImportCredential directives for LXC compatibility
ImportCredential=
EOF
        warning "Failed to create console-getty override"
        return 1
    }
    
    # Create override for container-getty@.service to remove ImportCredential
    pct exec "$vmid" -- tee /etc/systemd/system/container-getty@.service.d/lxc-override.conf > /dev/null << 'EOF' || {
[Service]
# Remove ImportCredential directives for LXC compatibility
ImportCredential=
EOF
        warning "Failed to create container-getty override"
        return 1
    }
    
    # Reload systemd and restart services
    pct exec "$vmid" -- systemctl daemon-reload || {
        warning "Failed to reload systemd daemon in container $vmid"
        return 1
    }
    
    # Restart getty services
    pct exec "$vmid" -- systemctl restart console-getty.service || {
        warning "Failed to restart console-getty.service"
    }
    
    pct exec "$vmid" -- systemctl restart container-getty@1.service container-getty@2.service || {
        warning "Failed to restart container-getty services"
    }
    
    # Verify services are running
    local console_status container1_status container2_status
    console_status=$(pct exec "$vmid" -- systemctl is-active console-getty.service 2>/dev/null || echo "failed")
    container1_status=$(pct exec "$vmid" -- systemctl is-active container-getty@1.service 2>/dev/null || echo "failed")
    container2_status=$(pct exec "$vmid" -- systemctl is-active container-getty@2.service 2>/dev/null || echo "failed")
    
    if [[ "$console_status" == "active" && "$container1_status" == "active" && "$container2_status" == "active" ]]; then
        success "Getty services fixed - console access should now work for container $vmid"
    else
        warning "Some getty services may still have issues (console: $console_status, tty1: $container1_status, tty2: $container2_status)"
    fi
    
    return 0
}

create_custom_apparmor_profile() {
    local profile_name="lxc-debian13-homelab"
    local profile_path="/etc/apparmor.d/lxc-$profile_name"
    
    # Check if profile already exists
    if [[ -f "$profile_path" ]]; then
        info "Custom AppArmor profile already exists"
        return 0
    fi
    
    info "Creating custom AppArmor profile for Debian 13 containers..."
    
    cat > "$profile_path" << 'EOF'
# Custom LXC AppArmor profile for Debian 13 containers
# Community solution for systemd 257 compatibility
# More secure alternative to unconfined profile

#include <tunables/global>

profile lxc-debian13-homelab flags=(attach_disconnected,mediate_deleted) {
  #include <abstractions/lxc/container-base>
  
  # Allow systemd mount operations (Debian 13 requirement)
  mount fstype=tmpfs,
  mount fstype=proc,
  mount fstype=sysfs,
  mount fstype=devpts,
  mount fstype=devtmpfs,
  mount options=(rw,rslave),
  mount options=(rw,rbind),
  mount options=(rw,move),
  mount options=(ro,remount,bind),
  
  # Allow access to systemd directories
  /dev/hugepages/ rw,
  /tmp/ rw,
  /run/lock/ rw,
  /dev/mqueue/ rw,
  /run/systemd/mount-rootfs/ rw,
  /run/rpc_pipefs/ rw,
  
  # Network access for services
  network inet,
  network inet6,
  network netlink,
  
  # Signal handling for process management
  signal (send,receive),
  
  # Required capabilities for systemd
  capability sys_admin,
  capability dac_override,
  capability setuid,
  capability setgid,
  capability net_admin,
  capability sys_chroot,
  capability mknod,
  capability audit_write,
  
  # Security: Explicitly deny dangerous operations
  deny /sys/kernel/security/** w,
  deny /proc/sys/kernel/core_pattern w,
  deny /proc/sys/kernel/modprobe w,
  deny /proc/sysrq-trigger w,
  deny /sys/firmware/** w,
  deny /sys/devices/virtual/powercap/** w,
}
EOF

    # Load the profile
    if apparmor_parser -r "$profile_path" 2>/dev/null; then
        success "Custom AppArmor profile created and loaded"
        return 0
    else
        warning "Failed to load custom AppArmor profile, falling back to unconfined"
        rm -f "$profile_path" 2>/dev/null
        return 1
    fi
}

apply_custom_apparmor_profile() {
    local vmid=$1
    local container_name=$2
    local config_file="/etc/pve/lxc/$vmid.conf"
    
    info "Applying custom AppArmor profile to container $vmid ($container_name)..."
    
    # Update AppArmor profile (no backup needed for PVE config, it's automatically versioned)
    grep -v "lxc.apparmor.profile" "$config_file" > "$config_file.tmp" && \
    echo "lxc.apparmor.profile: lxc-debian13-homelab" >> "$config_file.tmp" && \
    mv "$config_file.tmp" "$config_file" || {
        warning "Failed to update custom AppArmor profile for container $vmid"
        return 1
    }
    
    success "Custom AppArmor profile applied to container $vmid"
    info "This provides better security than unconfined while fixing Debian 13 issues"
}

upgrade_container() {
    local vmid=$1
    local container_name=$2
    local node_name=$3
    
    info "============================================"
    info "STARTING UPGRADE: Container $vmid ($container_name) on $node_name"
    info "============================================"
    
    # Check current Debian version
    local current_version
    current_version=$(check_container_debian_version "$vmid" "$node_name")
    
    if [[ $current_version =~ ^13\. ]]; then
        success "Container $vmid ($container_name) is already running Debian 13.x"
        return 0
    elif [[ ! $current_version =~ ^12\. ]]; then
        error "Container $vmid ($container_name) is running Debian $current_version (not supported)"
        return 1
    fi
    
    info "Container $vmid ($container_name) running Debian $current_version - proceeding with upgrade"
    
    # Create backup
    if ! create_backup "$vmid" "$container_name" "$node_name"; then
        return 1
    fi
    
    # CRITICAL FIX: Apply AppArmor profile BEFORE upgrade to prevent systemd issues
    info "Pre-configuring AppArmor profile to prevent systemd issues during upgrade..."
    if command -v apparmor_parser >/dev/null 2>&1 && [[ ${SECURITY_MODE:-"unconfined"} == "custom" ]]; then
        info "Using custom AppArmor profile (recommended for security)"
        create_custom_apparmor_profile
        apply_custom_apparmor_profile "$vmid" "$container_name"
    else
        info "Using unconfined AppArmor profile (acceptable for homelab)"
        warning "Consider using custom profile for better security: --security-mode custom"
        fix_apparmor_profile_pre_upgrade "$vmid" "$container_name"
    fi
    
    # Upgrade existing packages first
    info "Step 1/5: Updating current packages in container $vmid..."
    info "Command: apt update && apt upgrade -y"
    pct_exec_with_node $vmid "$node_name" bash -c 'export DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true && apt update && apt upgrade -y' || {
        error "Failed to update current packages in container $vmid"
        return 1
    }
    success "Current packages updated successfully"
    
    # Backup sources.list
    info "Step 2/5: Backing up sources.list..."
    pct_exec_with_node $vmid "$node_name" cp /etc/apt/sources.list /etc/apt/sources.list.backup || {
        error "Failed to backup sources.list in container $vmid"
        return 1
    }
    success "sources.list backed up"
    
    # Update sources.list to trixie
    info "Step 3/5: Updating sources.list from bookworm to trixie..."
    pct_exec_with_node $vmid "$node_name" bash -c 'sed -i "s/bookworm/trixie/g" /etc/apt/sources.list' || {
        error "Failed to update sources.list in container $vmid"
        return 1
    }
    info "Verifying sources.list changes..."
    pct_exec_with_node $vmid "$node_name" grep -E "(trixie|bookworm)" /etc/apt/sources.list
    success "sources.list updated to trixie"
    
    # Update package lists
    info "Step 4/5: Updating package lists with new repository..."
    pct_exec_with_node $vmid "$node_name" apt update || {
        error "Failed to update package lists in container $vmid"
        return 1
    }
    success "Package lists updated"
    
    # Perform dist-upgrade
    info "Step 5/5: Performing distribution upgrade to Debian 13..."
    info "This may take several minutes - please be patient"
    info "Command: apt dist-upgrade -y (with full non-interactive mode)"
    pct_exec_with_node $vmid "$node_name" bash -c 'export DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true NEEDRESTART_MODE=a UCF_FORCE_CONFFNEW=1 && apt -o Dpkg::Options::="--force-confnew" -o Dpkg::Options::="--force-confdef" dist-upgrade -y' || {
        error "Distribution upgrade failed for container $vmid"
        # Restore backup on failure
        warning "Attempting to restore sources.list backup..."
        pct_exec_with_node $vmid "$node_name" mv /etc/apt/sources.list.backup /etc/apt/sources.list 2>/dev/null || true
        return 1
    }
    success "Distribution upgrade completed!"
    
    # CRITICAL FIX: Wait for all upgrade processes to complete
    info "Post-upgrade verification phase starting..."
    wait_for_upgrade_completion "$vmid" "$node_name"
    
    # Verify upgrade
    info "Verifying upgrade completion..."
    local new_version
    new_version=$(check_container_debian_version "$vmid" "$node_name")
    
    if [[ $new_version =~ ^13\. ]]; then
        success "Container $vmid ($container_name) successfully upgraded to Debian $new_version"
        
        # Clean up unused packages
        info "Cleaning up unused packages in container $vmid..."
        pct exec $vmid -- bash -c 'DEBIAN_FRONTEND=noninteractive apt autoremove -y' 2>/dev/null || {
            warning "Failed to clean up packages in container $vmid (upgrade was successful)"
        }
        
        # Fix getty services for console access (AppArmor already configured pre-upgrade)
        info "Applying console access fixes for Debian 13..."
        fix_getty_services "$vmid" "$container_name"
        
        return 0
    else
        error "Upgrade verification failed for container $vmid (version: $new_version)"
        return 1
    fi
}

get_available_pools() {
    # Try JSON format first (if jq is available), then fall back to table format
    if command -v jq >/dev/null 2>&1; then
        pvesh get /pools --output-format json 2>/dev/null | \
        jq -r '.[].poolid' 2>/dev/null && return 0
    fi
    
    # Fallback: parse table format output  
    pvesh get /pools 2>/dev/null | grep -E "^│" | grep -v "poolid" | sed 's/│//g' | sed 's/├.*//g' | sed 's/└.*//g' | awk '{print $1}' | grep -v "^$" || {
        error "Failed to get resource pools"
        return 1
    }
}

get_available_storage() {
    # Get storage that supports backups (content type 'backup')
    pvesm status -content backup | awk 'NR>1 && $3=="active" {print $1}' 2>/dev/null || \
    pvesm status | awk 'NR>1 && $3=="active" {print $1}'
}

prompt_for_pool() {
    if [[ -n $RESOURCE_POOL ]]; then
        info "Using configured resource pool: $RESOURCE_POOL"
        return 0
    fi
    
    local pools
    mapfile -t pools < <(get_available_pools)
    
    if [[ ${#pools[@]} -eq 0 ]]; then
        error "No resource pools found!"
        error "Please create resource pools first and assign containers to them:"
        error "Example: pvesh set /pools/Media-Server -vms 300,301,302,303,304,305,306,308"
        exit 1
    fi
    
    echo
    warning "IMPORTANT: LXC containers must be organized in resource pools before upgrading!"
    info "Note: VMs in pools are automatically skipped - this script only upgrades LXC containers"
    echo
    info "Available resource pools:"
    for i in "${!pools[@]}"; do
        echo "  [$((i+1))] ${pools[$i]}"
    done
    
    echo
    read -p "Select resource pool number (1-${#pools[@]}): " -r pool_num
    
    if [[ ! $pool_num =~ ^[0-9]+$ ]] || [[ $pool_num -lt 1 ]] || [[ $pool_num -gt ${#pools[@]} ]]; then
        error "Invalid selection: $pool_num"
        exit 1
    fi
    
    RESOURCE_POOL="${pools[$((pool_num-1))]}"
    success "Selected resource pool: $RESOURCE_POOL"
}

prompt_for_backup_storage() {
    if [[ -n $BACKUP_STORAGE ]]; then
        info "Using configured backup storage: $BACKUP_STORAGE"
        return 0
    fi
    
    local storage_list
    mapfile -t storage_list < <(get_available_storage)
    
    if [[ ${#storage_list[@]} -eq 0 ]]; then
        error "No active storage found!"
        exit 1
    fi
    
    echo
    info "Available backup storage:"
    for i in "${!storage_list[@]}"; do
        echo "  [$((i+1))] ${storage_list[$i]}"
    done
    
    echo
    read -p "Select backup storage number (1-${#storage_list[@]}): " -r storage_num
    
    if [[ ! $storage_num =~ ^[0-9]+$ ]] || [[ $storage_num -lt 1 ]] || [[ $storage_num -gt ${#storage_list[@]} ]]; then
        error "Invalid selection: $storage_num"
        exit 1
    fi
    
    BACKUP_STORAGE="${storage_list[$((storage_num-1))]}"
    success "Selected backup storage: $BACKUP_STORAGE"
}

discover_containers() {
    local containers=()
    
    info "Discovering containers in $RESOURCE_POOL pool..." >&2
    
    local pool_containers
    pool_containers=$(get_containers_in_pool "$RESOURCE_POOL" 2>/dev/null) || {
        error "Failed to get containers from pool $RESOURCE_POOL" >&2
        error "Make sure the pool exists and containers are assigned to it" >&2
        exit 1
    }
    
    if [[ -z $pool_containers ]]; then
        error "No containers found in $RESOURCE_POOL pool" >&2
        error "Please assign containers to the pool first:" >&2
        error "Example: pvesh set /pools/$RESOURCE_POOL -vms 300,301,302,303,304,305,306,308" >&2
        exit 1
    fi
    
    while IFS=: read -r vmid name node_name; do
        containers+=("$vmid:$name:$node_name")
    done <<< "$pool_containers"
    
    printf '%s\n' "${containers[@]}"
}

main() {
    local DRY_RUN=false
    local FORCE=false
    local SKIP_BACKUP=false
    local TARGET_CONTAINERS=()
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -n|--dry-run)
                DRY_RUN=true
                shift
                ;;
            -f|--force)
                FORCE=true
                shift
                ;;
            -s|--skip-backup)
                SKIP_BACKUP=true
                shift
                ;;
            --security-mode)
                if [[ -n "${2:-}" ]]; then
                    case $2 in
                        unconfined|custom)
                            SECURITY_MODE=$2
                            ;;
                        *)
                            error "Invalid security mode: $2. Use 'unconfined' or 'custom'"
                            exit 1
                            ;;
                    esac
                    shift 2
                else
                    error "--security-mode requires a value: 'unconfined' or 'custom'"
                    exit 1
                fi
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            -*)
                error "Unknown option: $1"
                usage
                exit 1
                ;;
            *)
                if [[ $1 =~ ^[0-9]+$ ]]; then
                    TARGET_CONTAINERS+=("$1")
                else
                    error "Invalid container ID: $1"
                    exit 1
                fi
                shift
                ;;
        esac
    done
    
    echo
    echo "========================================="
    echo "  LXC Debian 13 Upgrade Script"
    echo "========================================="
    echo
    warning "PREREQUISITES:"
    warning "1. This script must be run on a Proxmox node"
    warning "2. Containers must be organized in resource pools"
    warning "3. Ensure backup storage is available"
    echo
    info "AppArmor Security Mode: ${SECURITY_MODE:-unconfined}"
    if [[ ${SECURITY_MODE:-"unconfined"} == "unconfined" ]]; then
        info "  → Acceptable for homelab environments"
        info "  → Consider --security-mode custom for better security"
    else
        info "  → Recommended for security-conscious environments"
        info "  → Creates custom AppArmor profile"
        warning "  → Based on testing, Proxmox may override to 'unconfined'"
    fi
    echo
    info "If you haven't organized containers in pools yet, run:"
    info "pvesh set /pools/YourPoolName -vms VMID1,VMID2,VMID3..."
    echo
    
    log "Starting LXC Debian 13 upgrade process..."
    log "Log file: $LOG_FILE"
    
    if [[ $DRY_RUN == true ]]; then
        info "DRY RUN MODE - No changes will be made"
    fi
    
    if [[ $SKIP_BACKUP == true ]]; then
        warning "BACKUP SKIPPED - This is not recommended for production systems"
    fi
    
    # Check prerequisites
    check_prerequisites
    
    # Interactive prompts for configuration
    prompt_for_pool
    if [[ $SKIP_BACKUP != true ]]; then
        prompt_for_backup_storage
    fi
    
    # Discover containers
    local all_containers
    mapfile -t all_containers < <(discover_containers)
    
    # Process all LXC containers in the selected pool (pool-based workflow)
    info "All LXC containers in '$RESOURCE_POOL' pool will be upgraded:"
    for i in "${!all_containers[@]}"; do
        IFS=: read -r vmid name node <<< "${all_containers[$i]}"
        local version
        version=$(check_container_debian_version "$vmid" "$node" 2>/dev/null) || version="unknown"
        if [[ $version =~ ^13\. ]]; then
            echo "  - $vmid ($name) - Already Debian $version ✓ on $node"
        else
            echo "  - $vmid ($name) - Debian $version → 13.0 on $node"  
        fi
    done
    
    # Set all containers for processing
    local containers_to_process=("${all_containers[@]}")
    
    if [[ ${#containers_to_process[@]} -eq 0 ]]; then
        warning "No LXC containers found in $RESOURCE_POOL pool"
        info "This script only processes LXC containers. VMs are automatically skipped."
        exit 0
    fi
    
    echo
    info "Pool-based upgrade: All ${#containers_to_process[@]} LXC containers in '$RESOURCE_POOL' pool will be processed"
    
    # Show upgrade summary
    info "Upgrade summary:"
    local upgrade_needed=0
    local already_upgraded=0
    
    for container in "${containers_to_process[@]}"; do
        IFS=: read -r vmid name node <<< "$container"
        
        local version
        version=$(check_container_debian_version "$vmid" "$node" 2>/dev/null) || version="unknown"
        
        if [[ $version =~ ^13\. ]]; then
            echo "  - $vmid ($name) - Already Debian $version ✓"
            already_upgraded=$((already_upgraded + 1))
        else
            echo "  - $vmid ($name) - Debian $version → Debian 13"
            upgrade_needed=$((upgrade_needed + 1))
        fi
    done
    
    if [[ $upgrade_needed -eq 0 ]]; then
        success "All selected containers are already running Debian 13!"
        exit 0
    fi
    
    info "Summary: $upgrade_needed containers need upgrade, $already_upgraded already upgraded"
    
    if [[ $DRY_RUN == true ]]; then
        info "DRY RUN completed - no changes made"
        exit 0
    fi
    
    info "Proceeding to confirmation phase..."
    
    # Final confirmation
    if [[ $FORCE != true ]]; then
        echo
        warning "This will upgrade $upgrade_needed containers to Debian 13."
        if [[ $SKIP_BACKUP != true ]]; then
            info "Backups will be created before each upgrade."
        else
            warning "WARNING: No backups will be created!"
        fi
        echo
        echo -n "Do you want to proceed? (yes/no): "
        read -r REPLY
        if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
            info "Upgrade cancelled by user"
            exit 0
        fi
    fi
    
    # Perform upgrades
    local success_count=0
    local failure_count=0
    local failed_containers=()
    
    for container in "${containers_to_process[@]}"; do
        IFS=: read -r vmid name node <<< "$container"
        
        # Skip if already upgraded
        local version
        version=$(check_container_debian_version "$vmid" "$node" 2>/dev/null) || version="unknown"
        if [[ $version =~ ^13\. ]]; then
            info "Skipping container $vmid ($name) - already running Debian $version"
            continue
        fi
        
        echo
        echo "$(printf '%*s' 80 '' | tr ' ' '=')"
        info "PROCESSING CONTAINER $vmid ($name) ON $node - $(date)"
        echo "$(printf '%*s' 80 '' | tr ' ' '=')"
        
        # Process container with error handling
        local container_start_time=$(date +%s)
        local container_success=false
        
        if upgrade_container "$vmid" "$name" "$node"; then
            container_success=true
            local container_end_time=$(date +%s)
            local container_duration=$((container_end_time - container_start_time))
            success "Container $vmid ($name) upgraded successfully in ${container_duration}s"
            success_count=$((success_count + 1))
            echo
            echo "✅ UPGRADE COMPLETED: $vmid ($name) - Debian 12.x → 13.0"
        else
            local container_end_time=$(date +%s)
            local container_duration=$((container_end_time - container_start_time))
            error "Failed to upgrade container $vmid ($name) after ${container_duration}s"
            failed_containers+=("$vmid ($name)")
            failure_count=$((failure_count + 1))
            echo
            echo "❌ UPGRADE FAILED: $vmid ($name) - will continue with remaining containers"
            warning "Check the log file for detailed error information"
        fi
        
        echo
        info "Progress: $((success_count + failure_count)) of ${#containers_to_process[@]} containers processed"
        if [[ $failure_count -gt 0 ]]; then
            warning "Failures so far: $failure_count"
        fi
        echo
        
        # Add a brief pause between containers to avoid overwhelming the system
        if [[ $((success_count + failure_count)) -lt ${#containers_to_process[@]} ]]; then
            info "Pausing 5 seconds before next container..."
            sleep 5
        fi
    done
    
    # Final report
    echo
    log "=== UPGRADE SUMMARY ==="
    log "Successfully upgraded: $success_count containers"
    log "Failed upgrades: $failure_count containers"
    
    if [[ $failure_count -gt 0 ]]; then
        log "Failed containers:"
        for failed in "${failed_containers[@]}"; do
            log "  - $failed"
        done
    fi
    
    log "Log file saved: $LOG_FILE"
    
    if [[ $failure_count -gt 0 ]]; then
        exit 1
    else
        success "All upgrades completed successfully!"
    fi
}

# Only run main if script is executed directly
# Handle curl execution where BASH_SOURCE may not be available
if [[ -z "${BASH_SOURCE[0]:-}" ]] || [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi