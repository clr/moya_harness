#!/bin/zsh

set -euo pipefail

HARNESS_ROOT="${HARNESS_ROOT:-/Users/clr/moya_harness}"

"${HARNESS_ROOT}/scripts/run_cluster.sh" --config "${HARNESS_ROOT}/harness.rps.config.toml" "$@"
