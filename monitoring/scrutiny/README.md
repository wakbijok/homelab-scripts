# Scrutiny Disk Monitoring Scripts

This directory contains deployment and management scripts for Scrutiny, a SMART disk monitoring solution for the homelab infrastructure.

## Overview

Scrutiny provides centralized disk health monitoring across all Proxmox nodes with:

- **Web Interface**: Real-time disk health dashboard
- **Historical Trends**: Long-term SMART data analysis
- **Failure Prediction**: Early warning system for disk failures
- **Multi-Node Support**: Monitors all disks across the cluster

## Architecture

```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│   Proxmox Node  │    │   Proxmox Node  │    │   Proxmox Node  │
│   192.168.0.21  │    │   192.168.0.22  │    │   192.168.0.23  │
│                 │    │                 │    │                 │
│  ┌─────────────┐│    │  ┌─────────────┐│    │  ┌─────────────┐│
│  │  Collector  ││    │  │  Collector  ││    │  │  Collector  ││
│  │   Binary    ││    │  │   Binary    ││    │  │   Binary    ││
│  │  (Cron)     ││    │  │  (Cron)     ││    │  │  (Cron)     ││
│  └─────────────┘│    │  └─────────────┘│    │  └─────────────┘│
└─────────┬───────┘    └─────────┬───────┘    └─────────┬───────┘
          │                      │                      │
          │                      │                      │
          └──────────────────────┼──────────────────────┘
                                 │
                    ┌─────────────▼───────────────┐
                    │      Central Server         │
                    │      192.168.0.18:8080     │
                    │                             │
                    │  ┌─────────────────────────┐│
                    │  │    Scrutiny Web UI     ││
                    │  │   + Embedded InfluxDB  ││
                    │  │      (Docker)          ││
                    │  └─────────────────────────┘│
                    └─────────────────────────────┘
```

## Scripts

### 1. `deploy-central-server.sh`

Deploys the Scrutiny central server with embedded InfluxDB.

**Usage:**

```bash
./deploy-central-server.sh [SERVER_IP] [WEB_PORT] [INFLUX_PORT]
```

**Example:**

```bash
./deploy-central-server.sh 192.168.0.18 8080 8086
```

**What it does:**

- Installs Docker if needed
- Creates necessary directories
- Deploys Scrutiny omnibus container
- Tests web interface accessibility

### 2. `deploy-collectors.sh`

Deploys standalone collectors on all Proxmox nodes.

**Usage:**

```bash
./deploy-collectors.sh [CENTRAL_SERVER:PORT] [CRON_SCHEDULE]
```

**Example:**

```bash
./deploy-collectors.sh 192.168.0.18:8080 "0 */4 * * *"
```

**What it does:**

- Downloads collector binaries to each node
- Creates collector configurations
- Tests collector functionality
- Sets up staggered cron jobs (every 4 hours)

### 3. `test-scrutiny.sh`

Comprehensive health check for the entire Scrutiny installation.

**Usage:**

```bash
./test-scrutiny.sh [CENTRAL_SERVER] [WEB_PORT]
```

**Example:**

```bash
./test-scrutiny.sh 192.168.0.18 8080
```

**What it tests:**

- Central server container status
- Web interface accessibility
- API endpoint functionality
- Collector binary existence
- Configuration files
- Cron job setup
- Collector execution
- Storage device detection

### 4. `uninstall-scrutiny.sh`

Complete removal of Scrutiny from all nodes.

**Usage:**

```bash
./uninstall-scrutiny.sh [CENTRAL_SERVER]
```

**Example:**

```bash
./uninstall-scrutiny.sh 192.168.0.18
```

**What it does:**

- Removes collectors from all nodes
- Removes cron jobs
- Stops and removes central server container
- Optionally removes data and configuration

## Quick Start

1. **Make scripts executable:**

   ```bash
   chmod +x *.sh
   ```
2. **Deploy central server:**

   ```bash
   ./deploy-central-server.sh
   ```
3. **Deploy collectors:**

   ```bash
   ./deploy-collectors.sh
   ```
4. **Test installation:**

   ```bash
   ./test-scrutiny.sh
   ```
5. **Access web interface:**

   ```
   http://192.168.0.18:8080
   ```

## Configuration

### Central Server

- **Host:** 192.168.0.18 (LXC container)
- **Web Port:** 8080
- **InfluxDB Port:** 8086
- **Data Path:** `/opt/scrutiny/`

### Collectors

- **Schedule:** Every 4 hours (staggered by 5 minutes per node)
- **Binary Path:** `/opt/scrutiny/bin/scrutiny-collector`
- **Config Path:** `/opt/scrutiny/config/collector.yaml`
- **Nodes:** 192.168.0.21, 192.168.0.22, 192.168.0.23

## Manual Operations

### Run collector manually:

```bash
ssh root@192.168.0.21 '/opt/scrutiny/bin/scrutiny-collector run --config /opt/scrutiny/config/collector.yaml'
```

### View container logs:

```bash
ssh root@192.168.0.18 'docker logs scrutiny'
```

### Restart central server:

```bash
ssh root@192.168.0.18 'docker restart scrutiny'
```

### Check cron jobs:

```bash
ssh root@192.168.0.21 'crontab -l'
```

## Features

- ✅ **No Docker overhead** on Proxmox nodes
- ✅ **Lightweight collectors** using native smartctl
- ✅ **Embedded InfluxDB** - no external database needed
- ✅ **Historical trends** and failure prediction
- ✅ **Staggered collection** to avoid I/O conflicts
- ✅ **Automatic scheduling** via cron
- ✅ **Web-based dashboard** for monitoring
- ✅ **Multi-device support** (SATA, NVMe, SAS)

## Troubleshooting

### Central server not accessible:

```bash
ssh root@192.168.0.18 'docker ps'
ssh root@192.168.0.18 'docker logs scrutiny'
```

### Collector not working:

```bash
ssh root@192.168.0.21 '/opt/scrutiny/bin/scrutiny-collector run --config /opt/scrutiny/config/collector.yaml'
```

### No devices detected:

```bash
ssh root@192.168.0.21 'smartctl --scan'
ssh root@192.168.0.21 'lsblk -d'
```

### Permission issues:

```bash
ssh root@192.168.0.21 'ls -la /opt/scrutiny/bin/scrutiny-collector'
ssh root@192.168.0.21 'chmod +x /opt/scrutiny/bin/scrutiny-collector'
```

## Security Considerations

- Central server runs in Docker container with restricted access
- Collectors run with minimal privileges (only need smartctl access)
- All communication is HTTP within trusted network
- No external network access required after initial setup

## Monitoring Benefits

### Current Setup Detection

- 📊 Historical SMART data collection for trend analysis
- 🔔 Early warning system for proactive replacement

### Use Cases

- **Capacity Planning:** Monitor drive wear and plan replacements
- **Performance Analysis:** Identify slow or degrading drives
- **Failure Prevention:** Replace drives before they fail
- **Ceph Optimization:** Monitor OSD drive health for rebalancing decisions

## Integration

This monitoring complements existing homelab infrastructure:

- **Grafana:** SMART metrics can be exported to existing dashboards
- **Proxmox:** Drive status visible alongside VM/LXC monitoring
- **Ceph:** Helps identify problematic OSDs before cluster issues
