#!/bin/bash
# Scrutiny Central Server Deployment Script
# Deploys Scrutiny web interface with embedded InfluxDB

set -euo pipefail

# Configuration
SCRUTINY_HOST="${1:-192.168.0.18}"
SCRUTINY_PORT="${2:-8080}"
INFLUX_PORT="${3:-8086}"
CONTAINER_NAME="scrutiny"

echo "🔧 Deploying Scrutiny Central Server on ${SCRUTINY_HOST}:${SCRUTINY_PORT}"

# Check if Docker is installed
if ! ssh root@${SCRUTINY_HOST} "command -v docker >/dev/null 2>&1"; then
    echo "❌ Docker not found on ${SCRUTINY_HOST}"
    echo "📦 Installing Docker..."
    ssh root@${SCRUTINY_HOST} "apt update && apt install -y docker.io"
    ssh root@${SCRUTINY_HOST} "systemctl enable --now docker"
fi

# Create directories
echo "📁 Creating Scrutiny directories..."
ssh root@${SCRUTINY_HOST} "mkdir -p /opt/scrutiny/{config,influxdb,logs}"

# Stop existing container if running
echo "🛑 Stopping existing Scrutiny container..."
ssh root@${SCRUTINY_HOST} "docker rm -f ${CONTAINER_NAME} 2>/dev/null || true"

# Deploy Scrutiny omnibus container
echo "🚀 Deploying Scrutiny omnibus container..."
ssh root@${SCRUTINY_HOST} "docker run -d \
    --name ${CONTAINER_NAME} \
    --restart unless-stopped \
    -p ${SCRUTINY_PORT}:8080 \
    -p ${INFLUX_PORT}:8086 \
    -v /opt/scrutiny/config:/opt/scrutiny/config \
    -v /opt/scrutiny/influxdb:/opt/scrutiny/influxdb \
    ghcr.io/analogj/scrutiny:master-omnibus"

# Wait for container to start
echo "⏳ Waiting for Scrutiny to start..."
sleep 30

# Check if service is running
if ssh root@${SCRUTINY_HOST} "docker ps | grep -q ${CONTAINER_NAME}"; then
    echo "✅ Scrutiny central server deployed successfully!"
    echo "🌐 Web interface: http://${SCRUTINY_HOST}:${SCRUTINY_PORT}"
    echo "📊 InfluxDB: http://${SCRUTINY_HOST}:${INFLUX_PORT}"
else
    echo "❌ Deployment failed. Checking logs..."
    ssh root@${SCRUTINY_HOST} "docker logs ${CONTAINER_NAME}"
    exit 1
fi

# Test web interface
echo "🧪 Testing web interface..."
if ssh root@${SCRUTINY_HOST} "curl -s -o /dev/null -w '%{http_code}' http://localhost:${SCRUTINY_PORT}" | grep -q "200\|302"; then
    echo "✅ Web interface is responding"
else
    echo "⚠️ Web interface may not be ready yet. Please check manually."
fi

echo "🎉 Scrutiny Central Server deployment complete!"
echo "📝 Next step: Run deploy-collectors.sh to setup collectors on Proxmox nodes"