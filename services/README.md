# Service Dockerfiles

The CI workflow expects service Dockerfiles at:

- `services/api/Dockerfile`
- `services/worker/Dockerfile`

If your layout differs, update `.github/workflows/ci-cd.yml` in the
`build-and-push` job (`file:` path under the Docker build step).
