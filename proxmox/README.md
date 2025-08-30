# Proxmox Management Scripts

Collection of automation scripts for Proxmox Virtual Environment (VE) management tasks.

## 📋 Available Scripts

### LXC Container Management

#### `upgrade-lxc-debian13.sh`

Comprehensive script for upgrading LXC containers from Debian 12 to Debian 13 with automatic compatibility fixes.

```bash
# Interactive upgrade (recommended)
./upgrade-lxc-debian13.sh

# Specific containers with security mode
./upgrade-lxc-debian13.sh --security-mode unconfined 301 302 303

# Dry run to see what would happen
./upgrade-lxc-debian13.sh --dry-run

# Available options
./upgrade-lxc-debian13.sh --help
```

**Features:**

- Automated backup creation before upgrade
- AppArmor compatibility fixes
- Console access fixes (getty services)
- Resource pool integration
- Multiple security modes
- Comprehensive logging

**Prerequisites:**

- Must be run on Proxmox node
- Containers organized in resource pools
- Backup storage available

#### `create-debian13-lxc-container.sh`

Creates Debian 13 LXC containers using DAB (Debian Appliance Builder) method.

```bash
# Interactive LXC container creation
./create-debian13-lxc-container.sh
```

**Features:**

- Checks for existing Debian 13 templates or creates new ones
- Interactive configuration (hostname, IP, storage, etc.)
- Uses official Proxmox DAB config from GitHub
- Applies console compatibility fixes for AppArmor issues
- Complete workflow: template creation → container deployment
- Handles privileged/unprivileged containers
- Cross-storage support (local, CIFS, NFS)
- Minimal resource allocation (1 CPU core, 512MB RAM)
- Automatic container ID detection using Proxmox API

**Important Notes:**

- AppArmor profile automatically set to unconfined for Debian 13 compatibility
- Console access issues resolved through systemd service fixes
- DAB process can take several minutes for initial template creation
- Template reuse for subsequent containers (no recreation needed)

**Prerequisites:**

- Must be run on Proxmox node
- Internet connection for DAB downloads
- Sufficient storage space for template creation
- DAB package will be installed automatically if missing

### VM Template Creation

#### `create-debian12-cloudinit-template.sh`

Creates a Debian 12 cloud-init template for quick VM deployment.

```bash
# Create template with default VM ID (9003)
./create-debian12-cloudinit-template.sh

# Create template with specific VM ID
./create-debian12-cloudinit-template.sh 9005

# Customize storage (edit script variables)
STORAGE="your-storage-name"
```

#### `create-debian13-cloudinit-template.sh`

Creates a Debian 13 cloud-init template for quick VM deployment.

```bash
# Create template with default VM ID (9004)
./create-debian13-cloudinit-template.sh

# Create template with specific VM ID
./create-debian13-cloudinit-template.sh 9006

# Customize storage (edit script variables)
STORAGE="your-storage-name"
```

**What these scripts create:**

- Downloads latest Debian cloud image (12 or 13)
- Creates VM with optimized settings:
  - 2GB RAM, 2 CPU cores
  - VirtIO SCSI controller
  - Cloud-init drive
  - Network bridge (vmbr0)
- Converts to template for cloning

**Template specifications:**

- **VM ID**: 9003 (Debian 12) / 9004 (Debian 13) or custom
- **Storage**: datastore01 (configurable)
- **Image**: Latest Debian generic cloud image
- **Ready for**: Quick VM cloning with cloud-init

## 🔧 Common Use Cases

### Quick VM Deployment

**Debian 12:**

1. Create template: `./create-debian12-cloudinit-template.sh`
2. Clone template in Proxmox UI
3. Configure cloud-init settings
4. Start VM

**Debian 13:**

1. Create template: `./create-debian13-cloudinit-template.sh`
2. Clone template in Proxmox UI
3. Configure cloud-init settings
4. Start VM

### LXC Container Upgrades

1. Organize containers in resource pools
2. Run upgrade script: `./upgrade-lxc-debian13.sh`
3. Follow interactive prompts
4. Verify upgraded containers

## ⚠️ Important Notes

### Debian 13 LXC Upgrades

Based on our testing, Proxmox VE appears to automatically override AppArmor configurations to `unconfined` for Debian 13 containers. This behavior has not been officially confirmed by the Proxmox team.

**Observed behavior:**

- All Debian 13 containers run with unconfined AppArmor regardless of manual configuration
- Console access issues are automatically resolved by the upgrade script
- Configuration may show `generated` but runtime uses `unconfined`

### Cloud-Init Templates

- Default storage is set to `datastore01` - modify script if different
- Template will replace existing VM if same ID is used
- Requires internet connection to download cloud image

### Security Considerations

#### AppArmor Profiles

The upgrade script offers multiple security modes, though based on testing, Proxmox may override these:

| Mode           | Description               | Observed Result                      |
| -------------- | ------------------------- | ------------------------------------ |
| `unconfined` | Standard homelab approach | ✅ Applied as expected               |
| `custom`     | Enhanced security profile | ⚠️ May be overridden to unconfined |

#### Best Practices

1. **Always backup** before upgrades
2. **Test in non-production** first
3. **Verify functionality** after upgrades
4. **Monitor logs** for issues
5. **Use resource pools** for organization

## 🔍 Troubleshooting

### Common Issues

#### Storage Not Found

```bash
# Check available storages
pvesm status

# Update script variables if needed
STORAGE="your-storage-name"
```

#### Container Not in Pool

```bash
# Add container to pool
pvesh set /pools/YourPool -vms VMID1,VMID2,VMID3
```

#### Console Access Issues

The upgrade script automatically handles console access fixes, but for manual resolution:

```bash
# Check getty services
systemctl status console-getty.service
systemctl status container-getty@1.service
```

#### AppArmor Verification

```bash
# Check container's AppArmor profile
pct exec VMID -- cat /proc/self/attr/current

# Check configuration
grep "lxc.apparmor" /var/lib/lxc/VMID/config
```

## 🚀 Future Enhancements

Planned additions:

- Bulk VM operations
- Automated backup scheduling
- Network configuration templates
- Storage management utilities

---

*Scripts tested on Proxmox VE with Dell OptiPlex hardware. Results may vary in different environments.*
