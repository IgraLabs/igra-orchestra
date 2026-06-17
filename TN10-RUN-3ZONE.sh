#!/usr/bin/env bash
# 3-zone run: canonical + quantum + KYC. Adds --profile kyc-zone to the q-zone stack.
docker compose \
  -f docker-compose.yml \
  -f deploy/ethrex-galleon-staging/docker-compose.ethrex-galleon.yml \
  -f deploy/igra-q-zone-staging/docker-compose.q-zone-staging.yml \
  -f deploy/igra-q-zone-staging/docker-compose.q-zone-testnet.yml \
  --profile backend --profile q-zone --profile kyc-zone "$@"
