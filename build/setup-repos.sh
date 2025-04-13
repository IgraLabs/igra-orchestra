#!/bin/bash
# setup-repos.sh - Clone and setup repositories for Igra Orchestra

# Function for timestamped log messages
function log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
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
            log "ERROR: Failed to clone $repo_name repository"
            exit 1
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
    git fetch
    if [ $? -ne 0 ]; then
        log "ERROR: Failed to fetch changes for $repo_name"
        exit 1
    fi

    log "Checking out branch: $branch"
    git checkout $branch
    if [ $? -ne 0 ]; then
        log "ERROR: Failed to checkout branch $branch for $repo_name"
        exit 1
    fi

    log "Pulling latest changes..."
    git pull
    if [ $? -ne 0 ]; then
        log "ERROR: Failed to pull latest changes for $repo_name"
        exit 1
    fi

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
RUSTY_KASPA_BRANCH=${5:-new_BB_syntax_rebased_to_v1}

# Repository information
REPOS=("block-builder" "execution-layer" "kaswallet" "igra-rpc-provider" "rusty-kaspa-private")
URLS=(
    "git@github.com:IgraLabs/block-builder.git"
    "git@github.com:IgraLabs/execution-layer.git"
    "git@github.com:IgraLabs/kaswallet.git"
    "git@github.com:IgraLabs/igra-rpc-provider.git"
    "git@github.com:IgraLabs/rusty-kaspa-private.git"
)
BRANCHES=("$BLOCK_BUILDER_BRANCH" "$EXECUTION_LAYER_BRANCH" "$KASWALLET_BRANCH" "$IGRA_RPC_PROVIDER_BRANCH" "$RUSTY_KASPA_BRANCH")

# Log branch information
log "Using branches:"
log "  - block-builder: $BLOCK_BUILDER_BRANCH"
log "  - execution-layer: $EXECUTION_LAYER_BRANCH"
log "  - kaswallet: $KASWALLET_BRANCH"
log "  - igra-rpc-provider: $IGRA_RPC_PROVIDER_BRANCH"
log "  - rusty-kaspa-private: $RUSTY_KASPA_BRANCH"

# Create repos directory
log "Creating repos directory if it doesn't exist..."
if [ ! -d "repos" ]; then
    mkdir -p repos
    log "Created directory: repos"
else
    log "Directory repos already exists"
fi

# Clone and configure repositories
for i in "${!REPOS[@]}"; do
    clone_repo "${REPOS[$i]}" "${URLS[$i]}"
    configure_repo "${REPOS[$i]}" "${BRANCHES[$i]}"
done

log "==REPOSITORY SETUP COMPLETED SUCCESSFULLY=="
log "Repositories configured successfully:"
log "  - block-builder: $BLOCK_BUILDER_BRANCH"
log "  - execution-layer: $EXECUTION_LAYER_BRANCH"
log "  - kaswallet: $KASWALLET_BRANCH"
log "  - igra-rpc-provider: $IGRA_RPC_PROVIDER_BRANCH"
log "  - rusty-kaspa-private: $RUSTY_KASPA_BRANCH"
log ""
log "You can now run docker-compose build && docker-compose up"
