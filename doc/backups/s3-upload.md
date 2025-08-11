# S3 Backup Upload

Upload IGRA Orchestra backups to AWS S3 for disaster recovery.

## Prerequisites

- AWS CLI installed:
  - macOS: `brew install awscli`
  - Linux: `sudo apt install awscli` or download from [AWS](https://aws.amazon.com/cli/)
- AWS credentials configured (`aws configure --profile igra-labs`)
- S3 configuration in `.env`:
  ```bash
  S3_BACKUP_BUCKET=igralabs-viaduct-archival-data
  S3_BACKUP_REGION=eu-north-1
  S3_BACKUP_RETENTION_COUNT=3  # Keep latest 3 backups
  ```

## Usage

```bash
# Upload latest backup
AWS_PROFILE=igra-labs ./scripts/backup/upload-to-s3.sh viaduct

# Upload specific backup
AWS_PROFILE=igra-labs ./scripts/backup/upload-to-s3.sh viaduct /path/to/backup.tar.gz

# List S3 backups
AWS_PROFILE=igra-labs ./scripts/backup/upload-to-s3.sh --list viaduct

# Dry run (preview changes)
AWS_PROFILE=igra-labs ./scripts/backup/upload-to-s3.sh --dry-run viaduct
```

## S3 Structure

```
s3://bucket/archival-data/igra-orchestra/{network}/
├── igra-orchestra-testnet_viaduct_data_20250812_143022.tar.gz
├── igra-orchestra-testnet_kaspad_data_20250812_150000.tar.gz
└── ...
```

## Features

- **Automatic Retention**: Keeps only latest 3 backups (configurable)
- **Verification**: MD5 checksum and file size validation
- **Retry Logic**: Automatic retry on failure (up to 3 attempts)
- **Progress Tracking**: Shows upload progress for large files
- **Logging**: Detailed logs in `~/.backups/{container}-backups/s3_upload_logs.log`

## Integration with Backup Script

```bash
# Manual: Run after backup
./scripts/backup/backup.sh viaduct
AWS_PROFILE=igra-labs ./scripts/backup/upload-to-s3.sh viaduct

# Automatic: Set in .env
S3_BACKUP_AUTO_UPLOAD=true
```

## Troubleshooting

| Issue | Solution |
|-------|----------|
| AWS CLI not found | Install: macOS: `brew install awscli`, Linux: `apt install awscli` |
| Permission denied | Check AWS credentials: `aws sts get-caller-identity --profile igra-labs` |
| Upload fails | Check network, credentials, and log file |
| Lock file exists | Remove stale lock: `rm /tmp/upload-to-s3.sh_*.lock` |

## Security

- Never commit AWS credentials
- Use IAM with minimal permissions (s3:PutObject, s3:GetObject, s3:ListBucket, s3:DeleteObject)
- Enable S3 bucket encryption

## Related

- [Local Backup](./local-backup-restore.md) - Local backup operations
- [S3 Download](./s3-download.md) - Download backups from S3