# Log Cleanup Automation

Automated log cleanup system for Ubuntu servers to prevent disk exhaustion from Docker syslog and compressed logs.

## Quick Start

```bash
# Install
cd scripts/log-management
sudo ./install.sh

# Test
sudo /usr/local/bin/log-cleanup --dry-run

# Uninstall
sudo ./uninstall.sh
```

## Features

- **Removes all .gz files** from `/var/log` to free space
- **Truncates active logs** keeping last 10,000 lines
- **Runs daily at 3 AM** via cron
- **Docker-aware** for container log management
- **Dry-run mode** for safe testing

## Configuration

Edit `/etc/log-cleanup.conf`:

```bash
LOG_RETENTION_LINES=10000    # Lines to keep
LOG_DIR=/var/log             # Directory to clean
MIN_DISK_SPACE_GB=5          # Warning threshold
DRY_RUN=false                # Test mode
```

## Usage

```bash
# Manual run
sudo /usr/local/bin/log-cleanup

# Dry run (preview)
sudo /usr/local/bin/log-cleanup --dry-run

# Custom retention
sudo /usr/local/bin/log-cleanup --retention 5000

# Help
sudo /usr/local/bin/log-cleanup --help
```

## What Gets Cleaned

**Removed:**
- All `*.gz` files in `/var/log` and subdirectories

**Truncated (keeps recent lines):**
- `/var/log/syslog`
- `/var/log/auth.log`
- `/var/log/kern.log`
- `/var/log/messages`
- `/var/log/daemon.log`
- `/var/log/user.log`

## Monitoring

```bash
# View logs
tail -f /var/log/log-cleanup/cleanup.log

# Check last run
grep "CLEANUP SUMMARY" /var/log/log-cleanup/cleanup.log -A 10
```

## Troubleshooting

### Not Running Automatically

```bash
# Check cron
sudo systemctl status cron
cat /etc/cron.d/log-cleanup

# Test manually
sudo /usr/local/bin/log-cleanup --dry-run
```

### Permission Errors

```bash
# Ensure root execution
sudo /usr/local/bin/log-cleanup

# Check permissions
ls -la /usr/local/bin/log-cleanup
ls -la /etc/log-cleanup.conf
```

### No Space Freed

```bash
# Check what would be cleaned
sudo /usr/local/bin/log-cleanup --dry-run

# Adjust retention
sudo nano /etc/log-cleanup.conf
# Reduce LOG_RETENTION_LINES
```

## Security

⚠️ **WARNING**: Runs as root and deletes system files.

- Always test with `--dry-run` first
- Configuration file has restricted permissions (600)
- Uses flock to prevent concurrent execution
- Audit logs track all operations

## Alternative: Systemd Timer

```bash
# Use systemd instead of cron
sudo rm /etc/cron.d/log-cleanup
sudo systemctl enable --now log-cleanup.timer
sudo systemctl status log-cleanup.timer
```

## Files

- **Script**: `/usr/local/bin/log-cleanup`
- **Config**: `/etc/log-cleanup.conf`
- **Cron**: `/etc/cron.d/log-cleanup`
- **Logs**: `/var/log/log-cleanup/`

## Requirements

- Ubuntu 18.04+
- Root access
- Tools: `find`, `tail`, `df`, `awk`, `flock`