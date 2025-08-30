#!/bin/bash

# Debian 12 Cloudinit Template Creation Script for Proxmox
# Usage: ./create-debian12-cloudinit-template.sh [VMID]

# Default VM ID
VMID=${1:-9003}
STORAGE="datastore01"
TEMPLATE_NAME="debian12-cloudinit-template"
CLOUD_IMAGE_URL="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2"
CLOUD_IMAGE_FILE="debian-12-generic-amd64.qcow2"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   print_error "This script must be run as root" 
   exit 1
fi

# Check if VM ID already exists
if qm status $VMID &>/dev/null; then
    print_warning "VM ID $VMID already exists. Destroying existing VM..."
    qm destroy $VMID
fi

# Check if storage exists
if ! pvesm status | grep -q "^$STORAGE"; then
    print_error "Storage '$STORAGE' not found. Available storages:"
    pvesm status | grep -E "^(NAME|datastore01|tank01|local-lvm)"
    exit 1
fi

print_status "Starting Debian 12 template creation with VM ID: $VMID"

# Download Debian 12 cloud image
print_status "Downloading Debian 12 cloud image..."
wget -q --show-progress -O $CLOUD_IMAGE_FILE $CLOUD_IMAGE_URL
if [[ $? -ne 0 ]]; then
    print_error "Failed to download cloud image"
    exit 1
fi

# Create VM
print_status "Creating VM with ID $VMID..."
qm create $VMID \
    --name $TEMPLATE_NAME \
    --ostype l26 \
    --memory 2048 \
    --balloon 0 \
    --cores 2 \
    --cpu host \
    --net0 virtio,bridge=vmbr0 \
    --scsihw virtio-scsi-pci \
    --bios seabios \
    --machine q35 \
    --agent 1 \
    --vga std \
    --serial0 socket

# Import disk
print_status "Importing cloud image as disk..."
qm importdisk $VMID $CLOUD_IMAGE_FILE $STORAGE
qm set $VMID --scsi0 $STORAGE:vm-$VMID-disk-0,discard=on
qm set $VMID --boot order=scsi0

# Configure cloudinit
print_status "Configuring cloudinit..."
qm set $VMID --ide2 $STORAGE:cloudinit

# Create cloudinit configuration directory
mkdir -p /var/lib/vz/snippets

# Create cloudinit configuration
CLOUDINIT_CONFIG="/var/lib/vz/snippets/debian12-cloudinit.yaml"
cat > $CLOUDINIT_CONFIG << 'EOF'
#cloud-config
package_update: true
package_upgrade: true
packages:
  - qemu-guest-agent
  - openssh-server
  - curl
  - wget
  - sudo
  - vim
runcmd:
  - systemctl enable qemu-guest-agent
  - systemctl start qemu-guest-agent
  - systemctl enable ssh
  - systemctl start ssh
  - echo "Debian 12 Template Ready" > /etc/motd
  - rm -f /etc/cloud/cloud.cfg.d/subiquity-disable-cloudinit-networking.cfg
  - rm -f /etc/cloud/cloud.cfg.d/99-installer.cfg
  - systemctl restart cloud-init
users:
  - default
  - name: debian
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: false
ssh_pwauth: true
disable_root: false
EOF

# Set cloudinit configuration
qm set $VMID --cicustom "vendor=local:snippets/debian12-cloudinit.yaml"

# Configure networking (DHCP by default)
qm set $VMID --ipconfig0 ip=dhcp

# Configure DNS
qm set $VMID --nameserver 1.1.1.1

# Prompt for SSH key
print_status "Checking for SSH public keys..."
SSH_KEY_PATH=""
if [[ -f /root/.ssh/id_rsa.pub ]]; then
    SSH_KEY_PATH="/root/.ssh/id_rsa.pub"
elif [[ -f /root/.ssh/id_ed25519.pub ]]; then
    SSH_KEY_PATH="/root/.ssh/id_ed25519.pub"
elif [[ -f /var/lib/vz/snippets/sshkey.pub ]]; then
    SSH_KEY_PATH="/var/lib/vz/snippets/sshkey.pub"
else
    print_warning "No SSH public key found. Creating template without SSH key..."
    print_warning "You can add SSH keys when cloning the template"
fi

if [[ -n "$SSH_KEY_PATH" ]]; then
    qm set $VMID --sshkeys $SSH_KEY_PATH
    print_status "Using SSH key from: $SSH_KEY_PATH"
fi

# Set default user
qm set $VMID --ciuser debian

# Convert to template
print_status "Converting VM to template..."
qm template $VMID

# Cleanup
rm -f $CLOUD_IMAGE_FILE

print_status "Debian 12 template creation completed!"
print_status "Template ID: $VMID"
print_status "Template Name: $TEMPLATE_NAME"
print_status ""
print_status "To clone this template:"
print_status "  qm clone $VMID <new-vm-id> --name <new-vm-name> --full"
print_status ""
print_status "To customize cloudinit when cloning:"
print_status "  qm set <new-vm-id> --ciuser <username> --cipassword <password>"
print_status "  qm set <new-vm-id> --sshkeys /path/to/sshkey.pub"
print_status "  qm set <new-vm-id> --ipconfig0 ip=<ip>/<netmask>,gw=<gateway>"
