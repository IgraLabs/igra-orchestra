#!/usr/bin/env bash
set -euo pipefail

config_path="${KASPA_EXIT_BUILDER_CONFIG:-/work/proposal-builder/builder.json}"
federation_id="${KASPA_FEDERATION_ID:-}"
federation_id_file="${KASPA_FEDERATION_ID_FILE:-/work/results/federation.json}"
poll_seconds="${KASPA_EXIT_BUILDER_POLL_SECONDS:-300}"
mode="${KASPA_EXIT_BUILDER_MODE:-daemon}"

if [[ -z "${federation_id}" && -f "${federation_id_file}" ]]; then
    federation_id="$(python - "$federation_id_file" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    data = json.load(fh)
print(data.get("id") or data.get("federationId") or "")
PY
)"
fi

if [[ ! -f "${config_path}" ]]; then
    echo "proposal-builder config not found: ${config_path}" >&2
    exit 64
fi
if [[ -z "${federation_id}" ]]; then
    echo "KASPA_FEDERATION_ID is empty and ${federation_id_file} did not provide one" >&2
    exit 64
fi

python manage.py migrate kaspa --noinput

args=(
    python manage.py build_kaspa_exit_proposal
    --config "${config_path}"
    --federation "${federation_id}"
    --cast-bin "${KASPA_EXIT_BUILDER_CAST_BIN:-/usr/local/bin/cast}"
    --poll-seconds "${poll_seconds}"
)

if [[ "${mode}" == "daemon" ]]; then
    args+=(--daemon)
elif [[ "${mode}" != "once" ]]; then
    echo "Unsupported KASPA_EXIT_BUILDER_MODE=${mode}; use daemon or once" >&2
    exit 64
fi

if [[ "${KASPA_EXIT_BUILDER_SKIP_FINALITY_CHECK:-false}" == "true" ]]; then
    args+=(--skip-finality-check)
fi
if [[ "${KASPA_EXIT_BUILDER_SKIP_SUBMIT:-false}" == "true" ]]; then
    args+=(--skip-submit)
fi
if [[ "${KASPA_EXIT_BUILDER_ALLOW_NON_IGRA_LOCK_SCRIPT_FOR_TESTING:-false}" == "true" ]]; then
    args+=(--allow-non-igra-lock-script-for-testing)
fi

exec "${args[@]}"
