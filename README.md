# Synodus infrastructure

Docker Compose configurations, Envoy routing, and monitoring for Synodus.

## Local setup

Requires curl, OpenSSL, and a running Docker daemon accessible to your user.
Docker Compose must support `--wait-timeout`. Allow at least 8 GiB of free disk
space; about 4 GiB of RAM is recommended.

```bash
curl -fsSL https://raw.githubusercontent.com/CORTA-11/infra/main/setup-local.sh | bash
```

The installer creates `./synodus`, pulls public, pinned Docker images, generates
passwords and service secrets, applies migrations, configures database roles,
creates the storage bucket, and starts the application and monitoring. No
registry login, source checkout, build tools, or manual application configuration
is required. Wait for `Synodus is ready`, then open <http://localhost:10000> and
register an account.

Rerun the same command to refresh configuration and start the stack again.
Existing credentials and data are preserved. Use `bash -s -- --dir PATH` after
the pipe to choose another installation directory, or `--ref TAG_OR_BRANCH` to
select an infra configuration revision.

## Access and credentials

| Service | URL | Login |
| --- | --- | --- |
| Application | <http://localhost:10000> | Register an account |
| Grafana | <http://localhost:3001> | `admin`; `GRAFANA_ADMIN_PASSWORD` in `synodus/.env` |
| Prometheus | <http://localhost:9090> | No login |

Ports bind to localhost by default. For a remote server:

```bash
ssh -L 10000:localhost:10000 -L 3001:localhost:3001 user@server
```

Generated credentials live in `synodus/.env` and `synodus/secrets/`. Keep both
when moving or backing up the installation. Service secrets can be changed
later by recreating the affected containers. Rerunning setup applies changed
database role passwords; PostgreSQL administrator passwords must also be
changed in PostgreSQL. Change an existing Grafana password through Grafana.
External AI providers require their endpoint, model, and API token in the
application's AI settings.

## Manage the local stack

```bash
cd synodus
docker compose -f compose.local.yaml ps
docker compose -f compose.local.yaml logs --tail 100
docker compose -f compose.local.yaml up -d
docker compose -f compose.local.yaml down
```

`down` keeps data volumes. Adding `--volumes` deletes them. If setup fails,
containers and data are retained; inspect the logs, resolve the error, and rerun.

## Other workflows

- `compose.local.yaml`: complete local stack using published images, managed by
  `setup-local.sh`.
- `compose.yaml`: Envoy and monitoring for source development. Start the sibling
  service repositories on the external `synodus-network` first; follow their
  READMEs for setup.
- `docker-compose.prod.yaml` and `deploy.sh`: separate production deployment
  using HTTPS, production secrets, and certificates in `certs/`.

Envoy routes `/api/` to the API, `/ws/docs` to document collaboration, other
`/ws` traffic to the socket server, and everything else to the frontend.
Monitoring configuration lives in `prometheus/` and `grafana/`.
