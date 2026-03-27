# moya_harness

Starter blueprint for packaging and deploying a distributed containerized
application.

## Included blueprint

- `docs/distributed-app-blueprint.md`: architecture and rollout checklist
- `docker-compose.yml`: local development stack
- `deploy/helm/distributed-app/`: Kubernetes Helm chart starter
- `.github/workflows/ci-cd.yml`: CI/CD skeleton with build, scan, and deploy
- `services/README.md`: expected Dockerfile layout for CI

## Quick start

1. Replace placeholder image names (`ghcr.io/your-org/...`) with real images.
2. Adapt `docker-compose.yml` services and env vars to your app.
3. Update Helm `values.yaml` for each environment.
4. Connect CI secrets and deploy targets in GitHub Actions.

## Helm example

```sh
helm template distributed-app ./deploy/helm/distributed-app
```
