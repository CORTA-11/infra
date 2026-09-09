# Infra

Envoy exposes the local Docker stack at `http://localhost:10000`.

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

The sibling repositories are expected at `../core-api`, `../socket-server`, and
`../web-frontend`. Create the shared network once, initialize core-api as
described in its README, then start the named services:

```bash
docker network inspect synodus-network >/dev/null 2>&1 || docker network create synodus-network

cd ../core-api
cp -n .env.example .env
cp -R dev_secrets .local_secrets
docker compose up -d postgres redis minio
make bootstrap-db
make seed
make assign-org-owner ORG_ID=30ee7153-9b48-4560-8cbf-972587a60fda USER_ID=0d5a4f4e-8d3b-4f17-9a79-4c38e29a6d11
make assign-org-owner ORG_ID=f1810095-f8a0-4e27-83df-d88b3256604d USER_ID=0d5a4f4e-8d3b-4f17-9a79-4c38e29a6d11
make assign-org-owner ORG_ID=afb118ba-2ade-4422-9f20-04754fd1d4a7 USER_ID=0d5a4f4e-8d3b-4f17-9a79-4c38e29a6d11
make verify-org-owners
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

## Configuration validation

```bash
docker compose config
docker compose run --rm envoy --mode validate -c /etc/envoy/envoy.yaml
```
