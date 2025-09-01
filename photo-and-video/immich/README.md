# Immich Native Linux Deployment Guide

This guide provides instructions for deploying Immich natively on Linux Debian 13 (Trixie ) without Docker.

## Overview

Immich is a high-performance self-hosted photo and video management solution. This deployment method runs all components natively on the host system, providing better performance and easier customization compared to Docker deployments.

## Prerequisites

### System Requirements

- **OS**: Debian 13 (Trixie) or compatible
- **CPU**: Multi-core processor (Intel Core i3 or better)
- **RAM**: Minimum 4GB, recommended 8GB+
- **Storage**:
  - Root disk with at least 10GB free space
  - Separate data disk for photos/videos (300GB+ recommended)
- **Network**: Static IP address recommended

### Required Packages

```bash
# Core dependencies
sudo apt update
sudo apt install -y curl git build-essential postgresql postgresql-contrib redis-server
sudo apt install -y python3-pip python3-venv nginx exiftool libimage-exiftool-perl
sudo apt install -y libvips-dev imagemagick ffmpeg postgresql-17-pgvector util-linux unzip

# Node.js 20.x installation
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt install -y nodejs
```

## Installation Steps

### 1. System Preparation

#### Resize Root Filesystem (if needed)

```bash
# If root disk is full, expand partition and filesystem
sudo growpart /dev/sda 1
sudo resize2fs /dev/sda1
```

#### Setup Data Disk

```bash
# Create partition on data disk (adjust device as needed)
echo 'n
p
1


w' | sudo fdisk /dev/sdb

# Format and mount at high-level directory
sudo mkfs.ext4 /dev/sdb1
sudo mkdir -p /var/lib/immich
sudo mount /dev/sdb1 /var/lib/immich

# Add to fstab for persistent mounting
echo '/dev/sdb1 /var/lib/immich ext4 defaults 0 2' | sudo tee -a /etc/fstab
```

### 2. Database Setup

#### Configure PostgreSQL

```bash
# Start and enable PostgreSQL
sudo systemctl start postgresql
sudo systemctl enable postgresql

# Create Immich database and user
sudo -u postgres createuser --createdb immich
sudo -u postgres createdb -O immich immich
sudo -u postgres psql -c "ALTER USER immich PASSWORD 'immich_password';"

# Install required extensions
sudo -u postgres psql -d immich -c "CREATE EXTENSION IF NOT EXISTS \"uuid-ossp\";"
sudo -u postgres psql -d immich -c "CREATE EXTENSION IF NOT EXISTS cube;"
sudo -u postgres psql -d immich -c "CREATE EXTENSION IF NOT EXISTS earthdistance;"
sudo -u postgres psql -d immich -c "CREATE EXTENSION IF NOT EXISTS vector;"
```

### 3. Redis Configuration

```bash
# Start and enable Redis
sudo systemctl start redis-server
sudo systemctl enable redis-server

# Test Redis connectivity
redis-cli ping  # Should return PONG
```

### 4. User and Directory Setup

```bash
# Create immich user
sudo useradd -r -s /bin/bash -d /var/lib/immich immich
sudo chown immich:immich /var/lib/immich
```

### 5. Immich Installation

#### Clone Reference Setup and Run Install Script

```bash
# Clone the working setup from immich-native repository by arter97
git clone https://github.com/arter97/immich-native /tmp/immich-native
cd /tmp/immich-native

# Run the installation script (automatically downloads and builds Immich v1.135.3)
sudo bash install.sh
```

#### Environment Configuration

The install script creates `/var/lib/immich/env` with the following key settings:

```bash
# Database
DB_PASSWORD=immich_password
DB_USERNAME=immich
DB_DATABASE_NAME=immich
DB_VECTOR_EXTENSION=pgvector

# Upload location (relative to app directory)
UPLOAD_LOCATION=./library

# Application settings
NODE_ENV=production
IMMICH_VERSION=release
IMMICH_HOST=127.0.0.1
REDIS_HOSTNAME=127.0.0.1
```

### 6. Service Configuration

The install script automatically creates systemd services:

```bash
# The immich.service configuration
[Unit]
Description=immich server
Requires=redis-server.service postgresql.service
After=redis-server.service postgresql.service

[Service]
User=immich
Group=immich
Type=simple
Restart=on-failure
WorkingDirectory=/var/lib/immich/app
EnvironmentFile=/var/lib/immich/env
ExecStart=node /var/lib/immich/app/dist/main

[Install]
WantedBy=multi-user.target
```

### 7. Nginx Reverse Proxy

Configure Nginx to serve the web interface and proxy API requests:

```bash
# Create Immich site configuration
sudo tee /etc/nginx/sites-available/immich > /dev/null << 'EOF'
upstream immich_server {
    server 127.0.0.1:2283;
    keepalive 2;
}

server {
    listen 80;
    server_name _;

    client_max_body_size 50000M;

    # Serve static web files directly
    location / {
        root /var/lib/immich/app/www;
        try_files $uri $uri/ @api;
      
        # Security headers
        add_header X-Frame-Options DENY;
        add_header X-Content-Type-Options nosniff;
        add_header Referrer-Policy strict-origin-when-cross-origin;
      
        # Cache static assets
        location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)$ {
            expires 1y;
            add_header Cache-Control "public, immutable";
        }
    }

    # API endpoints
    location @api {
        proxy_pass http://immich_server;
        proxy_set_header Host $http_host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
      
        # WebSocket support
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
      
        # Timeouts for large uploads
        proxy_read_timeout 3600;
        proxy_connect_timeout 3600;
        proxy_send_timeout 3600;
      
        # Buffer settings for uploads
        proxy_buffering off;
        proxy_request_buffering off;
    }

    location /api {
        proxy_pass http://immich_server;
        proxy_set_header Host $http_host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
      
        # WebSocket support
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
      
        # Timeouts for large uploads  
        proxy_read_timeout 3600;
        proxy_connect_timeout 3600;
        proxy_send_timeout 3600;
      
        # Buffer settings for uploads
        proxy_buffering off;
        proxy_request_buffering off;
    }

    # Serve uploaded media files directly
    location /library/ {
        internal;
        alias /var/lib/immich/app/library/;
      
        # Security headers
        add_header X-Content-Type-Options nosniff;
        add_header X-Frame-Options DENY;
    }
}
EOF

# Enable site and restart Nginx
sudo rm -f /etc/nginx/sites-enabled/default
sudo ln -sf /etc/nginx/sites-available/immich /etc/nginx/sites-enabled/immich
sudo nginx -t
sudo systemctl reload nginx
```

### 8. Permissions Fix

Ensure Nginx can access the web files:

```bash
sudo chmod 755 /var/lib/immich /var/lib/immich/app
sudo chmod -R 755 /var/lib/immich/app/www/
sudo chown -R immich:www-data /var/lib/immich/app/www/
```

## Architecture

```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│   Nginx Proxy   │    │  Immich Server  │    │  PostgreSQL DB  │
│   Port 80/443   │────│   Port 2283     │────│   Port 5432     │
└─────────────────┘    └─────────────────┘    └─────────────────┘
                                │
                       ┌─────────────────┐
                       │  Redis Cache    │
                       │   Port 6379     │
                       └─────────────────┘
                                │
                       ┌─────────────────┐
                       │  File Storage   │
                       │ /var/lib/immich │
                       └─────────────────┘
```

## File Structure

```
/var/lib/immich/                # Application root (mounted data disk)
├── app/                        # Built application
│   ├── dist/                   # Server code
│   ├── www/                    # Web interface
│   ├── node_modules/           # Dependencies
│   ├── geodata/                # GeoNames data
│   └── library/                # Photo/video storage
└── env                         # Environment configuration
```

## Key Differences from arter97's Original Setup

### 🔄 **Environment-Specific Adaptations**

This setup builds upon the excellent foundation provided by **arter97's immich-native** and makes the following environment-specific adaptations for my Debian 13 VM:

| **Configuration**     | **Original Setup** | **Our Debian 13 Environment**        | **Reason**                       |
| --------------------------- | ------------------------ | ------------------------------------------ | -------------------------------------- |
| **Storage Strategy**  | Standard installation    | Dedicated data disk at `/var/lib/immich` | VM storage optimization                |
| **Machine Learning**  | Full ML support          | Temporarily disabled                       | Python 3.13 compatibility in Debian 13 |
| **Web Configuration** | Core Nginx setup         | Extended with caching and headers          | Production deployment considerations   |
| **File Permissions**  | Default permissions      | Nginx-optimized permissions                | Web server integration                 |

### 🎯 **Our Specific Requirements**

1. **VM Storage Layout**: Utilizing a dedicated 295GB data disk mounted at the application root for optimal storage management in our virtualized environment.
2. **Debian 13 Compatibility**: Addressing Python version compatibility (3.13 vs required 3.10/3.11) by temporarily disabling ML components until upstream compatibility is resolved.
3. **Production Considerations**: Adding web server optimizations, security headers, and caching appropriate for a homelab production deployment.
4. **Infrastructure Integration**: Configuring for our specific network and storage architecture.

### 🙏 **Acknowledgment**

This deployment stands on the shoulders of the exceptional work by **arter97** ([immich-native](https://github.com/arter97/immich-native)). Their installation script and systemd service approach provided the robust foundation that made this deployment possible. I am grateful for their contribution to the community and highly recommend their repository as the go-to solution for native Immich deployments.

## Key Differences from Complex Approach

### ✅ Simplified Architecture

- **Single service** instead of multiple microservices
- **Static file serving** by Nginx instead of development server
- **Relative paths** for upload location (`./library`)
- **High-level mount point** (`/var/lib/immich`) for cleaner organization

### ✅ Resolved Issues

- **PostgreSQL Extension**: Uses `pgvector` via `DB_VECTOR_EXTENSION=pgvector`
- **GeoNames Data**: Automatically downloads required geodata files
- **Sharp Module**: Installed for thumbnail generation
- **Systemd Service**: Single service with proper dependencies

### ✅ Production Benefits

- **Cleaner file organization** with high-level mount
- **Better performance** with static file serving
- **Easier maintenance** with single service
- **Proper permissions** for web server access

## Verification

### Health Checks

```bash
# Service status
sudo systemctl status immich.service

# API connectivity
curl http://192.168.0.47/api/server/ping
# Expected: {"res":"pong"}

# Web interface
curl -I http://192.168.0.47/
# Expected: HTTP/1.1 200 OK
```

### Access Information

- **Web Interface**: http://192.168.0.47
- **API Endpoint**: http://192.168.0.47/api
- **Upload Storage**: `/var/lib/immich/app/library/`

## First-Time Setup

1. Navigate to http://192.168.0.47 in your web browser
2. Create your first admin user account
3. Configure library settings (default path is correct)
4. Begin uploading and managing your photos/videos

## Performance Notes

- **Upload Storage**: 295GB available on mounted data disk
- **Memory Usage**: ~400MB total (well within 4GB VM limits)
- **Features Available**: All core features except ML-dependent ones (face recognition, smart search)
- **Machine Learning**: Disabled due to Python version compatibility

## Troubleshooting

### Service Issues

```bash
# Check service logs
sudo journalctl -u immich.service -f

# Restart service
sudo systemctl restart immich.service
```

### Database Connection Issues

```bash
# Test database connectivity
psql -h localhost -U immich -d immich -c "SELECT version();"
```

### File Permission Issues

```bash
# Fix ownership if needed
sudo chown -R immich:immich /var/lib/immich/app/
sudo chmod 755 /var/lib/immich /var/lib/immich/app
sudo chmod -R 755 /var/lib/immich/app/www/
```

## Security Considerations

### Database Security

- Immich database user has limited privileges
- Strong passwords for database connections
- PostgreSQL bound to localhost only

### File Permissions

- Data directories owned by immich user
- Proper file system permissions on web directories
- Nginx serves files with appropriate security headers

### Network Security

- Default configuration binds API to localhost
- Nginx proxy provides external access
- Consider firewall rules for production deployment

## Deployment Status

### ✅ DEPLOYMENT COMPLETED SUCCESSFULLY

**Production Ready**: All core services operational and tested

#### Service Status

- ✅ **Immich Server**: Running as single systemd service
- ✅ **PostgreSQL Database**: Initialized with pgvector extension
- ✅ **Redis Cache**: Operational
- ✅ **Nginx Reverse Proxy**: Serving web interface and API
- ✅ **Static File Serving**: Efficient delivery of web assets
- ✅ **Systemd Integration**: Auto-start enabled

#### Technical Specifications

- **Version**: Immich v1.135.3
- **Database**: PostgreSQL 17.5 with pgvector extension
- **Node.js**: v20.19.4
- **Architecture**: Single service with static file serving
- **Mount Point**: `/var/lib/immich` (295GB available)

---

**✅ Status**: Production deployment completed successfully. Ready for use!

**Last Updated**: 2025-09-01
**Tested Environment**: Debian 13 (Trixie), VM with 8GB RAM, 300GB storage
**Deployment Method**: Native Linux (Docker-free) - Simplified Architecture
**Reference Implementation**: Built upon [arter97/immich-native](https://github.com/arter97/immich-native)
**Environment**: Debian 13 VM with dedicated data disk, adapted for homelab infrastructure
