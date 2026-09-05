# Infra

Envoy exposes the local Docker stack at `http://localhost:10000`.

Routes:

- `/api/` forwards to `core-api` on port 8080.
- `/ws` forwards WebSocket upgrades to `socket-server` on port 8081.
- everything else forwards to `web-frontend` on port 3000.

Start it after the backend and frontend services have joined the shared
`synodus-network`:

```bash
docker compose up -d
```
