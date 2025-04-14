#!/bin/bash
# setup-repos.sh - Clone and setup repositories for Igra Orchestra

# Function for timestamped log messages
function log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $@"
}

function panic() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $@" >&2
    exit 1
}

# Function to clone a repository if it doesn't exist
function clone_repo() {
    local repo_name=$1
    local repo_url=$2

    log "Setting up $repo_name repository"
    if [ ! -d "repos/$repo_name" ]; then
        log "Cloning $repo_name repository..."
        git clone $repo_url repos/$repo_name
        if [ $? -eq 0 ]; then
            log "Successfully cloned $repo_name repository"
        else
            panic "Failed to clone $repo_name repository"
        fi
    else
        log "$repo_name repository already exists, skipping clone"
    fi
}

# Function to configure a repository
function configure_repo() {
    local repo_name=$1
    local branch=$2

    log "Configuring $repo_name repository"
    cd repos/$repo_name
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

    cd ../..
}

log "Starting repository setup"

# Default branches
BLOCK_BUILDER_BRANCH=${1:-main}
EXECUTION_LAYER_BRANCH=${2:-main}
KASWALLET_BRANCH=${3:-main}
IGRA_RPC_PROVIDER_BRANCH=${4:-igor/fix/docker-workaround}
VIADUCT_BRANCH=${5:-new_BB_syntax_rebased_to_v1}
KASPAD_BRANCH=${5:-for-wallet}

# Repository information
REPOS=(
    "block-builder    "
    "execution-layer  "
    "kaswallet        "
    "igra-rpc-provider"
    "viaduct          "
    "kaspad           "
)
URLS=(
    "git@github.com:IgraLabs/block-builder.git"
    "git@github.com:IgraLabs/execution-layer.git"
    "git@github.com:IgraLabs/kaswallet.git"
    "git@github.com:IgraLabs/igra-rpc-provider.git"
    "git@github.com:IgraLabs/rusty-kaspa-private.git"
    "git@github.com:IgraLabs/rusty-kaspa.git"
)
BRANCHES=(
    "$BLOCK_BUILDER_BRANCH"
    "$EXECUTION_LAYER_BRANCH"
    "$KASWALLET_BRANCH"
    "$IGRA_RPC_PROVIDER_BRANCH"
    "$VIADUCT_BRANCH"
    "$KASPAD_BRANCH"
)

# Log branch information
log "Using repos and branches:"
for i in "${!REPOS[@]}"; do
  log "  - ${REPOS[$i]} > ${URLS[$i]} > ${BRANCHES[$i]}"
done

# Create repos directory
if [ ! -d "repos" ]; then
    log "Creating repos folder..."
    mkdir -p repos
    log "Created directory: repos"
else
    log "Reusing repos folder"
fi

# Clone and configure repositories
for i in "${!REPOS[@]}"; do
    clone_repo "${REPOS[$i]}" "${URLS[$i]}"
    configure_repo "${REPOS[$i]}" "${BRANCHES[$i]}"
done

log
log "==REPOSITORY SETUP COMPLETED SUCCESSFULLY=="
log "Repositories configured as follows:"
for i in "${!REPOS[@]}"; do
  log "  - ${REPOS[$i]} ${BRANCHES[$i]}"
done
log ""
log "You can now run docker-compose build && docker-compose up"
