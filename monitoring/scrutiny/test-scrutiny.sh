#!/bin/bash
# Scrutiny Health Check Script
# Tests Scrutiny installation and collects health data

set -euo pipefail

# Configuration
CENTRAL_SERVER="${1:-192.168.0.18}"
SCRUTINY_PORT="${2:-8080}"
PROXMOX_NODES=(
    "192.168.0.21"
    "192.168.0.22"
    "192.168.0.23"
)

echo "🔍 Testing Scrutiny installation"
echo "📡 Central server: ${CENTRAL_SERVER}:${SCRUTINY_PORT}"

# Test central server
echo ""
echo "🖥️ Testing Central Server..."

# Check if container is running
if ssh root@${CENTRAL_SERVER} "docker ps | grep -q scrutiny"; then
    echo "   ✅ Scrutiny container is running"
else
    echo "   ❌ Scrutiny container is not running"
    ssh root@${CENTRAL_SERVER} "docker ps -a | grep scrutiny || echo 'No scrutiny container found'"
fi

# Test web interface
echo "   🌐 Testing web interface..."
if ssh root@${CENTRAL_SERVER} "command -v curl >/dev/null 2>&1" && ssh root@${CENTRAL_SERVER} "curl -s -o /dev/null -w '%{http_code}' http://localhost:${SCRUTINY_PORT}" | grep -q "200\|302"; then
    echo "   ✅ Web interface is responding"
else
    echo "   ❌ Web interface is not responding"
fi

# Test API
echo "   📊 Testing API endpoint..."
if ssh root@${CENTRAL_SERVER} "curl -s http://localhost:${SCRUTINY_PORT}/api/health 2>/dev/null | grep -q 'ok\|status'" 2>/dev/null; then
    echo "   ✅ API is responding"
else
    echo "   ⚠️ API may not be ready or accessible"
fi

# Test collectors
echo ""
echo "🔧 Testing Collectors..."

failed_collectors=()
for node in "${PROXMOX_NODES[@]}"; do
    echo "   🖥️ Testing collector on ${node}..."
    
    # Check if binary exists
    if ssh root@${node} "test -f /opt/scrutiny/bin/scrutiny-collector"; then
        echo "      ✅ Binary exists"
    else
        echo "      ❌ Binary not found"
        failed_collectors+=("${node}")
        continue
    fi
    
    # Check if config exists
    if ssh root@${node} "test -f /opt/scrutiny/config/collector.yaml"; then
        echo "      ✅ Configuration exists"
    else
        echo "      ❌ Configuration not found"
        failed_collectors+=("${node}")
        continue
    fi
    
    # Check cron job
    if ssh root@${node} "crontab -l 2>/dev/null | grep -q scrutiny-collector"; then
        echo "      ✅ Cron job configured"
        # Show cron schedule
        schedule=$(ssh root@${node} "crontab -l 2>/dev/null | grep scrutiny-collector | awk '{print \$1\" \"\$2\" \"\$3\" \"\$4\" \"\$5}'")
        echo "         Schedule: ${schedule}"
    else
        echo "      ⚠️ Cron job not found"
    fi
    
    # Test collector execution
    echo "      🧪 Testing collector execution..."
    if timeout 60 ssh root@${node} "/opt/scrutiny/bin/scrutiny-collector run --config /opt/scrutiny/config/collector.yaml 2>&1 | grep -q 'Main: Completed'"; then
        echo "      ✅ Collector executed successfully"
    else
        echo "      ❌ Collector execution failed"
        failed_collectors+=("${node}")
    fi
    
    # Check detected devices
    echo "      💾 Detecting storage devices..."
    devices=$(ssh root@${node} "lsblk -d | grep -E '(sd|nvme)' | wc -l" || echo "0")
    echo "         Found ${devices} storage devices"
done

# Summary
echo ""
echo "📊 Test Summary:"
echo "   Nodes tested: ${#PROXMOX_NODES[@]}"
echo "   Collectors working: $((${#PROXMOX_NODES[@]} - ${#failed_collectors[@]}))"
echo "   Failed collectors: ${#failed_collectors[@]}"

if [[ ${#failed_collectors[@]} -gt 0 ]]; then
    echo "❌ Failed collector nodes:"
    printf '   - %s\n' "${failed_collectors[@]}"
fi

# Show disk health summary
echo ""
echo "💾 Current Disk Health Status:"
echo "   Access web interface: http://${CENTRAL_SERVER}:${SCRUTINY_PORT}"
echo "   View detailed SMART data and trends in the dashboard"

# Show manual commands
echo ""
echo "📝 Manual Commands:"
echo "   Run collector manually: ssh root@<node> '/opt/scrutiny/bin/scrutiny-collector run --config /opt/scrutiny/config/collector.yaml'"
echo "   View container logs: ssh root@${CENTRAL_SERVER} 'docker logs scrutiny'"
echo "   Restart central server: ssh root@${CENTRAL_SERVER} 'docker restart scrutiny'"

if [[ ${#failed_collectors[@]} -eq 0 ]]; then
    echo ""
    echo "🎉 All tests passed! Scrutiny is working correctly."
else
    echo ""
    echo "⚠️ Some collectors failed tests. Check the failed nodes above."
    exit 1
fi