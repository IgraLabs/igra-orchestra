# Kaspad DB Upgrade Prompt

Kaspad can stop during startup with:

```text
NOTE: Node database is from an older version. Proceeding with the upgrade is instant and safe.
However, downgrading to an older node version later will require deleting the database.
Do you confirm? (y/n)
Operation was rejected (), exiting..
```

This happens because kaspad is asking for interactive approval inside Docker.
For this older-version metadata upgrade, start kaspad once with its
noninteractive approval env var:

```bash
KASPAD_NONINTERACTIVE=true docker compose --profile backend up -d --no-build --force-recreate kaspad
docker compose logs -f kaspad
```

After kaspad starts past the upgrade prompt, recreate it without the temporary
approval:

```bash
docker compose --profile backend up -d --no-build --force-recreate kaspad
docker compose logs -f kaspad
```

`KASPAD_NONINTERACTIVE=true` maps to kaspad `--yes`, which answers all kaspad
interactive prompts. Use it only for this known safe older-version metadata
upgrade and do not leave it in `.env`.

`docker compose --yes` is unrelated; it answers Docker Compose prompts, not
kaspad prompts.

If the command still exits with `Operation was rejected (), exiting..`, update
the deployment checkout first. Older compose files did not pass
`KASPAD_NONINTERACTIVE` into the kaspad container.
