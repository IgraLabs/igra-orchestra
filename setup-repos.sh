#!/bin/bash
# setup-repos.sh - Clone and setup repositories for Igra Orchestra

# Function to print help information
function print_help() {
    echo "Usage: ./setup-repos.sh"
    echo ""
    echo "Description:"
    echo "  This script clones and configures repositories for Igra Orchestra."
    echo "  It sets up each repository in the list with the appropriate branches."
    echo ""
    echo "Environment Variables:"
    echo "  You can override the default branches for each repository by setting the following environment variables:"
    echo "    EXECUTION_LAYER_BRANCH"
    echo "    KASWALLET_BRANCH"
    echo "    IGRA_RPC_PROVIDER_BRANCH"
    echo "    KASPAD_BRANCH"
    echo "    KASPA_MINER_BRANCH"
    echo ""
    echo "Examples:"
    echo "  ./setup-repos.sh"
    echo ""
    echo "  # Example with environment variables:"
    echo "  KASWALLET_BRANCH=my-branch ./setup-repos.sh"
    echo ""
    echo "Notes:"
    echo "  - Ensure you have the required permissions and SSH key set up to clone from private repositories."
    echo "  - Environment variables must be set before calling the script to take effect."
}

if [[ "$1" == "--help" || "$1" == "-h" ]]; then
    print_help
    exit 0
fi

# Function for timestamped log messages
function log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $@"
}

function panic() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $@" >&2
    echo >&2
    echo "Try './setup-repos.sh --help'" >&2
    exit 1
}

# Original working directory
SCRIPT_DIR="$(pwd)"

# Load environment variables from .env file if it exists
if [[ -f "$SCRIPT_DIR/.env" ]]; then
    log "Loading environment variables from .env file"
    set -a # Automatically export all variables
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/.env"
    set +a
else
    log ".env file not found, using default branch settings or environment variables."
fi

# Check if using pre-built images
USE_PREBUILT_IMAGES=${USE_PREBUILT_IMAGES:-false}

# Function to clone a repository if it doesn't exist
function clone_repo() {
    local repo_url=$1
    # Extract, e.g. kaspa-miner from git@github.com:elichai/kaspa-miner.git
    local folder=$(basename -s .git "$repo_url")

    log "Setting up $folder repository"
    if [[ -d "$SCRIPT_DIR/build/repos/$folder" ]]; then
        log "$folder repository already exists, skipping clone"
    else
        log "Cloning $folder repository..."
        git clone $repo_url "$SCRIPT_DIR/build/repos/$folder" \
            && log "Successfully cloned $folder repository" \
            || panic "Failed to clone $folder repository"
    fi
}

# Function to configure a repository
function configure_repo() {
    local repo_name=$1
    local repo_url=$2
    local branch=$3

    log "Configuring $repo_name repository"
    local folder=$(basename -s .git "$repo_url")
    cd "$SCRIPT_DIR/build/repos/$folder"
    log "Current directory: $(pwd)"

    log "Fetching latest changes..."
    git fetch \
        || panic "Failed to fetch changes for $repo_name"

    log "Checking out branch: $branch"
    git checkout $branch \
        || panic "Failed to checkout branch $branch for $repo_name"

    log "Pulling latest changes..."
    git pull \
        || panic "Failed to pull latest changes for $repo_name"

    log "Current branch info for $repo_name:"
    git --no-pager branch -v

    # Return to the script directory
    cd "$SCRIPT_DIR"
}

if [[ $# -gt 0 ]]; then
    panic "Unexpected parameter(s) $@"
fi

# Default branches
EXECUTION_LAYER_BRANCH=${EXECUTION_LAYER_BRANCH:-main}
KASWALLET_BRANCH=${KASWALLET_BRANCH:-main}
IGRA_RPC_PROVIDER_BRANCH=${IGRA_RPC_PROVIDER_BRANCH:-main}
KASPAD_BRANCH=${KASPAD_BRANCH:-master}
KASPA_MINER_BRANCH=${KASPA_MINER_BRANCH:-main}

log "Starting repository setup"

# Check if using pre-built images for proprietary services
if [[ "$USE_PREBUILT_IMAGES" == "true" ]]; then
    log "USE_PREBUILT_IMAGES is set to true"
    log "Will clone Kaspa miner repository only"
    log "All other services will use pre-built Docker images"

    REPOS=(
        "kaspa-miner      "
    )
    URLS=(
        "git@github.com:elichai/kaspa-miner.git"
    )
    BRANCHES=(
        "$KASPA_MINER_BRANCH"
    )
else
    log "USE_PREBUILT_IMAGES is set to false (or not set)"
    log "Will clone all repositories and build from source"

    # Repository information - all repositories
    REPOS=(
        "execution-layer  "
        "kaswallet        "
        "igra-rpc-provider"
        "kaspad           "
        "kaspa-miner      "
    )

    URLS=(
        "git@github.com:IgraLabs/execution-layer.git"
        "git@github.com:IgraLabs/kaswallet.git"
        "git@github.com:IgraLabs/igra-rpc-provider.git"
        "git@github.com:IgraLabs/rusty-kaspa-private.git"
        "git@github.com:elichai/kaspa-miner.git"
    )
    BRANCHES=(
        "$EXECUTION_LAYER_BRANCH"
        "$KASWALLET_BRANCH"
        "$IGRA_RPC_PROVIDER_BRANCH"
        "$KASPAD_BRANCH"
        "$KASPA_MINER_BRANCH"
    )
fi

# Log branch information
log "Using repos and branches:"
for i in "${!REPOS[@]}"; do
  log "  - ${REPOS[$i]} - ${URLS[$i]}::${BRANCHES[$i]}"
done


# Clone and configure repositories
for i in "${!REPOS[@]}"; do
    clone_repo "${URLS[$i]}"
    configure_repo "${REPOS[$i]}" "${URLS[$i]}" "${BRANCHES[$i]}"
done

log
log "==REPOSITORY SETUP COMPLETED SUCCESSFULLY=="
log "Repositories configured as follows:"
for i in "${!REPOS[@]}"; do
  log "  - ${REPOS[$i]} ${BRANCHES[$i]}"
done
log ""

# Provide appropriate instructions based on mode
if [[ "$USE_PREBUILT_IMAGES" == "true" ]]; then
    log "====================================================================="
    log "IMPORTANT: Using pre-built images mode"
    log "====================================================================="
    log ""
    log "Pulling pre-built images from Docker Hub..."

    # Pull and tag images
    services=("kaspad" "execution-layer" "rpc-provider" "kaswallet")
    for service in "${services[@]}"; do
        log "Pulling igranetwork/${service}:latest..."
        if docker pull "igranetwork/${service}:latest"; then
            log "Tagging as ${service}..."
            docker tag "igranetwork/${service}:latest" "${service}"
            log "✓ ${service} ready"
        else
            panic "Failed to pull igranetwork/${service}:latest. Make sure the image exists on Docker Hub."
        fi
    done

    log ""
    log "All images pulled and tagged successfully!"
    log ""
    log "You can now start services with:"
    log "  docker-compose up -d"
    log ""
    log "Note: Docker will use the pulled images instead of building from source."
else
    log "You can now run docker-compose build && docker-compose up"
fi
