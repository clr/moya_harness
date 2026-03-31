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
        split(line, parts, "=")
        key = parts[1]
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
  key="$(printf '%s' "$key" | sed -E 's/^"(.*)"$/\1/')"
  echo "$key"
}

toml_unquote() {
  local v="$1"
  v="$(printf '%s' "$v" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
  v="$(printf '%s' "$v" | sed -E 's/^"(.*)"$/\1/')"
  echo "$v"
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
  echo "[harness][debug] loading harness config: ${HARNESS_CONFIG_FILE}"
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
    cfg_key="${cfg_key#\"}"
    cfg_key="${cfg_key%\"}"
    SQUEEZE_OVERRIDES["$cfg_key"]="$cfg_value"
  done < <(toml_section_pairs "squeeze" "$HARNESS_CONFIG_FILE")

  # Defensive explicit reads for critical squeeze keys (avoids any parser edge cases
  # in generic section-pair extraction on zsh/macOS).
  for explicit_key in \
    ramp_mode total_target_rps initial_active_workers worker_step \
    worker_step_interval_seconds max_active_workers connections_per_worker \
    stop_latency_percentile latency_breach_consecutive_windows duration_seconds \
    warmup_seconds worker_inflight_limit base_url requests_per_second \
    start_requests_per_second rps_step
  do
    explicit_val="$(toml_get "squeeze" "$explicit_key" "$HARNESS_CONFIG_FILE")"
    if [[ -n "$explicit_val" ]]; then
      case "$explicit_key" in
        ramp_mode|base_url)
          SQUEEZE_OVERRIDES["$explicit_key"]="\"$explicit_val\""
          ;;
        *)
          SQUEEZE_OVERRIDES["$explicit_key"]="$explicit_val"
          ;;
      esac
    fi
  done

  echo "[harness][debug] loaded squeeze override keys: ${(k)SQUEEZE_OVERRIDES}"

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

# If concurrency ramp mode is enabled, ensure harness launches enough worker containers
# for every worker that may be activated during warmup/measured phases.
template_ramp_mode="$(toml_get "" "ramp_mode" "$SQUEEZER_REPO/$CONFIG_TEMPLATE_PATH")"
explicit_ramp_mode=""
explicit_max_active=""
explicit_initial_active=""
explicit_worker_step=""
explicit_worker_step_interval=""
if [[ -f "$HARNESS_CONFIG_FILE" ]]; then
  explicit_ramp_mode="$(toml_get "squeeze" "ramp_mode" "$HARNESS_CONFIG_FILE")"
  explicit_max_active="$(toml_get "squeeze" "max_active_workers" "$HARNESS_CONFIG_FILE")"
  explicit_initial_active="$(toml_get "squeeze" "initial_active_workers" "$HARNESS_CONFIG_FILE")"
  explicit_worker_step="$(toml_get "squeeze" "worker_step" "$HARNESS_CONFIG_FILE")"
  explicit_worker_step_interval="$(toml_get "squeeze" "worker_step_interval_seconds" "$HARNESS_CONFIG_FILE")"
fi
RAMP_MODE_VALUE="$(toml_unquote "${explicit_ramp_mode:-${SQUEEZE_OVERRIDES[ramp_mode]:-${template_ramp_mode:-}}}")"
echo "[harness][debug] resolved ramp_mode='${RAMP_MODE_VALUE:-<empty>}' (config override='${SQUEEZE_OVERRIDES[ramp_mode]:-<none>}', template='${template_ramp_mode:-<none>}')"
echo "[harness][debug] explicit max_active_workers='${explicit_max_active:-<none>}' override max_active_workers='${SQUEEZE_OVERRIDES[max_active_workers]:-<none>}'"
INITIAL_ACTIVE_WORKERS_VALUE=""
MAX_ACTIVE_WORKERS_VALUE=""
WORKER_STEP_VALUE=""
WORKER_STEP_INTERVAL_VALUE=""
POOL_WORKER_COUNT=""
if [[ "$RAMP_MODE_VALUE" == "concurrency" ]]; then
  required_workers="$WORKER_COUNT"

  template_max_active="$(toml_get "" "max_active_workers" "$SQUEEZER_REPO/$CONFIG_TEMPLATE_PATH")"
  max_active_raw="$(toml_unquote "${explicit_max_active:-${SQUEEZE_OVERRIDES[max_active_workers]:-${template_max_active:-}}}")"
  MAX_ACTIVE_WORKERS_VALUE="$max_active_raw"

  template_initial_active="$(toml_get "" "initial_active_workers" "$SQUEEZER_REPO/$CONFIG_TEMPLATE_PATH")"
  initial_active_raw="$(toml_unquote "${explicit_initial_active:-${SQUEEZE_OVERRIDES[initial_active_workers]:-${template_initial_active:-}}}")"
  INITIAL_ACTIVE_WORKERS_VALUE="$initial_active_raw"

  template_worker_step="$(toml_get "" "worker_step" "$SQUEEZER_REPO/$CONFIG_TEMPLATE_PATH")"
  worker_step_raw="$(toml_unquote "${explicit_worker_step:-${SQUEEZE_OVERRIDES[worker_step]:-${template_worker_step:-1}}}")"
  WORKER_STEP_VALUE="$worker_step_raw"

  template_worker_step_interval="$(toml_get "" "worker_step_interval_seconds" "$SQUEEZER_REPO/$CONFIG_TEMPLATE_PATH")"
  worker_step_interval_raw="$(toml_unquote "${explicit_worker_step_interval:-${SQUEEZE_OVERRIDES[worker_step_interval_seconds]:-${template_worker_step_interval:-5}}}")"
  WORKER_STEP_INTERVAL_VALUE="$worker_step_interval_raw"

  if [[ "$initial_active_raw" =~ ^[0-9]+$ ]] && (( initial_active_raw > required_workers )); then
    required_workers="$initial_active_raw"
  fi

  if (( required_workers != WORKER_COUNT )); then
    echo "[harness] increasing worker container count from ${WORKER_COUNT} to ${required_workers} to satisfy concurrency ramp settings"
  fi

  WORKER_COUNT="$required_workers"

  POOL_WORKER_COUNT="$WORKER_COUNT"
  if [[ "$max_active_raw" =~ ^[0-9]+$ ]] && (( max_active_raw > POOL_WORKER_COUNT )); then
    POOL_WORKER_COUNT="$max_active_raw"
  fi

  if [[ "$max_active_raw" =~ ^[0-9]+$ ]] && (( WORKER_COUNT > max_active_raw )); then
    echo "[harness] capping worker container count from ${WORKER_COUNT} to ${max_active_raw} due to max_active_workers"
    WORKER_COUNT="$max_active_raw"
  fi

  template_connections="$(toml_get "" "connections" "$SQUEEZER_REPO/$CONFIG_TEMPLATE_PATH")"
  effective_connections="$template_connections"

  override_connections="$(toml_unquote "${SQUEEZE_OVERRIDES[connections]:-}")"
  if [[ "$override_connections" =~ ^[0-9]+$ ]]; then
    effective_connections="$override_connections"
  fi

  if [[ "$max_active_raw" =~ ^[0-9]+$ ]] && [[ "$effective_connections" =~ ^[0-9]+$ ]] && (( max_active_raw > effective_connections )); then
    echo "[harness] increasing squeeze.connections from ${effective_connections} to ${max_active_raw} to satisfy concurrency ramp"
    SQUEEZE_OVERRIDES[connections]="$max_active_raw"
  fi
fi

echo "[harness] effective worker container count=${WORKER_COUNT} (ramp_mode=${RAMP_MODE_VALUE:-rps})"
if [[ "$RAMP_MODE_VALUE" == "concurrency" ]]; then
  echo "[harness] concurrency pool worker count=${POOL_WORKER_COUNT:-$WORKER_COUNT} initial_active_workers=${INITIAL_ACTIVE_WORKERS_VALUE:-$WORKER_COUNT} max_active_workers=${MAX_ACTIVE_WORKERS_VALUE:-$WORKER_COUNT}"
fi

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
typeset -a CANDIDATE_WORKER_NODES
typeset -a ACTIVE_WORKER_NAMES
typeset -a ACTIVE_WORKER_NODES
candidate_count="$WORKER_COUNT"
if [[ "$RAMP_MODE_VALUE" == "concurrency" ]] && [[ -n "$POOL_WORKER_COUNT" ]]; then
  candidate_count="$POOL_WORKER_COUNT"
fi

initial_launch_count="$WORKER_COUNT"
if [[ "$RAMP_MODE_VALUE" == "concurrency" ]] && [[ "$INITIAL_ACTIVE_WORKERS_VALUE" =~ ^[0-9]+$ ]] && (( INITIAL_ACTIVE_WORKERS_VALUE > 0 )); then
  initial_launch_count="$INITIAL_ACTIVE_WORKERS_VALUE"
fi
if (( initial_launch_count > candidate_count )); then
  initial_launch_count="$candidate_count"
fi

for ((i = 1; i <= candidate_count; i++)); do
  worker="worker${i}"
  CANDIDATE_WORKER_NODES+=(":\"${worker}@${worker}\"")
  WORKER_NAMES+=("$worker")
  WORKER_NODES+=(":\"${worker}@${worker}\"")
  if (( i <= initial_launch_count )); then
    ACTIVE_WORKER_NAMES+=("$worker")
    ACTIVE_WORKER_NODES+=(":\"${worker}@${worker}\"")
  fi
done

WORKER_NODE_LIST="$(printf '%s, ' "${ACTIVE_WORKER_NODES[@]}")"
WORKER_NODE_LIST="${WORKER_NODE_LIST%, }"
CANDIDATE_WORKER_NODE_LIST="$(printf '%s, ' "${CANDIDATE_WORKER_NODES[@]}")"
CANDIDATE_WORKER_NODE_LIST="${CANDIDATE_WORKER_NODE_LIST%, }"

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
    sh -lc "while true; do ERL_LIBS=/app/_build/dev/lib elixir --sname ${WORKER} --cookie ${COOKIE} -e 'Application.ensure_all_started(:moya_squeezer); Process.sleep(:infinity)'; echo '[worker restart] node exited, restarting'; sleep 1; done" >/dev/null
done

echo "[harness] waiting for worker nodes to become reachable"
typeset -a WORKER_NODE_ATOM_LIST
for WORKER in "${WORKER_NAMES[@]}"; do
  WORKER_NODE_ATOM_LIST+=(":\"${WORKER}@${WORKER}\"")
done
WORKER_NODE_ATOMS="$(printf '%s, ' "${WORKER_NODE_ATOM_LIST[@]}")"
WORKER_NODE_ATOMS="${WORKER_NODE_ATOMS%, }"

worker_ready=0
for attempt in {1..30}; do
  if docker run --rm \
    --network "${NETWORK_NAME}" \
    "${SQUEEZER_IMAGE}" \
    sh -lc "ERL_LIBS=/app/_build/dev/lib elixir --sname readiness --cookie ${COOKIE} -e 'nodes=[${WORKER_NODE_ATOMS}]; ok? = Enum.all?(nodes, fn n -> Node.connect(n) and Node.ping(n) == :pong end); if ok?, do: System.halt(0), else: System.halt(1)'" >/dev/null 2>&1; then
    worker_ready=1
    break
  fi
  sleep 2
done

if (( worker_ready == 0 )); then
  echo "[harness] error: worker nodes did not become reachable in time"
  echo "[harness] check with: docker ps --format '{{.Names}}' | grep '^worker'"
  exit 1
fi

echo "[harness] starting manager"
docker run -d \
  --name "${MANAGER_NAME}" \
  --hostname "${MANAGER_NAME}" \
  --network "${NETWORK_NAME}" \
  -v "${SQUEEZER_REPO}/config:/app/config:ro" \
  -v "${SQUEEZER_REPO}/logs:/app/logs" \
  "${SQUEEZER_IMAGE}" \
  sh -lc "ERL_LIBS=/app/_build/dev/lib elixir --sname ${MANAGER_NAME} --cookie ${COOKIE} -e 'Application.ensure_all_started(:moya_squeezer); case MoyaSqueezer.run(\"${CONFIG_EFFECTIVE_PATH}\", worker_nodes: [${WORKER_NODE_LIST}], candidate_worker_nodes: [${CANDIDATE_WORKER_NODE_LIST}]) do :ok -> :ok; {:error, reason} -> IO.puts(reason); System.halt(1) end'"

echo "[harness] started with db_nodes=${DB_NODE_COUNT} workers=${WORKER_COUNT}"
echo "[harness] effective squeeze config: ${CONFIG_EFFECTIVE_FULL}"
echo "[harness] tail manager logs with: docker logs -f ${MANAGER_NAME}"
echo "[harness] stop with: ${HARNESS_ROOT}/scripts/stop_cluster.sh"

if [[ "${FOLLOW_MANAGER_REPORT}" == "1" ]]; then
  echo "[harness] streaming manager output until manager exits..."
  docker logs -f "${MANAGER_NAME}" 2>&1
fi
