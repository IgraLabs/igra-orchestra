#!/bin/bash
# setup-repos.sh - Clone and setup repositories for Igra Orchestra

# Function to print help information
function print_help() {
    echo "Usage: ./setup-repos.sh [--dev]"
    echo ""
    echo "Description:"
    echo "  This script clones and configures repositories for Igra Orchestra."
    echo "  It sets up each repository in the list with the appropriate branches."
    echo ""
    echo "Options:"
    echo "  --dev    Use this flag for the development environment. Adds 'kaspad' and 'kaspa-miner' repositories to the setup."
    echo "  (empty)  Run the script without any arguments for the standard setup without dev-specific repositories."
    echo ""
    echo "Environment Variables:"
    echo "  You can override the default branches for each repository by setting the following environment variables:"
    echo "    BLOCK_BUILDER_BRANCH"
    echo "    EXECUTION_LAYER_BRANCH"
    echo "    KASWALLET_BRANCH"
    echo "    IGRA_RPC_PROVIDER_BRANCH"
    echo "    VIADUCT_BRANCH"
    echo "    KASPAD_BRANCH"
    echo "    KASPA_MINER_BRANCH"
    echo ""
    echo "Examples:"
    echo "  ./setup-repos.sh           # Standard setup."
    echo "  ./setup-repos.sh --dev     # Development setup with additional repositories."
    echo ""
    echo "  # Example with environment variables:"
    echo "  KASWALLET_BRANCH=my-branch ./setup-repos.sh --dev"
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

is_dev_env=
if [[ $# -gt 0 ]]; then
    if [[ $# -gt 1 || "$1" != "--dev" ]]; then
        panic "Unexpected parameter(s) $@"
    fi
    is_dev_env="Y"
    shift
fi

# Default branches
BLOCK_BUILDER_BRANCH=${BLOCK_BUILDER_BRANCH:-main}
EXECUTION_LAYER_BRANCH=${EXECUTION_LAYER_BRANCH:-main}
KASWALLET_BRANCH=${KASWALLET_BRANCH:-main}
IGRA_RPC_PROVIDER_BRANCH=${IGRA_RPC_PROVIDER_BRANCH:-main}
VIADUCT_BRANCH=${VIADUCT_BRANCH:-updated_storage_tests}
KASPAD_BRANCH=${KASPAD_BRANCH:-for-wallet}
KASPA_MINER_BRANCH=${KASPA_MINER_BRANCH:-main}

log "Starting repository setup"

# Repository information
REPOS=(
    "block-builder    "
    "execution-layer  "
    "kaswallet        "
    "igra-rpc-provider"
    "viaduct          "
)
if [[ ${is_dev_env} == "Y" ]]; then
    REPOS+=(
      "kaspad           "
      "kaspa-miner      "
    )
fi

URLS=(
    "git@github.com:IgraLabs/block-builder.git"
    "git@github.com:IgraLabs/execution-layer.git"
    "git@github.com:IgraLabs/kaswallet.git"
    "git@github.com:IgraLabs/igra-rpc-provider.git"
    "git@github.com:IgraLabs/rusty-kaspa-private.git"
    "git@github.com:IgraLabs/rusty-kaspa.git"
    "git@github.com:elichai/kaspa-miner.git"
)
BRANCHES=(
    "$BLOCK_BUILDER_BRANCH"
    "$EXECUTION_LAYER_BRANCH"
    "$KASWALLET_BRANCH"
    "$IGRA_RPC_PROVIDER_BRANCH"
    "$VIADUCT_BRANCH"
    "$KASPAD_BRANCH"
    "$KASPA_MINER_BRANCH"
)

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
log "You can now run docker-compose build && docker-compose up"
