#!/usr/bin/env bash
set -euo pipefail

config_path="${IGRA_PROPOSAL_BUILDER_CONFIG:-/work/proposal-builder/builder.json}"
poll_seconds="${KASPA_EXIT_BUILDER_POLL_SECONDS:-300}"
mode="${KASPA_EXIT_BUILDER_MODE:-daemon}"

if [[ ! -f "${config_path}" ]]; then
    echo "proposal-builder config not found: ${config_path}" >&2
    exit 64
fi

igra-proposal-builder --config "${config_path}" validate-config >/tmp/igra-proposal-builder-config.json

if [[ "${mode}" == "daemon" ]]; then
    exec igra-proposal-builder --config "${config_path}" daemon --poll-seconds "${poll_seconds}"
elif [[ "${mode}" == "once" || "${mode}" == "run-once" ]]; then
    exec igra-proposal-builder --config "${config_path}" run-once
else
    echo "Unsupported KASPA_EXIT_BUILDER_MODE=${mode}; use daemon or once" >&2
    exit 64
fi
