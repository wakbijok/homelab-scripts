#!/bin/bash
# Scrutiny Collectors Deployment Script
# Deploys standalone collectors on Proxmox nodes

set -euo pipefail

# Configuration
CENTRAL_SERVER="${1:-192.168.0.18:8080}"
COLLECTOR_SCHEDULE="${2:-0 */4 * * *}"  # Every 4 hours
PROXMOX_NODES=(
    "192.168.0.21"
    "192.168.0.22" 
    "192.168.0.23"
)

echo "🔧 Deploying Scrutiny Collectors to Proxmox nodes"
echo "📡 Central server: ${CENTRAL_SERVER}"
echo "⏰ Schedule: ${COLLECTOR_SCHEDULE}"

# Function to deploy collector on a single node
deploy_collector() {
    local node=$1
    local cron_offset=$2
    local cron_schedule="${COLLECTOR_SCHEDULE}"
    
    # Add offset to avoid all nodes collecting simultaneously
    if [[ $cron_offset -gt 0 ]]; then
        cron_schedule="${cron_offset} */4 * * *"
    fi
    
    echo "🖥️ Deploying collector on ${node}..."
    
    # Create directories
    ssh root@${node} "mkdir -p /opt/scrutiny/{bin,config}"
    
    # Download collector binary
    echo "   📦 Downloading collector binary..."
    ssh root@${node} "wget -q https://github.com/AnalogJ/scrutiny/releases/latest/download/scrutiny-collector-metrics-linux-amd64 -O /opt/scrutiny/bin/scrutiny-collector"
    ssh root@${node} "chmod +x /opt/scrutiny/bin/scrutiny-collector"
    
    # Create collector configuration
    echo "   ⚙️ Creating collector configuration..."
    ssh root@${node} "cat > /opt/scrutiny/config/collector.yaml << 'EOF'
api:
  endpoint: http://${CENTRAL_SERVER}
EOF"
    
    # Test collector
    echo "   🧪 Testing collector..."
    if ssh root@${node} "timeout 60 /opt/scrutiny/bin/scrutiny-collector run --config /opt/scrutiny/config/collector.yaml"; then
        echo "   ✅ Collector test successful"
    else
        echo "   ⚠️ Collector test failed or timed out"
        return 1
    fi
    
    # Add cron job
    echo "   ⏰ Setting up cron job (${cron_schedule})..."
    ssh root@${node} "(crontab -l 2>/dev/null | grep -v 'scrutiny-collector' || true; echo '${cron_schedule} /opt/scrutiny/bin/scrutiny-collector run --config /opt/scrutiny/config/collector.yaml >/dev/null 2>&1') | crontab -"
    
    echo "   ✅ Collector deployed successfully on ${node}"
}

# Deploy collectors to all nodes
failed_nodes=()
for i in "${!PROXMOX_NODES[@]}"; do
    node="${PROXMOX_NODES[$i]}"
    cron_offset=$((i * 5))  # Stagger by 5 minutes
    
    if deploy_collector "${node}" "${cron_offset}"; then
        echo "✅ ${node} - SUCCESS"
    else
        echo "❌ ${node} - FAILED"
        failed_nodes+=("${node}")
    fi
done

# Summary
echo ""
echo "📊 Deployment Summary:"
echo "   Total nodes: ${#PROXMOX_NODES[@]}"
echo "   Successful: $((${#PROXMOX_NODES[@]} - ${#failed_nodes[@]}))"
echo "   Failed: ${#failed_nodes[@]}"

if [[ ${#failed_nodes[@]} -gt 0 ]]; then
    echo "❌ Failed nodes:"
    printf '   - %s\n' "${failed_nodes[@]}"
    exit 1
else
    echo "🎉 All collectors deployed successfully!"
    echo ""
    echo "📝 Next steps:"
    echo "   1. Visit http://${CENTRAL_SERVER%:*}:${CENTRAL_SERVER#*:} to view disk health"
    echo "   2. Collectors will run automatically every 4 hours"
    echo "   3. Manual collection: ssh root@<node> '/opt/scrutiny/bin/scrutiny-collector run --config /opt/scrutiny/config/collector.yaml'"
fi