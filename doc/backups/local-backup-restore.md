# Backup, Restore, and Monitoring Procedures

This document outlines the procedures for backing up, restoring, and monitoring data for various components within the IGRA Orchestra Devnet environment.

## Backup and Restore Scripts

The backup and restore functionality has been consolidated into unified scripts that work with multiple components.

### Backup (`scripts/backup/backup.sh`) — Two-Stage Flow

This script performs the following actions:

1.  Pauses the specified container and copies the volume contents to a local staging directory.
2.  Unpauses the container immediately after the copy completes (minimizing downtime).
3.  Compresses the staging directory into a timestamped `.tar.gz` archive in `$HOME/.backups/<container>-backups/`.
4.  Verifies the integrity of the archive.
5.  Prunes old backups, keeping the most recent N (configurable via `LOCAL_BACKUP_RETENTION_COUNT`).
6.  Optionally uploads the archive to S3 if `S3_BACKUP_AUTO_UPLOAD=true`.
7.  Logs all operations and timings; the "Container Frozen Time" reflects only pause/copy/unpause.

**Usage:**

```bash
./scripts/backup/backup.sh <container_name>
```

Examples:
```bash
./scripts/backup/backup.sh viaduct
./scripts/backup/backup.sh kaspad
```

### Restore (`scripts/backup/restore.sh`)

This script restores data from a backup file into the specified volume.

1.  Identifies the backup file (latest by default, or specified as an argument).
2.  Verifies the integrity of the selected backup file.
3.  Stops the specified container.
4.  **Prompts for confirmation** before clearing the *current* data in the target volume.
5.  Extracts the backup archive into the target volume.

**Usage:**

*   Restore the latest backup:
    ```bash
    ./scripts/backup/restore.sh <container_name>
    ```
*   Restore a specific backup file:
    ```bash
    ./scripts/backup/restore.sh <container_name> /path/to/your/backup/file.tar.gz
    ```

Examples:
```bash
# Restore latest viaduct backup
./scripts/backup/restore.sh viaduct

# Restore latest kaspad backup
./scripts/backup/restore.sh kaspad

# Restore specific viaduct backup
./scripts/backup/restore.sh viaduct "$HOME/.backups/viaduct-backups/igra-orchestra-devnet_viaduct_data_YYYYMMDD_HHMMSS.tar.gz"
```

**Warning:** The restore script will **delete** the current contents of the volume before restoring. Ensure you are restoring the correct backup.

## Viaduct Component

The `viaduct` service uses the `igra-orchestra-devnet_viaduct_data` Docker volume.

### Monitoring Volume Activity

You can monitor real-time filesystem events (creates, modifications, deletes, reads, writes) within the `igra-orchestra-devnet_viaduct_data` volume using `inotifywait` in a temporary container. This is useful for debugging or understanding how the `viaduct` container interacts with its data.

**Command:**

```bash
docker run -it --rm \
  -v igra-orchestra-devnet_viaduct_data:/watch:ro \
  alpine sh -c "apk add --no-cache inotify-tools && inotifywait -m -r -e create,modify,delete,open,close_write /watch"
```

This command:

*   Runs a temporary Alpine container (`--rm`).
*   Mounts the target volume read-only (`:ro`) to `/watch` inside the container.
*   Installs `inotify-tools`.
*   Runs `inotifywait` recursively (`-r`) and continuously (`-m`), watching the `/watch` directory for the specified events (`-e ...`).

Press `Ctrl+C` to stop monitoring.

## Inspecting Volume Data

After restoring data to a volume, you might want to inspect its contents to verify the restore process or to check the data itself. You can do this by mounting the Docker volume into a temporary container and navigating its filesystem.

**Steps:**

1.  **Identify the volume name:** This is related to the `<container_name>` used with backup/restore scripts (e.g., `igra-orchestra-devnet_viaduct_data` for the `viaduct` container). Refer to your Docker setup for exact volume names.
2.  **Run a temporary container with the volume mounted:**

    ```bash
    docker run -it --rm \
      -v <your_volume_name>:/mnt/inspected_volume \
      alpine sh
    ```

    Replace `<your_volume_name>` with the actual name of the volume you want to inspect. For example, for the `viaduct` component, if its data volume is `igra-orchestra-devnet_viaduct_data`, you would use that.

3.  **Navigate and inspect:** Once inside the container's shell, the volume content will be available at `/mnt/inspected_volume`.

    ```bash
    # cd /mnt/inspected_volume
    # ls -lah
    # # Use any other shell commands to explore (cat, find, grep, etc.)
    # exit
    ```

**Explanation of the command:**

*   `docker run -it --rm`: Runs a new container.
    *   `-i`: Keeps STDIN open even if not attached (interactive).
    *   `-t`: Allocates a pseudo-TTY (terminal).
    *   `--rm`: Automatically removes the container when it exits.
*   `-v <your_volume_name>:/mnt/inspected_volume`: Mounts the specified Docker volume (`<your_volume_name>`) to the `/mnt/inspected_volume` path inside the container.
*   `alpine sh`: Specifies the image to use (Alpine Linux, which is lightweight) and the command to run (the `sh` shell). You can use other images like `ubuntu` if `alpine` lacks tools you need.

**Example (inspecting the Viaduct volume):**

Assuming the Viaduct data volume is named `igra-orchestra-devnet_viaduct_data`:

```bash
docker run -it --rm \
  -v igra-orchestra-devnet_viaduct_data:/mnt/inspected_volume \
  alpine sh
```

Then, inside the container:
```bash
~ # cd /mnt/inspected_volume
/mnt/inspected_volume # ls -l
# ... (output of ls) ...
/mnt/inspected_volume # exit
```

---
*(Future sections for other components can be added here)*