# Repository Guidelines

These instructions apply to the entire `infra` repository.

## Permanent repository memory

- Treat this file as the repository's permanent memory. When work reveals
  stable, generally useful knowledge that future agents should retain, add it
  here as part of the same change.
- Record only verified, durable guidance. Do not add temporary task state,
  speculative conclusions, credentials, secrets, or personal data.

## Scope

- This repository defines the local Envoy entrypoint for the application stack.
  Keep it small and declarative; application behavior belongs in the service
  repositories.
- `compose.yaml` starts Envoy on the external `synodus-network`.
  `envoy.local.yaml` routes `/api/` to `api:8080`, `/ws/docs` to
  `collaboration-server:8082`, other `/ws` traffic to `socket-server:8081`,
  and all other traffic to `web:3000`.
- Local Compose must use `envoy.local.yaml` (HTTP without certificates). Production
  uses `envoy.yaml` (HTTPS and certificates); keep their application routes aligned.
- Route order is significant: keep the WebSocket and API routes before the `/`
  catch-all. Preserve WebSocket upgrade configuration when editing listeners.
- Coordinate upstream names, ports, path prefixes, and public origins with
  `core-api`, `socket-server`, and `web-frontend`.
- Both local and production Compose files extend the shared monitoring services
  in `docker-compose.yaml`; monitoring starts with normal deployments.
  `deploy.sh` initializes the Grafana password in `.env` and ensures monitoring
  also runs after a deployment targeting one service.

## Change guidelines

- Pin container images to an explicit immutable version or digest. Do not
  introduce floating tags such as `latest`.
- Do not commit credentials or embed secrets in Compose or Envoy configuration.
  Use environment variables or secret mechanisms when configuration becomes
  sensitive.
- Keep the Envoy admin interface limited to local development. Do not expose a
  production admin endpoint without authentication and network controls.
- Prefer the smallest configuration change that preserves current local
  startup behavior and the external network contract.

## Validation

- Validate Compose changes with `docker compose config`.
- Validate Envoy changes with the pinned image, for example:
  `docker compose run --rm envoy --mode validate -c /etc/envoy/envoy.yaml`.
- For routing changes, start the dependent services and verify the frontend,
  an `/api/` request, a `/ws` upgrade, and the Envoy admin readiness endpoint.
- If Docker or dependent services are unavailable, perform static validation
  where possible and state which runtime checks were not run.
