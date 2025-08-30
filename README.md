# Homelab Bash Scripts

A collection of my bash scripts for homelab automation and management, with a focus on security best practices.

## 🎯 Mission

Repos of workarounds or simply a working solution for common homelab challenges.

## Environment

This script collection is designed for my Proxmox HCI environment, consisting of:

- **2x Dell Optiplex 3080** (Intel i3-10100T, 64GB RAM, 960GB SSD + 256GB NVMe)
- **1x Dell OptiPlex 7040** (Intel i5-6500, 32GB RAM, 1TB SSD + 960GB NVMe)
- **1x Tower PC** (DIY NAS)

## 🚀 Current Scripts

### Proxmox Management

- **Debian 13 LXC Upgrade** - Comprehensive container upgrade with compatibility fixes
- **Debian 12 Cloud-Init Template** - Quick VM template creation for deployment

```bash
# LXC container upgrade
./proxmox/upgrade-lxc-debian13.sh --security-mode unconfined

# Create VM template  
./proxmox/create-debian12-cloudinit-template.sh 9003
```

For detailed usage instructions, see [`proxmox/README.md`](proxmox/README.md).

### Future Additions

More automation scripts for common homelab tasks will be added over time.

## Directory Structure

```
├── proxmox/                    # Proxmox-specific automation
│   ├── README.md                      # Proxmox scripts documentation
│   ├── upgrade-lxc-debian13.sh        # Comprehensive Debian 13 upgrade script
│   └── create-debian12-cloudinit-template.sh  # VM template creation
├── monitoring/                 # System monitoring and health checks
│   └── scrutiny/              # Scrutiny disk monitoring tools
├── networking/                # Network configuration and management (planned)
├── backup/                   # Backup automation scripts (planned)
├── deployment/              # Service deployment scripts (planned)
└── utils/                   # General utility scripts (planned)
```

## 🛡️ Security Philosophy

1. **Security by Default** - Recommend the most secure approach first
2. **Pragmatic Options** - Provide alternatives for different environments
3. **Clear Trade-offs** - Explain security implications honestly

### Example: AppArmor Approach

```bash
# ✅ We recommend this (most secure)
./upgrade-lxc-debian13.sh --security-mode custom

# ⚠️ We explain this (acceptable trade-off) 
./upgrade-lxc-debian13.sh --security-mode unconfined

# ❌ We document but discourage this
# Using privileged containers
```

## Usage Patterns

### For Learning

- Try different security approaches to understand implications
- Read the migration guide to understand the "why" behind solutions

### For Homelab

- Use unconfined AppArmor profiles for convenience
- Implement basic monitoring and backups
- Document your security trade-offs

### For Production

- Always use custom AppArmor profiles
- Implement comprehensive monitoring
- Regular security audits

## Security Monitoring

### Recommended Monitoring

```bash
# Monitor AppArmor activity
journalctl -f | grep apparmor

# Check container isolation
lxc-ls -f

# Validate security profiles
aa-status
```

### Regular Maintenance

- Keep all systems updated
- Review security logs regularly
- Monitor for official Proxmox updates
- Update to official solutions when available

## Contributing

I welcome contributions that:

- Improve security while maintaining functionality
- Add support for additional environments
- Enhance documentation and learning materials
- Report issues and edge cases

Please follow the security-first philosophy and always explain trade-offs clearly.

---

**Created by the community, for the community.**

*Security is not optional - it's about making informed choices.*
