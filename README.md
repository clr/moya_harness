# moya_harness

Deployment/orchestration repo for the Moya stack.

Canonical repository:

- https://github.com/clr/moya_harness

Related repositories:

- https://github.com/clr/moya_squeezer
- https://github.com/clr/moya

This repo now owns the container orchestration logic for:

- `moya_squeezer` (manager + workers)
- `moya_db`

## What lives here

- `docker-compose.yml`: multi-container local stack for Moya
- `scripts/run_cluster.sh`: plain-docker cluster launcher
- `scripts/stop_cluster.sh`: plain-docker cluster teardown
- `docs/distributed-app-blueprint.md`: deployment architecture notes
- `deploy/helm/distributed-app/`: Helm chart starter
- `.github/workflows/ci-cd.yml`: CI/CD skeleton

## Sibling repos expected

By default, harness expects these adjacent directories:

- `../moya_squeezer`
- `../moya_db`

Override with env vars when needed:

- `SQUEEZER_REPO`
- `DB_REPO`

## Quick start (plain Docker)

```sh
chmod +x scripts/run_cluster.sh scripts/stop_cluster.sh
./scripts/run_cluster.sh
```

By default, `run_cluster.sh` reads `./harness.config.toml` for cluster shape and squeeze overrides.
It also streams manager output in the same terminal and stops streaming when the manager prints `[final]`.

Tail manager logs:

```sh
docker logs -f manager
```

Stop everything:

```sh
./scripts/stop_cluster.sh
```

Useful overrides:

- `SQUEEZER_IMAGE`, `DB_IMAGE`
- `BASE_IMAGE`
- `NETWORK_NAME`
- `COOKIE`
- `CONFIG_PATH` (template path inside squeezer repo; backward-compatible alias)
- `WORKER_COUNT`, `DB_NODE_COUNT`, `DB_BASE_PORT`
- `START_REQUESTS_PER_SECOND`, `REQUESTS_PER_SECOND`, `DURATION_SECONDS`, `WARMUP_SECONDS`

## Harness config file

`harness.config.toml` is the central override file for local cluster orchestration.

Example:

```toml
[cluster]
network_name = "moya_net"

[moya_db]
node_count = 1
base_port = 9000
image = "moya_db:latest"

[moya_squeezer]
manager_name = "manager"
worker_count = 3
cookie = "squeeze_cookie"
config_template_path = "config/docker.toml"
config_effective_path = "config/generated/docker.effective.toml"

[squeeze]
start_requests_per_second = 1500
requests_per_second = 500
rps_step = 50
duration_seconds = 30
warmup_seconds = 10

# Optional concurrency ramp mode with fixed total target RPS
# ramp_mode = "concurrency"
# total_target_rps = 1500
# initial_active_workers = 3
# worker_step = 1
# worker_step_interval_seconds = 5
# max_active_workers = 6
```

When the cluster starts, harness generates an effective squeeze config at
`config_effective_path` and runs the manager against that file.
Any key under `[squeeze]` is applied to the effective squeezer config, so you can
override any setting supported by `moya_squeezer/config/*.toml` (for example `rps_step`).

In `ramp_mode = "concurrency"`, the manager increases active workers over time while
holding `total_target_rps` constant, so per-worker/connection rate decreases each step.
When concurrency mode is enabled, harness will automatically launch enough worker
containers to satisfy `max_active_workers` (and at least `initial_active_workers`).

## Override precedence

From lowest to highest precedence:

1. Script defaults
2. `harness.config.toml`
3. Environment variables
4. CLI flags

## CLI examples

Run with 5 workers:

```sh
./scripts/run_cluster.sh --workers 5
```

Run with 3 db nodes and custom base port:

```sh
./scripts/run_cluster.sh --db-nodes 3
```

Override squeeze start RPS for one run:

```sh
./scripts/run_cluster.sh --start-rps 2200
```

See supported options:

```sh
./scripts/run_cluster.sh --help
```

Run detached (do not stream manager report in this terminal):

```sh
./scripts/run_cluster.sh --no-follow-report
```

## Docker Compose usage

```sh
docker compose up --build --abort-on-container-exit
```

Compose can also use these env vars:

- `SQUEEZER_REPO`, `DB_REPO`
- `SQUEEZER_IMAGE`, `DB_IMAGE`
- `BASE_IMAGE`

## Notes

- `moya_squeezer` should focus on app/test logic, not multi-service deployment.
- `moya_db` keeps its service-level deployment files (`deploy/systemd`, `deploy/launchd`), while stack orchestration remains here.
