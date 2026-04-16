#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${(%):-%N}")" && pwd)"
HARNESS_ROOT="${HARNESS_ROOT:-$(cd -- "${SCRIPT_DIR}/.." && pwd)}"

"${HARNESS_ROOT}/scripts/run_cluster.sh" --config "${HARNESS_ROOT}/harness.payload.config.toml" "$@"
