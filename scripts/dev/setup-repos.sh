#!/bin/bash
# setup-repos.sh - Clone and setup repositories for Igra Orchestra

# Function to print help information
function print_help() {
    echo "Usage: ./scripts/dev/setup-repos.sh"
    echo ""
    echo "Description:"
    echo "  This script clones and configures repositories for Igra Orchestra."
    echo "  It sets up each repository in the list with the appropriate branches."
    echo ""
    echo "Environment Variables:"
    echo "  ORCHESTRA_ENV_FILE selects the env file to load (default: .env)."
    echo "  You can override the default branches for each repository by setting the following environment variables:"
    echo "    RETH_BRANCH"
    echo "    KASWALLET_BRANCH"
    echo "    IGRA_RPC_PROVIDER_BRANCH"
    echo "    KASPAD_BRANCH"
    echo "    KASPA_MINER_BRANCH"
    echo "  You can override repository URLs with RETH_REPO_URL, KASWALLET_REPO_URL,"
    echo "  IGRA_RPC_PROVIDER_REPO_URL, KASPAD_REPO_URL, and KASPA_MINER_REPO_URL."
    echo ""
    echo "Examples:"
    echo "  ./scripts/dev/setup-repos.sh"
    echo ""
    echo "  # Example with environment variables:"
    echo "  KASWALLET_BRANCH=my-branch ./scripts/dev/setup-repos.sh"
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
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

function panic() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
    echo >&2
    echo "Try './scripts/dev/setup-repos.sh --help'" >&2
    exit 1
}

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Project root is two levels up from scripts/dev/
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Load environment variables from the selected env file if it exists
ORCHESTRA_ENV_FILE=${ORCHESTRA_ENV_FILE:-.env}
if [[ "$ORCHESTRA_ENV_FILE" != /* ]]; then
    ORCHESTRA_ENV_FILE="$PROJECT_DIR/$ORCHESTRA_ENV_FILE"
fi

if [[ -f "$ORCHESTRA_ENV_FILE" ]]; then
    log "Loading environment variables from $ORCHESTRA_ENV_FILE"
    set -a # Automatically export all variables
    # shellcheck source=/dev/null
    source "$ORCHESTRA_ENV_FILE"
    set +a
else
    log "Env file not found at $ORCHESTRA_ENV_FILE, using default branch settings or environment variables."
fi

# Check if using pre-built images
USE_PREBUILT_IMAGES=${USE_PREBUILT_IMAGES:-false}

# Function to clone a repository if it doesn't exist
function clone_repo() {
    local repo_url=$1
    # Extract, e.g. kaspa-miner from git@github.com:elichai/kaspa-miner.git
    local folder
    folder=$(basename -s .git "$repo_url")

    log "Setting up $folder repository"
    if [[ -d "$PROJECT_DIR/build/repos/$folder" ]]; then
        log "$folder repository already exists, skipping clone"
    else
        log "Cloning $folder repository..."
        if git clone "$repo_url" "$PROJECT_DIR/build/repos/$folder"; then
            log "Successfully cloned $folder repository"
        else
            panic "Failed to clone $folder repository"
        fi
    fi
}

# Function to configure a repository
function configure_repo() {
    local repo_name=$1
    local repo_url=$2
    local branch=$3

    log "Configuring $repo_name repository"
    local folder
    folder=$(basename -s .git "$repo_url")
    cd "$PROJECT_DIR/build/repos/$folder" || panic "Failed to cd into $folder"
    log "Current directory: $(pwd)"

    log "Fetching latest changes..."
    git fetch \
        || panic "Failed to fetch changes for $repo_name"

    log "Checking out branch: $branch"
    git checkout "$branch" \
        || panic "Failed to checkout branch $branch for $repo_name"

    log "Pulling latest changes..."
    git pull \
        || panic "Failed to pull latest changes for $repo_name"

    log "Current branch info for $repo_name:"
    git --no-pager branch -v

    # Return to the project directory
    cd "$PROJECT_DIR" || panic "Failed to cd back to project directory"
}

if [[ $# -gt 0 ]]; then
    panic "Unexpected parameter(s) $*"
fi

# Default branches
RETH_BRANCH=${RETH_BRANCH:-production}
KASWALLET_BRANCH=${KASWALLET_BRANCH:-main}
IGRA_RPC_PROVIDER_BRANCH=${IGRA_RPC_PROVIDER_BRANCH:-main}
KASPAD_BRANCH=${KASPAD_BRANCH:-master}
KASPA_MINER_BRANCH=${KASPA_MINER_BRANCH:-main}

RETH_REPO_URL=${RETH_REPO_URL:-git@github.com:IgraLabs/reth-private.git}
KASWALLET_REPO_URL=${KASWALLET_REPO_URL:-git@github.com:IgraLabs/kaswallet.git}
IGRA_RPC_PROVIDER_REPO_URL=${IGRA_RPC_PROVIDER_REPO_URL:-git@github.com:IgraLabs/igra-rpc-provider.git}
KASPAD_REPO_URL=${KASPAD_REPO_URL:-git@github.com:IgraLabs/rusty-kaspa-private.git}
KASPA_MINER_REPO_URL=${KASPA_MINER_REPO_URL:-git@github.com:elichai/kaspa-miner.git}

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
        "$KASPA_MINER_REPO_URL"
    )
    BRANCHES=(
        "$KASPA_MINER_BRANCH"
    )
else
    log "USE_PREBUILT_IMAGES is set to false (or not set)"
    log "Will clone all repositories and build from source"

    # Repository information - all repositories
    REPOS=(
        "reth             "
        "kaswallet        "
        "igra-rpc-provider"
        "kaspad           "
        "kaspa-miner      "
    )

    URLS=(
        "$RETH_REPO_URL"
        "$KASWALLET_REPO_URL"
        "$IGRA_RPC_PROVIDER_REPO_URL"
        "$KASPAD_REPO_URL"
        "$KASPA_MINER_REPO_URL"
    )
    BRANCHES=(
        "$RETH_BRANCH"
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

    # Pick the same version file docker-compose and the deployment guides use per network.
    # Fail loudly on unknown/missing NETWORK rather than silently pulling mainnet tags onto a
    # testnet datadir (or vice versa) — mixing image versions across networks is a deploy footgun.
    # Reject mixed-case (e.g. "Mainnet") at the source: docker-compose interpolates ${NETWORK}
    # verbatim into kaspad CLI flags (--$NETWORK) and the compose project name, so a value that
    # passes here but isn't lowercase would break compose-up downstream.
    if [[ -z "${NETWORK:-}" ]]; then
        panic "NETWORK is not set. Configure it in .env or export it before running with USE_PREBUILT_IMAGES=true."
    fi
    case "$NETWORK" in
        mainnet)
            versions_file="$PROJECT_DIR/versions.mainnet.env"
            ;;
        testnet)
            versions_file="$PROJECT_DIR/versions.testnet.env"
            ;;
        *)
            panic "Unsupported NETWORK='$NETWORK'. Set NETWORK to lowercase 'mainnet' or 'testnet'."
            ;;
    esac

    if [[ -f "$versions_file" ]]; then
        log "Sourcing image versions from $(basename "$versions_file") (NETWORK=$NETWORK)"
        # shellcheck source=/dev/null
        source "$versions_file"
    else
        panic "Version file not found: $versions_file (NETWORK=$NETWORK)"
    fi

    # Pull and tag images (versions from the selected versions.*.env)
    # Format: "image_name:version:local_tag"
    images=(
        "kaspad:${KASPAD_VERSION}:kaspad"
        "reth:${RETH_VERSION}:execution-layer"
        "rpc-provider:${RPC_PROVIDER_VERSION}:rpc-provider"
        "kaswallet:${KASWALLET_VERSION}:kaswallet"
    )
    for entry in "${images[@]}"; do
        IFS=':' read -r image version local_tag <<< "$entry"
        log "Pulling igranetwork/${image}:${version}..."
        if docker pull "igranetwork/${image}:${version}"; then
            log "Tagging as ${local_tag}..."
            docker tag "igranetwork/${image}:${version}" "${local_tag}"
            log "✓ ${local_tag} ready"
        else
            panic "Failed to pull igranetwork/${image}:${version}. Make sure the image exists on Docker Hub."
        fi
    done

    log ""
    log "All images pulled and tagged successfully!"
    log ""
    log "You can now start services with:"
    log "  docker compose up -d"
    log ""
    log "Note: Docker will use the pulled images instead of building from source."
else
    log "You can now run docker compose build && docker compose up"
fi
