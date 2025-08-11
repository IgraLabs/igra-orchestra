# S3 Backup Download

Download IGRA Orchestra backups from public S3 bucket for disaster recovery.

## Overview

The `download-from-s3.sh` script downloads backups from a **public S3 bucket** - no AWS credentials required.

## Usage

```bash
# Download latest backup (saves to ~/.backups/{container}-backups/)
./scripts/backup/download-from-s3.sh viaduct

# Download specific backup
./scripts/backup/download-from-s3.sh viaduct igra-orchestra-testnet_viaduct_data_20250812_173649.tar.gz

# List available backups
./scripts/backup/download-from-s3.sh --list viaduct

# Download to custom directory
./scripts/backup/download-from-s3.sh --output-dir /tmp/restore viaduct

# Dry run (preview without downloading)
./scripts/backup/download-from-s3.sh --dry-run viaduct
```

## Default Behavior

- **Download location**: `~/.backups/{container}-backups/`
- **Auto-create directory**: Creates backup directory if it doesn't exist
- **Latest backup**: Automatically selects most recent if not specified
- **Verification**: Validates archive integrity after download

## Features

- **No Authentication Required**: Public bucket access
- **Automatic Directory Creation**: Creates `~/.backups/{container}-backups/` if needed
- **Archive Verification**: Checks tar.gz integrity
- **MD5 Checksum**: Calculates and displays for verification
- **Progress Bar**: Shows download progress
- **Latest Backup Selection**: Automatically finds most recent backup

## Configuration

Optional environment variables (defaults work for most cases):
```bash
S3_BACKUP_BUCKET=igralabs-viaduct-archival-data  # Default bucket
S3_BACKUP_REGION=eu-north-1                      # Default region
NETWORK=testnet                                  # Default network
```

## Restore Workflow

```bash
# 1. Download latest backup
./scripts/backup/download-from-s3.sh viaduct

# 2. Restore from downloaded backup
./scripts/backup/restore.sh viaduct ~/.backups/viaduct-backups/igra-orchestra-testnet_viaduct_data_YYYYMMDD_HHMMSS.tar.gz
```

## Quick Disaster Recovery

```bash
# Download and restore in one command
./scripts/backup/download-from-s3.sh viaduct && \
./scripts/backup/restore.sh viaduct
```

## Verify Downloads

```bash
# List downloaded files
ls -la ~/.backups/viaduct-backups/

# Check file integrity
tar -tzf ~/.backups/viaduct-backups/igra-orchestra-*.tar.gz > /dev/null && echo "Archive OK"

# Calculate MD5 checksum
# macOS
md5 -q ~/.backups/viaduct-backups/igra-orchestra-*.tar.gz
# Linux
md5sum ~/.backups/viaduct-backups/igra-orchestra-*.tar.gz | cut -d' ' -f1
```

## Troubleshooting

| Issue | Solution |
|-------|----------|
| No backups found | Check container name matches uploaded backups |
| Download fails | Check internet connection and S3 bucket availability |
| Archive corrupted | Re-download or try different backup |
| Permission denied | Ensure write access to download directory |

## Examples

### Download All Container Backups
```bash
for container in viaduct kaspad; do
    ./scripts/backup/download-from-s3.sh --list $container
    ./scripts/backup/download-from-s3.sh $container
done
```

### Disaster Recovery Test
```bash
# Download to test directory
./scripts/backup/download-from-s3.sh --output-dir /tmp/dr-test viaduct

# Verify download
ls -la /tmp/dr-test/
```

## Related

- [Local Backup](./local-backup-restore.md) - Local backup operations
- [S3 Upload](./s3-upload.md) - Upload backups to S3