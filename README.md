# Infra

Envoy exposes the local Docker stack at `http://localhost:10000`.

## One-command local setup

Install Git, curl, OpenSSL, and Docker with Compose v2+ (including
`--wait-timeout` support), then start Docker. On Linux or macOS, run:

```bash
curl -fsSL https://raw.githubusercontent.com/CORTA-11/infra/main/setup-local.sh | bash
```

The command clones all five repositories into `./synodus`, builds the services, applies
public database migrations and role passwords, creates the MinIO bucket, and
starts the API, tenant provisioner, AI service, chat and Document collaboration,
frontend, Envoy, Prometheus, and Grafana. Go, Node.js, and Python run inside
Docker; they are not required on your machine. Allow time and disk space for
the initial image builds. Repository access must be available to Git; private
repositories require your existing Git credentials.

For existing sibling checkouts, use the installer directly:

```bash
bash infra/setup-local.sh
```

To choose the destination for a downloaded installer:

```bash
curl -fsSL https://raw.githubusercontent.com/CORTA-11/infra/main/setup-local.sh | bash -s -- --dir "$HOME/synodus"
```

Rerunning preserves existing checkouts, environment values, secret files, and
database volumes, and reapplies migrations. It does not pull changes into
existing repositories. `--ref TAG_OR_BRANCH` selects the same ref for all new
clones; that ref must exist in every repository. The installer is intended for
local development.

No application configuration or password entry is required. On a fresh install,
OpenSSL generates unique random passwords for the database administrator and
three database roles, MinIO, and Grafana, plus the JWT, collaboration, cursor,
AI service, rate-limit, invitation-binding, and CSRF secrets. The API and MinIO
receive matching storage credentials; the API and realtime/AI services share
their respective service secrets automatically. Existing credentials are retained.

Credentials are stored locally in:

- `core-api/.env`: JWT, collaboration, cursor, and AI service secrets.
- `core-api/.local_secrets/`: database and storage credentials, rate-limit,
  invitation-binding, and CSRF secrets.
- `infra/.env`: Grafana admin password.

Environment files and the secret directory are accessible only to the installing
user. Individual secret files are readable by the container users when mounted.
These paths are ignored by Git. You can change credentials later: recreate the
affected containers after changing service secrets; rerunning setup applies
changed database role passwords. Changing the PostgreSQL administrator password
also requires changing it in PostgreSQL before rerunning setup. Change an existing
Grafana account password through Grafana; its environment value only initializes
the first account.

Open <http://localhost:10000> and register your first account; demo data is not
seeded. Grafana is at <http://localhost:3001>; its generated admin password is
stored in `infra/.env`. Setup checks application and monitoring readiness before
reporting success. On failure, it leaves containers and data available for
diagnosis; fix the reported error and rerun.

The AI service starts automatically. Using an external AI provider still requires
that provider's endpoint, model, and API token in the application's AI settings;
the installer cannot generate credentials for a third-party account.

Routes:

- `/api/` forwards to `core-api` on port 8080.
- `/ws/docs` forwards Document collaboration upgrades to the independent
  `collaboration-server` on port 8082.
- other `/ws` requests continue to forward to the Go `socket-server` on port
  8081.
- everything else forwards to `web-frontend` on port 3000.

Start it after the backend and frontend services have joined the shared
`synodus-network`:

```bash
docker compose up -d
```

## Reproducible local collaboration stack

The installer above automates these steps. For manual startup, the sibling
repositories are expected at `../core-api`, `../ai-service`,
`../socket-server`, and `../web-frontend`. Create the shared network once,
initialize core-api as described in its README, then start the named services:

```bash
docker network inspect synodus-network >/dev/null 2>&1 || docker network create synodus-network

cd ../core-api
cp -n .env.example .env
cp -R dev_secrets .local_secrets
docker compose up -d postgres redis minio
make bootstrap-db
make bootstrap
export RATE_LIMIT_LOGIN_IP_LIMIT=100
export RATE_LIMIT_LOGIN_IP_BURST=100
docker compose up --build -d api socket-server collaboration-server

cd ../web-frontend
cp -n .env.example .env.local
docker compose up --build -d web

cd ../infra
docker compose up -d
```

The defaults use the same public origins (`http://localhost:10000` and the
direct `:3000` development origin), `JWT_SECRET`, and
`COLLABORATION_SERVICE_SECRET`. Within Compose, `collaboration-server:8082`
loads and stores state through the private `api:8080` address. Browsers use only
Envoy: `/api/` for REST, `/ws/docs` for Hocuspocus, and `/ws` for chat.

Validate each public seam after startup:

```bash
curl -fsS http://localhost:9901/ready
curl -i http://localhost:10000/api/v1/auth/session   # expected 401 without a session
curl -fsS http://localhost:8081/health
curl -fsS http://localhost:8082/health
npm --prefix ../socket-server/collaboration ci
npm --prefix ../socket-server/collaboration run smoke -- ws://localhost:10000/ws/docs
```

The WebSocket smoke check expects the public route to upgrade and then reject
the missing ticket. A successful unauthorized connection would be a failure.

Payload admission remains owned by the upstream services: browser Document
JSON is limited to 64 KiB by core-api, the collaboration process accepts at
most 6 MiB per WebSocket message and canonical Yjs state, and private state
responses are read with a 16 MiB ceiling. The matching environment values are
declared in `socket-server/.env.example` and the core-api Compose service.

The first release runs one `collaboration-server` replica. Envoy does not yet
provide sticky or distributed Document Room routing; Redis-backed horizontal
room scaling is out of scope.

## Prometheus and Grafana

Monitoring starts automatically with the local and production stacks. Both
Compose files extend the shared services in `docker-compose.yaml`.
`./deploy.sh` (including deployments targeting one service) starts monitoring
and generates `GRAFANA_ADMIN_PASSWORD` in `.env` if it is missing, empty, or a
placeholder (including `admin`). The environment file is restricted to its owner.

For direct Compose commands, set `GRAFANA_ADMIN_PASSWORD` to a strong password in your ignored `.env` file
(see `.env.example`). The initial username is `admin`, configurable with
`GRAFANA_ADMIN_USER`. The password environment variable only initializes a new
Grafana database; change an existing account password through Grafana.

After preparing the local stack as above, start monitoring with:

```bash
docker compose up -d
```

For production, with the usual application secrets and TLS certificates ready:

```bash
./deploy.sh
```

Production chat summarisation uses the `ai-service` image published to GHCR.
`deploy.sh` generates a shared `AI_SERVICE_TOKEN` and starts `ai-service`
before `api`. The ai-service publishing workflow makes the image available;
run `./deploy.sh ai-service` and `./deploy.sh api` after a new image release.
The AI container is reachable only on the application network at
`http://ai-service:8080`.

Production API and WebSocket origin lists include `https://synodus.teshank.org`
alongside `https://geeth.cf` and `https://www.geeth.cf`. `deploy.sh` adds the
new origin to existing `.env` files. Envoy serves the certificate files in
`certs/`, which must cover the active hostname.

Use `-f docker-compose.prod.yaml` for production `logs`, `restart`, and `down`
commands. Monitoring uses named volumes for metrics and Grafana state. Metrics
retention is 15 days or 5 GB of stored blocks, whichever limit is reached first;
allow additional disk space for the write-ahead log and active data. `down`
preserves the volumes; `down -v` deletes them.

- Grafana: <http://localhost:3001>, with a provisioned Prometheus data source
  and the **Infra / Infra Overview** dashboard. Port 3001 avoids the frontend's
  development port 3000. Edit the dashboard JSON in `grafana/dashboards` to
  persist dashboard changes.
- Prometheus: <http://localhost:9090>, scraping itself, Node Exporter, and
  Envoy's private `envoy:9901/stats/prometheus` endpoint every 15 seconds.
- Node Exporter reads Linux host CPU, memory, and filesystem metrics using
  read-only host mounts. On Docker Desktop, these describe the Linux VM.
  Its port is available only inside the monitoring network.

The published monitoring ports and Envoy admin port bind to localhost. For a
remote host, use an SSH tunnel:

```bash
ssh -L 3001:127.0.0.1:3001 -L 9090:127.0.0.1:9090 user@your-server
```

Verify after startup (allow at least 30 seconds for scrapes, and several minutes
for rate panels):

```bash
curl -fsS http://localhost:9090/-/ready
curl -fsS http://localhost:3001/api/health
curl -fsS http://localhost:9090/api/v1/targets
curl -fsS http://localhost:9901/ready
```

All three jobs should report `health: up` in the targets response. Application
metrics endpoints are not assumed; Envoy panels show proxy traffic to the
upstreams. Envoy must be running successfully for its scrape target to be up.
Local Compose uses `envoy.local.yaml` for HTTP on port 10000 without certificates.
Production uses `envoy.yaml` for HTTP-to-HTTPS redirects and TLS, mounting
`./certs` at `/etc/envoy/certs`. Keep application routes aligned in both files.

Configuration follows the official [Grafana provisioning documentation](https://grafana.com/docs/grafana/latest/administration/provisioning/)
and [Envoy metrics endpoint documentation](https://www.envoyproxy.io/docs/envoy/latest/operations/admin).

## Configuration validation

```bash
docker compose config
docker compose run --rm envoy --mode validate -c /etc/envoy/envoy.yaml

# With GRAFANA_ADMIN_PASSWORD set in .env:
docker compose -f docker-compose.prod.yaml config --quiet
docker compose run --rm --no-deps \
  --entrypoint /bin/promtool prometheus check config /etc/prometheus/prometheus.yml
```
