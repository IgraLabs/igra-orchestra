#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

IGRA_Q_BRANCH="${IGRA_Q_BRANCH:-igra-q-logic-zone}"
CANONICAL_ETHREX_BRANCH="${CANONICAL_ETHREX_BRANCH:-igra-mainnet-ethrex-integration}"
KASPA_MINER_BRANCH="${KASPA_MINER_BRANCH:-kaspa-current-rpc-protowire}"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

clone_or_update() {
    local repo_url="$1"
    local folder="$2"
    local branch="$3"
    local path="$PROJECT_DIR/build/repos/$folder"

    mkdir -p "$PROJECT_DIR/build/repos"

    if [[ ! -d "$path/.git" ]]; then
        log "Cloning $repo_url into $path"
        git clone "$repo_url" "$path"
    fi

    log "Checking out $folder branch $branch"
    git -C "$path" fetch origin
    git -C "$path" checkout "$branch"
    git -C "$path" pull --ff-only
}

clone_or_update "git@github.com:IgraLabs/rusty-kaspa-private.git" "rusty-kaspa-private" "$IGRA_Q_BRANCH"
clone_or_update "git@github.com:IgraLabs/ethrex.git" "ethrex-q" "$IGRA_Q_BRANCH"
clone_or_update "https://github.com/IgraLabs/kaspa-miner.git" "kaspa-miner" "$KASPA_MINER_BRANCH"

if [[ "${IGRA_Q_PREPARE_CANONICAL_ETHREX:-false}" == "true" ]]; then
    clone_or_update "git@github.com:IgraLabs/ethrex.git" "ethrex" "$CANONICAL_ETHREX_BRANCH"
fi

log "q-zone repos are ready"
