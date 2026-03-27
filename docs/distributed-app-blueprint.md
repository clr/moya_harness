# Distributed App Starter Blueprint

This blueprint gives you a practical baseline for deploying multiple containers
as one distributed application with sane defaults for reliability and security.

## 1) Baseline architecture

- **Edge/API service**: receives client traffic.
- **Worker service**: async/background processing.
- **PostgreSQL**: transactional state (managed in production).
- **Redis**: cache and queue backend.
- **Kubernetes + Helm**: orchestration and packaging.
- **GitHub Actions**: CI/CD and promotion flow.

## 2) Container standards

Apply these to every service image:

- Use multi-stage builds and pinned base image tags.
- Run as non-root where possible.
- Add `HEALTHCHECK` or Kubernetes readiness/liveness probes.
- Keep images immutable (`sha` or semver tags), avoid moving `latest`.
- Externalize config to env vars; never bake secrets into images.

## 3) Environments

Use at least:

- `dev`: fast feedback, lower safeguards.
- `staging`: production-like integration validation.
- `prod`: controlled rollout + rollback policies.

Store environment-specific values in separate Helm values files:

- `values-dev.yaml`
- `values-staging.yaml`
- `values-prod.yaml`

## 4) CI/CD flow

Recommended order:

1. Lint and unit tests.
2. Build service images.
3. Security scans (dependencies + image).
4. Push signed images to registry.
5. Deploy to staging and run smoke tests.
6. Promote to production with rolling/canary strategy.

## 5) Reliability defaults

- Set CPU/memory requests + limits for every workload.
- Configure horizontal pod autoscaling on CPU and/or memory.
- Add request timeouts, retries, and backoff in clients.
- Keep services stateless; use managed data stores.
- Make handlers idempotent for safe retries.

## 6) Observability defaults

- Structured JSON logs with request/correlation IDs.
- Metrics (latency, error rate, throughput, saturation).
- Distributed traces for cross-service requests.
- Alerts tied to user-facing SLOs.

## 7) Security defaults

- Secret manager integration (never commit secrets).
- Image scanning in CI.
- Least-privilege Kubernetes service accounts.
- Network policies where cluster supports them.
- Dependency update automation.

## 8) Rollout checklist

- [ ] All services have readiness/liveness probes.
- [ ] Resource requests/limits are set.
- [ ] Images are tagged immutably.
- [ ] Helm values are environment-specific.
- [ ] Staging smoke tests pass before production promotion.
- [ ] Rollback command is documented and tested.

## 9) Next customization

Replace placeholders in:

- `docker-compose.yml`
- `deploy/helm/distributed-app/values.yaml`
- `.github/workflows/ci-cd.yml`

Then add concrete manifests for each service ingress, persistence, and queue
consumers according to your actual topology.
