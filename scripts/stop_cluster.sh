#!/bin/zsh

set -euo pipefail

NETWORK_NAME="${NETWORK_NAME:-moya_net}"

echo "[harness] stopping containers"
typeset -a TARGET_CONTAINERS
while IFS= read -r cname; do
  [[ -z "$cname" ]] && continue
  TARGET_CONTAINERS+=("$cname")
done < <(docker ps -a --format '{{.Names}}' | grep -E '^(manager|worker[0-9]+|moya_db_balancer|moya_db([0-9]+)?)$' || true)

if (( ${#TARGET_CONTAINERS[@]} > 0 )); then
  docker rm -f "${TARGET_CONTAINERS[@]}" >/dev/null 2>&1 || true
fi

echo "[harness] removing network ${NETWORK_NAME}"
docker network rm "${NETWORK_NAME}" >/dev/null 2>&1 || true

echo "[harness] stopped"
