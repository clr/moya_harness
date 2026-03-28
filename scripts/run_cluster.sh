#!/bin/zsh

set -euo pipefail

HARNESS_ROOT="${HARNESS_ROOT:-/Users/clr/moya_harness}"
SQUEEZER_REPO="${SQUEEZER_REPO:-/Users/clr/moya_squeezer}"
DB_REPO="${DB_REPO:-/Users/clr/moya_db}"
HARNESS_CONFIG_FILE="${HARNESS_CONFIG_FILE:-${HARNESS_ROOT}/harness.config.toml}"

NETWORK_NAME="${NETWORK_NAME:-moya_net}"
SQUEEZER_IMAGE="${SQUEEZER_IMAGE:-moya_squeezer:latest}"
DB_IMAGE="${DB_IMAGE:-moya_db:latest}"
CONFIG_TEMPLATE_PATH="${CONFIG_TEMPLATE_PATH:-config/docker.toml}"
CONFIG_EFFECTIVE_PATH="${CONFIG_EFFECTIVE_PATH:-config/generated/docker.effective.toml}"
COOKIE="${COOKIE:-squeeze_cookie}"
BASE_IMAGE="${BASE_IMAGE:-elixir:1.19.0}"
MANAGER_NAME="${MANAGER_NAME:-manager}"
WORKER_COUNT="${WORKER_COUNT:-3}"
DB_NODE_COUNT="${DB_NODE_COUNT:-1}"
DB_BASE_PORT="${DB_BASE_PORT:-9000}"

START_REQUESTS_PER_SECOND="${START_REQUESTS_PER_SECOND:-}"
REQUESTS_PER_SECOND="${REQUESTS_PER_SECOND:-}"
DURATION_SECONDS="${DURATION_SECONDS:-}"
WARMUP_SECONDS="${WARMUP_SECONDS:-}"
FOLLOW_MANAGER_REPORT="${FOLLOW_MANAGER_REPORT:-1}"
typeset -A SQUEEZE_OVERRIDES

# First pass for --config so file-based defaults can be loaded from a custom path.
typeset -a ORIGINAL_ARGS
ORIGINAL_ARGS=("$@")
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      HARNESS_CONFIG_FILE="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
set -- "${ORIGINAL_ARGS[@]}"

usage() {
  cat <<'USAGE'
Usage: run_cluster.sh [options]

Options:
  --config <path>        Path to harness config file (default: harness.config.toml)
  --workers <n>          Override moya_squeezer worker count
  --db-nodes <n>         Override moya_db node count
  --start-rps <n>        Override squeeze start_requests_per_second
  --rps <n>              Override squeeze requests_per_second
  --duration <n>         Override squeeze duration_seconds
  --warmup <n>           Override squeeze warmup_seconds
  --network <name>       Override docker network name
  --cookie <cookie>      Override Erlang cookie
  --config-template <p>  Squeezer template config path (in repo)
  --config-effective <p> Squeezer generated config path (in repo)
  --no-follow-report     Do not stream manager logs/report in this terminal
  -h, --help             Show this help
USAGE
}

toml_get() {
  local section="$1"
  local key="$2"
  local file="$3"

  awk -v target_section="$section" -v target_key="$key" '
    BEGIN { in_section = 0 }
    {
      line = $0
      sub(/#.*/, "", line)
      gsub(/^[ \t]+|[ \t]+$/, "", line)
      if (line == "") next

      if (line ~ /^\[[^\]]+\]$/) {
        sec = line
        gsub(/^\[|\]$/, "", sec)
        in_section = (sec == target_section)
        next
      }

      if (in_section && index(line, "=") > 0) {
        split(line, parts, "=")
        k = parts[1]
        gsub(/^[ \t]+|[ \t]+$/, "", k)
        if (k == target_key) {
          v = substr(line, index(line, "=") + 1)
          gsub(/^[ \t]+|[ \t]+$/, "", v)
          if (v ~ /^".*"$/) {
            v = substr(v, 2, length(v) - 2)
          }
          print v
          exit
        }
      }
    }
  ' "$file"
}

toml_section_pairs() {
  local section="$1"
  local file="$2"

  awk -v target_section="$section" '
    BEGIN { in_section = 0 }
    {
      line = $0
      sub(/#.*/, "", line)
      gsub(/^[ \t]+|[ \t]+$/, "", line)
      if (line == "") next

      if (line ~ /^\[[^\]]+\]$/) {
        sec = line
        gsub(/^\[|\]$/, "", sec)
        in_section = (sec == target_section)
        next
      }

      if (in_section && index(line, "=") > 0) {
        key = line
        sub(/=.*/, "", key)
        gsub(/^[ \t]+|[ \t]+$/, "", key)
        value = substr(line, index(line, "=") + 1)
        gsub(/^[ \t]+|[ \t]+$/, "", value)
        printf "%s\t%s\n", key, value
      }
    }
  ' "$file"
}

normalize_toml_key() {
  local key="$1"
  key="$(printf '%s' "$key" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
  if [[ "$key" == \"*\" ]]; then
    key="${key#\"}"
    key="${key%\"}"
  fi
  echo "$key"
}

upsert_toml_key() {
  local file="$1"
  local key="$2"
  local value="$3"
  local tmp="${file}.tmp"

  awk -v target_key="$key" -v target_value="$value" '
    BEGIN { updated = 0 }
    {
      line = $0
      no_comment = line
      sub(/#.*/, "", no_comment)
      gsub(/^[ \t]+|[ \t]+$/, "", no_comment)

      line_key = no_comment
      sub(/=.*/, "", line_key)
      gsub(/^[ \t]+|[ \t]+$/, "", line_key)
      if (line_key ~ /^".*"$/) {
        line_key = substr(line_key, 2, length(line_key) - 2)
      }

      if (!updated && line_key == target_key) {
        print target_key " = " target_value
        updated = 1
      } else {
        print line
      }
    }
    END {
      if (!updated) print target_key " = " target_value
    }
  ' "$file" > "$tmp"

  mv "$tmp" "$file"
}

if [[ -f "$HARNESS_CONFIG_FILE" ]]; then
  cfg_network_name="$(toml_get "cluster" "network_name" "$HARNESS_CONFIG_FILE")"
  cfg_db_node_count="$(toml_get "moya_db" "node_count" "$HARNESS_CONFIG_FILE")"
  cfg_db_base_port="$(toml_get "moya_db" "base_port" "$HARNESS_CONFIG_FILE")"
  cfg_db_image="$(toml_get "moya_db" "image" "$HARNESS_CONFIG_FILE")"
  cfg_manager_name="$(toml_get "moya_squeezer" "manager_name" "$HARNESS_CONFIG_FILE")"
  cfg_worker_count="$(toml_get "moya_squeezer" "worker_count" "$HARNESS_CONFIG_FILE")"
  cfg_cookie="$(toml_get "moya_squeezer" "cookie" "$HARNESS_CONFIG_FILE")"
  cfg_config_template="$(toml_get "moya_squeezer" "config_template_path" "$HARNESS_CONFIG_FILE")"
  cfg_config_effective="$(toml_get "moya_squeezer" "config_effective_path" "$HARNESS_CONFIG_FILE")"
  while IFS=$'\t' read -r cfg_key cfg_value; do
    [[ -z "$cfg_key" ]] && continue
    cfg_key="$(normalize_toml_key "$cfg_key")"
    SQUEEZE_OVERRIDES["$cfg_key"]="$cfg_value"
  done < <(toml_section_pairs "squeeze" "$HARNESS_CONFIG_FILE")

  [[ -n "$cfg_network_name" ]] && NETWORK_NAME="$cfg_network_name"
  [[ -n "$cfg_db_node_count" ]] && DB_NODE_COUNT="$cfg_db_node_count"
  [[ -n "$cfg_db_base_port" ]] && DB_BASE_PORT="$cfg_db_base_port"
  [[ -n "$cfg_db_image" ]] && DB_IMAGE="$cfg_db_image"
  [[ -n "$cfg_manager_name" ]] && MANAGER_NAME="$cfg_manager_name"
  [[ -n "$cfg_worker_count" ]] && WORKER_COUNT="$cfg_worker_count"
  [[ -n "$cfg_cookie" ]] && COOKIE="$cfg_cookie"
  [[ -n "$cfg_config_template" ]] && CONFIG_TEMPLATE_PATH="$cfg_config_template"
  [[ -n "$cfg_config_effective" ]] && CONFIG_EFFECTIVE_PATH="$cfg_config_effective"
fi

# Environment variable precedence over file
[[ -n "${CONFIG_PATH:-}" ]] && CONFIG_TEMPLATE_PATH="${CONFIG_PATH}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      shift 2
      ;;
    --workers)
      WORKER_COUNT="$2"
      shift 2
      ;;
    --db-nodes)
      DB_NODE_COUNT="$2"
      shift 2
      ;;
    --start-rps)
      START_REQUESTS_PER_SECOND="$2"
      shift 2
      ;;
    --rps)
      REQUESTS_PER_SECOND="$2"
      shift 2
      ;;
    --duration)
      DURATION_SECONDS="$2"
      shift 2
      ;;
    --warmup)
      WARMUP_SECONDS="$2"
      shift 2
      ;;
    --network)
      NETWORK_NAME="$2"
      shift 2
      ;;
    --cookie)
      COOKIE="$2"
      shift 2
      ;;
    --config-template)
      CONFIG_TEMPLATE_PATH="$2"
      shift 2
      ;;
    --config-effective)
      CONFIG_EFFECTIVE_PATH="$2"
      shift 2
      ;;
    --no-follow-report)
      FOLLOW_MANAGER_REPORT="0"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[harness] unknown argument: $1"
      usage
      exit 1
      ;;
  esac
done

if (( WORKER_COUNT < 1 )); then
  echo "[harness] WORKER_COUNT must be >= 1"
  exit 1
fi

if (( DB_NODE_COUNT < 1 )); then
  echo "[harness] DB_NODE_COUNT must be >= 1"
  exit 1
fi

# Known squeeze knobs from env/CLI override generic [squeeze] entries.
[[ -n "$START_REQUESTS_PER_SECOND" ]] && SQUEEZE_OVERRIDES[start_requests_per_second]="$START_REQUESTS_PER_SECOND"
[[ -n "$REQUESTS_PER_SECOND" ]] && SQUEEZE_OVERRIDES[requests_per_second]="$REQUESTS_PER_SECOND"
[[ -n "$DURATION_SECONDS" ]] && SQUEEZE_OVERRIDES[duration_seconds]="$DURATION_SECONDS"
[[ -n "$WARMUP_SECONDS" ]] && SQUEEZE_OVERRIDES[warmup_seconds]="$WARMUP_SECONDS"

CONFIG_TEMPLATE_FULL="${SQUEEZER_REPO}/${CONFIG_TEMPLATE_PATH}"
CONFIG_EFFECTIVE_FULL="${SQUEEZER_REPO}/${CONFIG_EFFECTIVE_PATH}"
mkdir -p "$(dirname "$CONFIG_EFFECTIVE_FULL")"
cp "$CONFIG_TEMPLATE_FULL" "$CONFIG_EFFECTIVE_FULL"

if (( DB_NODE_COUNT == 1 )); then
  DB_PRIMARY_HOST="moya_db"
else
  DB_PRIMARY_HOST="moya_db1"
fi
DB_PRIMARY_URL="http://${DB_PRIMARY_HOST}:${DB_BASE_PORT}"

# Ensure the generated config points at the launched DB topology unless caller set base_url explicitly.
if [[ -z "${SQUEEZE_OVERRIDES[base_url]:-}" ]]; then
  SQUEEZE_OVERRIDES[base_url]="\"${DB_PRIMARY_URL}\""
fi

for squeeze_key squeeze_value in ${(kv)SQUEEZE_OVERRIDES}; do
  squeeze_key="$(normalize_toml_key "$squeeze_key")"
  [[ -z "$squeeze_key" ]] && continue
  [[ -z "${squeeze_value//[[:space:]]/}" ]] && continue
  upsert_toml_key "$CONFIG_EFFECTIVE_FULL" "$squeeze_key" "$squeeze_value"
done

typeset -a WORKER_NAMES
typeset -a WORKER_NODES
for ((i = 1; i <= WORKER_COUNT; i++)); do
  worker="worker${i}"
  WORKER_NAMES+=("$worker")
  WORKER_NODES+=(":\"${worker}@${worker}\"")
done

WORKER_NODE_LIST="$(printf '%s, ' "${WORKER_NODES[@]}")"
WORKER_NODE_LIST="${WORKER_NODE_LIST%, }"

echo "[harness] building db image: ${DB_IMAGE}"
docker build -t "${DB_IMAGE}" "${DB_REPO}"

echo "[harness] building squeezer image: ${SQUEEZER_IMAGE}"
docker build --build-arg BASE_IMAGE="${BASE_IMAGE}" -t "${SQUEEZER_IMAGE}" "${SQUEEZER_REPO}"

echo "[harness] ensuring network: ${NETWORK_NAME}"
docker network create "${NETWORK_NAME}" >/dev/null 2>&1 || true

echo "[harness] clearing old containers (if any)"
typeset -a EXISTING_CONTAINERS
while IFS= read -r cname; do
  [[ -z "$cname" ]] && continue
  EXISTING_CONTAINERS+=("$cname")
done < <(docker ps -a --format '{{.Names}}' | grep -E '^(manager|worker[0-9]+|moya_db([0-9]+)?)$' || true)

while IFS= read -r cname; do
  [[ -z "$cname" ]] && continue
  if [[ "$cname" == "$MANAGER_NAME" ]]; then
    EXISTING_CONTAINERS+=("$cname")
  fi
done < <(docker ps -a --format '{{.Names}}')

if (( ${#EXISTING_CONTAINERS[@]} > 0 )); then
  docker rm -f "${EXISTING_CONTAINERS[@]}" >/dev/null 2>&1 || true
fi

echo "[harness] starting db"
for ((i = 1; i <= DB_NODE_COUNT; i++)); do
  if (( DB_NODE_COUNT == 1 )); then
    db_name="moya_db"
  else
    db_name="moya_db${i}"
  fi

  host_port=$((DB_BASE_PORT + i - 1))
  docker run -d \
    --name "${db_name}" \
    --hostname "${db_name}" \
    --network "${NETWORK_NAME}" \
    -p "${host_port}:9000" \
    "${DB_IMAGE}" >/dev/null
done

echo "[harness] starting workers"
for WORKER in "${WORKER_NAMES[@]}"; do
  docker run -d \
    --name "${WORKER}" \
    --hostname "${WORKER}" \
    --network "${NETWORK_NAME}" \
    "${SQUEEZER_IMAGE}" \
    sh -lc "while true; do ERL_LIBS=/app/_build/dev/lib elixir --sname ${WORKER} --cookie ${COOKIE} -e 'Application.ensure_all_started(:moya_squeezer); case MoyaSqueezer.run_worker(:\"${MANAGER_NAME}@${MANAGER_NAME}\") do :ok -> :ok; {:error, reason} -> IO.puts(reason); System.halt(1) end'; echo '[worker retry] waiting for manager'; sleep 2; done" >/dev/null
done

echo "[harness] starting manager"
docker run -d \
  --name "${MANAGER_NAME}" \
  --hostname "${MANAGER_NAME}" \
  --network "${NETWORK_NAME}" \
  -v "${SQUEEZER_REPO}/config:/app/config:ro" \
  -v "${SQUEEZER_REPO}/logs:/app/logs" \
  "${SQUEEZER_IMAGE}" \
  sh -lc "while true; do ERL_LIBS=/app/_build/dev/lib elixir --sname ${MANAGER_NAME} --cookie ${COOKIE} -e 'Application.ensure_all_started(:moya_squeezer); case MoyaSqueezer.run(\"${CONFIG_EFFECTIVE_PATH}\", worker_nodes: [${WORKER_NODE_LIST}]) do :ok -> :ok; {:error, reason} -> IO.puts(reason); System.halt(1) end' && break; echo '[manager retry] waiting for workers'; sleep 2; done"

echo "[harness] started with db_nodes=${DB_NODE_COUNT} workers=${WORKER_COUNT}"
echo "[harness] effective squeeze config: ${CONFIG_EFFECTIVE_FULL}"
echo "[harness] tail manager logs with: docker logs -f ${MANAGER_NAME}"
echo "[harness] stop with: ${HARNESS_ROOT}/scripts/stop_cluster.sh"

if [[ "${FOLLOW_MANAGER_REPORT}" == "1" ]]; then
  echo "[harness] streaming manager output until final report..."
  docker logs -f "${MANAGER_NAME}" 2>&1 | awk '
    {
      print
      fflush()
    }
    /\[final\]/ {
      exit 0
    }
  '
fi
