#!/usr/bin/env bash
#
# Checks an OpenSearch Lite image the way it will run on OpenShift under the restricted
# policy: a random UID in group 0, no capabilities, no privilege escalation, a read-only
# root filesystem with only data/, logs/ and /tmp writable.
#
#   lite/smoke_test.sh [image]             one node: the calls InfraDashboard, Index
#                                          Management and SQL rely on
#   lite/smoke_test.sh --cluster [image]   three nodes with the settings the Helm chart
#                                          gives them (no memory-mapped files, so no
#                                          vm.max_map_count change)
#
# Default image: opensearch-lite:3.9.0. KEEP=1 leaves the containers running.

set -euo pipefail

MODE=single
if [[ "${1:-}" == "--cluster" ]]; then MODE=cluster; shift; fi
IMAGE="${1:-opensearch-lite:3.9.0}"
ENGINE="$(command -v docker || command -v podman)"
ID="opensearch-lite-smoke-$$"
PORT="${PORT:-19200}"
URL="http://127.0.0.1:$PORT"
CONTAINERS=()

cleanup() {
  if [[ "${KEEP:-}" == 1 ]]; then return; fi
  if (( ${#CONTAINERS[@]} )); then "$ENGINE" rm -f "${CONTAINERS[@]}" >/dev/null 2>&1 || true; fi
  "$ENGINE" network rm "$ID" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# start <name> <extra docker args...>: one node, locked down like the chart's pod.
start() {
  local name="$1"; shift
  CONTAINERS+=("$name")
  "$ENGINE" run -d --name "$name" --hostname "$name" \
    --user "$((100000 + RANDOM)):0" --cap-drop ALL --security-opt no-new-privileges \
    --read-only \
    --tmpfs /tmp:exec,mode=1777 \
    --tmpfs /usr/share/opensearch/logs:mode=1777 \
    --tmpfs /usr/share/opensearch/data:exec,mode=1777 \
    -e OPENSEARCH_JAVA_OPTS="-Xms512m -Xmx512m" \
    "$@" "$IMAGE" >/dev/null
}

fail() {
  echo "FAIL: $*" >&2
  for c in "${CONTAINERS[@]}"; do
    echo "--- last log lines of $c" >&2
    "$ENGINE" logs --tail 40 "$c" >&2 || true
  done
  exit 1
}

wait_for() { # wait_for <url path that must answer 200>
  for _ in $(seq 1 120); do
    if curl -fs -m 5 "$URL$1" >/dev/null 2>&1; then return 0; fi
    sleep 2
  done
  fail "no answer from $URL$1 after 4 minutes"
}

check() { # check <description> <text the answer must contain> <curl arguments...>
  local what="$1" want="$2"; shift 2
  local got
  got="$(curl -sS -m 60 -H 'Content-Type: application/json' "$@" 2>&1)" || fail "$what: $got"
  [[ "$got" == *"$want"* ]] || fail "$what: expected '$want' in: ${got:0:600}"
  echo "ok   $what"
}

eventually() { # eventually <description> <text> <curl arguments...>: the same, retried for a minute
  local what="$1" want="$2"; shift 2
  local got=""
  for _ in $(seq 1 30); do
    got="$(curl -sS -m 60 -H 'Content-Type: application/json' "$@" 2>&1)" || true
    if [[ "$got" == *"$want"* ]]; then echo "ok   $what"; return 0; fi
    sleep 2
  done
  fail "$what: expected '$want' in: ${got:0:600}"
}

if [[ "$MODE" == cluster ]]; then
  echo "==> three nodes of $IMAGE (vm.max_map_count here: $(cat /proc/sys/vm/max_map_count 2>/dev/null || echo unknown))"
  # A node that other nodes can reach enforces OpenSearch's start-up checks; a single node
  # only warns. The one that depends on the host rather than on the image is the number of
  # open files. OpenShift gives containers 1048576.
  files="$("$ENGINE" run --rm --entrypoint sh "$IMAGE" -c 'ulimit -n')"
  if [[ "$files" != unlimited ]] && (( files < 65535 )); then
    echo "FAIL: containers on this host get $files open files, and OpenSearch refuses to form a" >&2
    echo "      cluster with fewer than 65535. Raise the container engine's nofile limit." >&2
    exit 1
  fi
  "$ENGINE" network create "$ID" >/dev/null
  for i in 0 1 2; do
    publish=()
    if [[ $i == 0 ]]; then publish=(-p "127.0.0.1:$PORT:9200"); fi
    start "$ID-$i" --network "$ID" ${publish[@]+"${publish[@]}"} \
      -e cluster.name=smoke \
      -e discovery.type=zen \
      -e discovery.seed_hosts="$ID-0,$ID-1,$ID-2" \
      -e cluster.initial_cluster_manager_nodes="$ID-0,$ID-1,$ID-2" \
      -e cluster.default_number_of_replicas=1 \
      -e node.store.allow_mmap=false
  done
  wait_for "/_cluster/health?wait_for_nodes=3&timeout=5s"
  check "three nodes joined"              '"number_of_nodes":3'  "$URL/_cluster/health"
  check "index with two replicas"         '"acknowledged":true'  -X PUT "$URL/smoke" -d '{"settings":{"number_of_shards":1,"number_of_replicas":2}}'
  check "all copies allocated (green)"    '"status":"green"'     "$URL/_cluster/health/smoke?wait_for_status=green&timeout=60s"
  check "write"                           '"result":"created"'   -X PUT "$URL/smoke/_doc/1?refresh=true" -d '{"msg":"hello"}'
  check "search"                          '"value":1'            "$URL/smoke/_search" -d '{"query":{"match":{"msg":"hello"}}}'
  check "memory-mapped files are off"     '"allow_mmap":"false"' "$URL/_nodes/_local/settings?flat_settings=false&filter_path=nodes.*.settings.node.store"
  check "a new index gets one replica"    '"acknowledged":true'  -X PUT "$URL/smoke-default"
  check "and that replica is allocated"   '"active_shards":2'    "$URL/_cluster/health/smoke-default?wait_for_status=green&timeout=60s"
  "$ENGINE" stop -t 60 "$ID-2" >/dev/null
  check "one node lost, two carry on"     '"number_of_nodes":2'  "$URL/_cluster/health?wait_for_nodes=2&timeout=60s"
  check "search with one node gone"       '"value":1'            "$URL/smoke/_search" -d '{"query":{"match":{"msg":"hello"}}}'
  echo "==> cluster checks passed"
  exit 0
fi

echo "==> one node of $IMAGE"
start "$ID" -p "127.0.0.1:$PORT:9200"
wait_for "/_cluster/health?wait_for_status=yellow&timeout=1s"

check "version 3.9.0, container build"  '"build_type" : "docker"'  "$URL/"
check "version 3.9.0"                   '"number" : "3.9.0"'       "$URL/"
check "answers without a login"         '"cluster_name":"opensearch-lite"' "$URL/_cluster/health"

plugins="$(curl -fsS "$URL/_cat/plugins?h=component" | sort | xargs)"
[[ "$plugins" == "opensearch-index-management opensearch-job-scheduler opensearch-sql" ]] \
  || fail "expected exactly job-scheduler, index-management and sql, got: $plugins"
echo "ok   plugins: $plugins"

uid="$("$ENGINE" exec "$ID" id -u)"; pid1="$("$ENGINE" exec "$ID" cat /proc/1/comm)"
[[ "$uid" -ge 100000 && "$pid1" == java ]] || fail "expected a random UID and java as PID 1, got uid=$uid pid1=$pid1"
echo "ok   runs as UID $uid, java is PID 1"

check "bulk index" '"errors":false' -X POST "$URL/_bulk?refresh=true" --data-binary '{"index":{"_index":"smoke-logs","_id":"1"}}
{"@timestamp":"2026-11-22T00:00:00Z","level":"info","service":"api","latency_ms":12,"location":{"lat":40.4,"lon":-3.7}}
{"index":{"_index":"smoke-logs","_id":"2"}}
{"@timestamp":"2026-11-22T00:01:00Z","level":"error","service":"api","latency_ms":250,"location":{"lat":51.5,"lon":-0.1}}
{"index":{"_index":"smoke-logs","_id":"3"}}
{"@timestamp":"2026-11-22T00:02:00Z","level":"info","service":"web","latency_ms":40,"location":{"lat":48.8,"lon":2.3}}
'
check "search"                     '"value":2'          "$URL/smoke-logs/_search" -d '{"query":{"match":{"level":"info"}}}'
check "date histogram and terms"   '"doc_count":2'      "$URL/smoke-logs/_search" -d '{"size":0,"aggs":{"s":{"terms":{"field":"service.keyword"},"aggs":{"t":{"date_histogram":{"field":"@timestamp","fixed_interval":"1m"}}}}}}'
check "painless script"            '"result":"updated"' -X POST "$URL/smoke-logs/_update/1?refresh=true" -d '{"script":{"source":"ctx._source.latency_ms += params.n","params":{"n":1}}}'
check "scripted field"             '"double":[26.0]'    "$URL/smoke-logs/_search" -d '{"query":{"ids":{"values":["1"]}},"_source":false,"script_fields":{"double":{"script":"doc[\"latency_ms\"].value * 2.0"}}}'
check "update by query (reindex)"  '"updated":3'        -X POST "$URL/smoke-logs/_update_by_query?refresh=true" -d '{"script":{"source":"ctx._source.checked = true"}}'
check "reindex"                    '"created":3'        -X POST "$URL/_reindex?refresh=true" -d '{"source":{"index":"smoke-logs"},"dest":{"index":"smoke-copy"}}'
check "geo mapping"                '"acknowledged":true' -X PUT "$URL/smoke-geo" -d '{"mappings":{"properties":{"location":{"type":"geo_point"}}}}'
check "geo document"               '"result":"created"' -X PUT "$URL/smoke-geo/_doc/1?refresh=true" -d '{"location":{"lat":40.4,"lon":-3.7}}'
check "geo tile grid (maps)"       '"doc_count":1'      "$URL/smoke-geo/_search" -d '{"size":0,"aggs":{"g":{"geotile_grid":{"field":"location","precision":4}}}}'
check "saved objects index"        '"result":"created"' -X PUT "$URL/.kibana_1/_doc/config:3.9.0?refresh=true" -d '{"type":"config","config":{"buildNum":1}}'
check "ingest pipeline with grok"  '"level":"WARN"'     -X POST "$URL/_ingest/pipeline/_simulate" -d '{"pipeline":{"processors":[{"grok":{"field":"m","patterns":["%{LOGLEVEL:level} %{GREEDYDATA:rest}"]}}]},"docs":[{"_source":{"m":"WARN disk is filling up"}}]}'
check "date format in French (locale data in the runtime)" '"acknowledged":true' -X PUT "$URL/smoke-fr" -d '{"mappings":{"properties":{"d":{"type":"date","format":"d MMMM yyyy","locale":"fr"}}}}'
check "French date parsed"         '"result":"created"' -X PUT "$URL/smoke-fr/_doc/1" -d '{"d":"3 février 2026"}'
check "SQL"                        '"total": 2'         -X POST "$URL/_plugins/_sql" -d '{"query":"SELECT service, latency_ms FROM smoke-logs WHERE level = '"'"'info'"'"' ORDER BY latency_ms"}'
check "PPL"                        '"total": 1'         -X POST "$URL/_plugins/_ppl" -d '{"query":"source=smoke-logs | where level = '"'"'error'"'"' | fields service, latency_ms"}'
check "PPL stats"                  '"total": 2'         -X POST "$URL/_plugins/_ppl" -d '{"query":"source=smoke-logs | stats avg(latency_ms) by service"}'
check "Index Management: policy"   '"_id":"smoke-delete"' -X PUT "$URL/_plugins/_ism/policies/smoke-delete" -d '{"policy":{"description":"delete after 30 days","default_state":"hot","states":[{"name":"hot","actions":[],"transitions":[{"state_name":"delete","conditions":{"min_index_age":"30d"}}]},{"name":"delete","actions":[{"delete":{}}],"transitions":[]}]}}'
check "Index Management: attach"   '"updated_indices":1' -X POST "$URL/_plugins/_ism/add/smoke-logs" -d '{"policy_id":"smoke-delete"}'
eventually "Index Management: index is managed" '"policy_id":"smoke-delete"' "$URL/_plugins/_ism/explain/smoke-logs"
check "security plugin is absent"  'no handler found'   "$URL/_plugins/_security/api/roles"
check "green: one node, no replicas waiting" '"status":"green"' "$URL/_cluster/health?wait_for_status=green&timeout=60s"

if "$ENGINE" logs "$ID" 2>&1 | grep -E 'ClassNotFoundException|NoClassDefFoundError|UnsatisfiedLinkError|Read-only file system'; then
  fail "the log shows a missing class, library or a write to the read-only filesystem"
fi
echo "ok   log is free of missing classes and read-only filesystem errors"
echo "==> all checks passed"
