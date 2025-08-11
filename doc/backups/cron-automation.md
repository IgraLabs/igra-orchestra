# Automated Backup with Cron

Automatically backup IGRA Orchestra volumes twice daily at 5 AM and 5 PM.

## Quick Setup

```bash
# Install cron jobs (5 AM and 5 PM daily)
./scripts/backup/setup-cron.sh install

# Check status
./scripts/backup/setup-cron.sh status

# Test the backup script
./scripts/backup/setup-cron.sh test

# Remove cron jobs
./scripts/backup/setup-cron.sh uninstall
```

## Configuration

Add to your `.env` file:

```bash
# Containers to backup (space-separated)
CRON_BACKUP_CONTAINERS="viaduct kaspad"

# Enable automatic S3 upload after backup
S3_BACKUP_AUTO_UPLOAD=true

# AWS profile for S3 uploads
AWS_PROFILE=igra-labs
```

## How It Works

1. **Cron Schedule**: Runs at 5:00 AM and 5:00 PM daily
2. **Backup Process**:
   - Creates local backup using `backup.sh`
   - If enabled, uploads to S3 using `upload-to-s3.sh`
   - Logs all operations to `~/.backups/cron-logs/`
3. **Log Retention**: Keeps logs for 30 days

## Monitoring

### Check Cron Jobs
```bash
# View installed cron jobs
crontab -l | grep igra-orchestra

# Check backup status
./scripts/backup/setup-cron.sh status
```

### View Logs
```bash
# Latest log file
ls -lt ~/.backups/cron-logs/ | head -2

# View recent log
tail -f ~/.backups/cron-logs/backup_cron_*.log
```

## Troubleshooting

### Cron Not Running
```bash
# Check if cron service is running
service cron status  # Linux
sudo launchctl list | grep cron  # macOS

# Test the backup script manually
./scripts/backup/cron-backup.sh
```

### AWS Credentials
For cron jobs, ensure AWS credentials are configured:
```bash
# Option 1: Use AWS profile
aws configure --profile igra-labs

# Option 2: Use IAM role (for EC2)
# Automatically handled by AWS SDK
```

### Container Not Running
The script will skip containers that aren't running and log a warning.

## Manual Execution

Run the automated backup script manually:
```bash
cd /path/to/igra-orchestra
./scripts/backup/cron-backup.sh
```

## Email Notifications (Optional)

To receive email notifications, add to crontab:
```bash
MAILTO=your-email@example.com
0 5 * * * cd /path/to/igra-orchestra && ./scripts/backup/cron-backup.sh
0 17 * * * cd /path/to/igra-orchestra && ./scripts/backup/cron-backup.sh
```