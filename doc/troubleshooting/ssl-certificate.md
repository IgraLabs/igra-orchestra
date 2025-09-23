## Fix: Traefik "non-existent certificate resolver"

Symptom:
- Traefik log: resolver `myresolver` not found
- curl: SSL certificate problem: unable to get local issuer certificate

Cause:
- Stale/corrupted ACME storage or resolver didn’t init (e.g., empty `${IGRA_ORCHESTRA_DOMAIN_EMAIL}`).

Quick fix:
```bash
cd /Users/igor/git/igra-labs/igra-orchestra
docker compose rm -sf traefik
docker volume rm traefik_certs
docker compose up -d traefik && docker logs -f traefik
```

Verify:
- Logs show ACME init (no resolver error).
- `${IGRA_ORCHESTRA_DOMAIN_EMAIL}` is set.


