# IGRA Orchestra Backup Documentation

Complete backup and restore solutions for IGRA Orchestra components.

## Documentation Index

### 1. [Local Backup & Restore](./local-backup-restore.md)
- Create local backups of Docker volumes
- Restore from local backups
- Monitor volume activity
- Inspect volume data

### 2. [S3 Upload](./s3-upload.md)
- Upload backups to AWS S3
- Automatic retention management
- Integration with local backup workflow
- Requires AWS credentials

### 3. [S3 Download](./s3-download.md)
- Download backups from public S3 bucket
- No AWS credentials required
- Automatic latest backup selection
- Direct integration with restore

### 4. [Cron Automation](./cron-automation.md)
- Automated backups at 5 AM and 5 PM daily
- Automatic S3 upload integration
- Log management and monitoring
- Easy setup and configuration

## Quick Start

### Complete Backup Workflow
```bash
# 1. Create local backup
./scripts/backup/backup.sh viaduct

# 2. Upload to S3 (requires AWS credentials)
AWS_PROFILE=igra-labs ./scripts/backup/upload-to-s3.sh viaduct
```

### Disaster Recovery
```bash
# 1. Download latest backup from S3 (no credentials needed)
./scripts/backup/download-from-s3.sh viaduct

# 2. Restore from downloaded backup
./scripts/backup/restore.sh viaduct
```

## Backup Scripts Location

All backup scripts are in `scripts/backup/`:
- `backup.sh` - Create local backups
- `restore.sh` - Restore from backups
- `upload-to-s3.sh` - Upload to S3
- `download-from-s3.sh` - Download from S3

## Default Paths

- **Local backups**: `~/.backups/{container}-backups/`
- **S3 path**: `s3://bucket/archival-data/igra-orchestra/{network}/`
- **Logs**: `~/.backups/{container}-backups/*.log`

## Supported Containers

- `viaduct` - Viaduct data volume
- `kaspad` - Kaspad data volume
- Any other Docker container managed by IGRA Orchestra