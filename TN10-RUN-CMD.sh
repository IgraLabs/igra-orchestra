#!/bin/bash
# Isolated-devnet q-zone stack (canonical + Falcon q-zone) — VERIFIED config resolves.
# Run from: tn10-deploy/orchestra-qzone (branch igra-q-logic-zone)
# Services: execution-layer (canonical ethrex), q-execution-layer (q-ethrex falcon), kaspad (adapter), miner
cd "$(dirname "$0")"
docker compose \
  -f docker-compose.yml \
  -f deploy/ethrex-galleon-staging/docker-compose.ethrex-galleon.yml \
  -f deploy/igra-q-zone-staging/docker-compose.q-zone-staging.yml \
  -f deploy/igra-q-zone-staging/docker-compose.q-zone-testnet.yml \
  --profile backend --profile q-zone "$@"
# usage: ./DEVNET-RUN-CMD.sh build   |   ./DEVNET-RUN-CMD.sh up -d   |   ./DEVNET-RUN-CMD.sh logs -f kaspad
