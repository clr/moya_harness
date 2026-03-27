# distributed-app Helm chart

## Render templates locally

```sh
helm template distributed-app ./deploy/helm/distributed-app
```

## Install or upgrade

```sh
helm upgrade --install distributed-app ./deploy/helm/distributed-app \
  --namespace default \
  --create-namespace \
  -f ./deploy/helm/distributed-app/values.yaml \
  -f ./deploy/helm/distributed-app/values-dev.yaml
```

## Environment overrides

The provided environment files currently only set `global.environment` to avoid
Helm list-merge pitfalls. Keep shared workload definitions in `values.yaml`, and
override workload fields with explicit `--set` flags in automation, for example:

```sh
helm upgrade --install distributed-app ./deploy/helm/distributed-app \
  -f ./deploy/helm/distributed-app/values.yaml \
  -f ./deploy/helm/distributed-app/values-prod.yaml \
  --set workloads[0].image.tag=2026.03.27 \
  --set workloads[1].image.tag=2026.03.27
```
