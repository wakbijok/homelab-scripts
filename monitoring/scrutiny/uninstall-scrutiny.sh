#!/bin/bash
# Scrutiny Uninstall Script
# Removes Scrutiny central server and all collectors

set -euo pipefail

# Configuration
CENTRAL_SERVER="${1:-192.168.0.18}"
CONTAINER_NAME="scrutiny"
PROXMOX_NODES=(
    "192.168.0.21"
    "192.168.0.22"
    "192.168.0.23"
)

echo "🗑️ Uninstalling Scrutiny from homelab infrastructure"

# Function to remove collector from a node
remove_collector() {
    local node=$1
    echo "🖥️ Removing collector from ${node}..."
    
    # Remove cron job
    ssh root@${node} "crontab -l 2>/dev/null | grep -v 'scrutiny-collector' | crontab - 2>/dev/null || true"
    
    # Remove files
    ssh root@${node} "rm -rf /opt/scrutiny"
    
    echo "   ✅ Collector removed from ${node}"
}

# Remove collectors from all nodes
echo "🔧 Removing collectors from Proxmox nodes..."
for node in "${PROXMOX_NODES[@]}"; do
    if remove_collector "${node}"; then
        echo "✅ ${node} - Collector removed"
    else
        echo "⚠️ ${node} - Failed to remove collector"
    fi
done

# Remove central server
echo "🔧 Removing central server from ${CENTRAL_SERVER}..."
ssh root@${CENTRAL_SERVER} "docker rm -f ${CONTAINER_NAME} 2>/dev/null || true"

# Option to remove data
read -p "🗂️ Remove Scrutiny data and configuration? [y/N]: " -r
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "🗑️ Removing Scrutiny data..."
    ssh root@${CENTRAL_SERVER} "rm -rf /opt/scrutiny"
    echo "✅ Data removed"
else
    echo "💾 Data preserved at /opt/scrutiny on ${CENTRAL_SERVER}"
fi

echo "🎉 Scrutiny uninstall complete!"
echo "📝 Manual cleanup (if needed):"
echo "   - Remove Docker: apt remove docker.io (if no longer needed)"
echo "   - Check remaining containers: docker ps -a"