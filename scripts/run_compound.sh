#!/bin/zsh

set -euo pipefail

HARNESS_ROOT="${HARNESS_ROOT:-/Users/clr/moya_harness}"
SQUEEZER_REPO="${SQUEEZER_REPO:-/Users/clr/moya_squeezer}"
NETWORK_NAME="${NETWORK_NAME:-moya_net}"

RPS_CONFIG="${HARNESS_ROOT}/harness.rps.config.toml"
CONCURRENCY_CONFIG="${HARNESS_ROOT}/harness.concurrency.config.toml"
PAYLOAD_CONFIG="${HARNESS_ROOT}/harness.payload.config.toml"
COMPOUND_LOG_DIR="${COMPOUND_LOG_DIR:-${HARNESS_ROOT}/logs/compound}"

mkdir -p "$COMPOUND_LOG_DIR"

extract_top_rps() {
  local log_file="$1"
  awk '{
    if (index($0, "rps=") > 0) {
      split($0, a, "rps=")
      split(a[2], b, " ")
      val = b[1] + 0
      if (val > max) max = val
    }
  } END { print max + 0 }' "$log_file"
}

extract_top_concurrency() {
  local log_file="$1"
  local from_ramp from_table
  from_ramp="$(awk '{
    if (index($0, "active_workers=") > 0) {
      split($0, a, "active_workers=")
      split(a[2], b, " ")
      val = b[1] + 0
      if (val > max) max = val
    }
  } END { print max + 0 }' "$log_file")"
  from_table="$(awk -F'\t' '/^\[manager\]\[workers\] worker[0-9]+@worker[0-9]+/ { if ($2 + 0 > max) max = $2 + 0 } END { if (max == "") max = 0; print max }' "$log_file")"
  if (( from_ramp > from_table )); then
    echo "$from_ramp"
  else
    echo "$from_table"
  fi
}

extract_top_payload() {
  local log_file="$1"
  awk '{
    if (index($0, "payload_size=") > 0) {
      split($0, a, "payload_size=")
      split(a[2], b, " ")
      val = b[1] + 0
      if (val > max) max = val
    }
  } END { print max + 0 }' "$log_file"
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

generate_effective_squeeze_config() {
  local harness_config="$1"
  local output_path="$2"

  local template_rel
  template_rel="$(toml_get "moya_squeezer" "config_template_path" "$harness_config")"
  [[ -z "$template_rel" ]] && template_rel="config/docker.toml"

  local template_full="${SQUEEZER_REPO}/${template_rel}"
  mkdir -p "$(dirname "$output_path")"
  cp "$template_full" "$output_path"

  while IFS=$'\t' read -r squeeze_key squeeze_value; do
    [[ -z "$squeeze_key" ]] && continue
    [[ -z "${squeeze_value//[[:space:]]/}" ]] && continue
    upsert_toml_key "$output_path" "$squeeze_key" "$squeeze_value"
  done < <(toml_section_pairs "squeeze" "$harness_config")

  upsert_toml_key "$output_path" "base_url" "\"http://moya_db_balancer:9000\""
  upsert_toml_key "$output_path" "feel_the_burn_seconds" "10"
  printf '\n' >> "$output_path"
}

start_manager_for_config() {
  local harness_config="$1"
  local effective_rel="$2"
  local log_file="$3"
  local effective_full="${SQUEEZER_REPO}/${effective_rel}"

  local manager_name cookie
  manager_name="$(toml_get "moya_squeezer" "manager_name" "$harness_config")"
  cookie="$(toml_get "moya_squeezer" "cookie" "$harness_config")"
  [[ -z "$manager_name" ]] && manager_name="manager"
  [[ -z "$cookie" ]] && cookie="squeeze_cookie"

  generate_effective_squeeze_config "$harness_config" "$effective_full"

  typeset -a worker_nodes
  while IFS= read -r worker; do
    [[ -z "$worker" ]] && continue
    worker_nodes+=(":\"${worker}@${worker}\"")
  done < <(docker ps --format '{{.Names}}' | grep -E '^worker[0-9]+$' | sort -V)

  if (( ${#worker_nodes[@]} == 0 )); then
    echo "[compound] no running worker containers found"
    exit 1
  fi

  worker_node_list="$(printf '%s, ' "${worker_nodes[@]}")"
  worker_node_list="${worker_node_list%, }"

  docker rm -f "$manager_name" >/dev/null 2>&1 || true

  echo "[compound] starting manager for $(basename "$harness_config")"
  docker run -d \
    --name "$manager_name" \
    --hostname "$manager_name" \
    --network "$NETWORK_NAME" \
    -p "4100:4001" \
    -v "${SQUEEZER_REPO}/config:/app/config:ro" \
    -v "${SQUEEZER_REPO}/logs:/app/logs" \
    "moya_squeezer:latest" \
    sh -lc "ERL_LIBS=/app/_build/dev/lib elixir --sname ${manager_name} --cookie ${cookie} -e 'Application.ensure_all_started(:moya_squeezer); case MoyaSqueezer.run(\"${effective_rel}\", worker_nodes: [${worker_node_list}]) do :ok -> :ok; {:error, reason} -> IO.puts(reason); System.halt(1) end'" >/dev/null

  docker logs -f "$manager_name" 2>&1 | tee "$log_file"
  docker wait "$manager_name" >/dev/null
}

echo "[compound] bringing up cluster + rps phase"
zsh "${HARNESS_ROOT}/scripts/run_cluster.sh" --config "$RPS_CONFIG" --feel-the-burn 10 --no-follow-report "$@"

echo "[compound] waiting for rps phase to finish"
rps_log="${COMPOUND_LOG_DIR}/rps.log"
concurrency_log="${COMPOUND_LOG_DIR}/concurrency.log"
payload_log="${COMPOUND_LOG_DIR}/payload.log"

docker logs -f manager 2>&1 | tee "$rps_log"
docker wait manager >/dev/null

start_manager_for_config "$CONCURRENCY_CONFIG" "config/generated/docker.compound.concurrency.effective.toml" "$concurrency_log"
start_manager_for_config "$PAYLOAD_CONFIG" "config/generated/docker.compound.payload.effective.toml" "$payload_log"

top_rps="$(extract_top_rps "$rps_log")"
top_concurrency="$(extract_top_concurrency "$concurrency_log")"
top_payload="$(extract_top_payload "$payload_log")"

echo "[compound] completed all phases: rps -> concurrency -> payload"
echo "[compound][summary] top_rps=${top_rps} top_concurrency=${top_concurrency} top_payload_bytes=${top_payload}"
