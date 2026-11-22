#!/usr/bin/env bash
#
# Installs the Helm chart on the Kubernetes cluster kubectl points at and checks it, in a
# namespace of its own that enforces the "restricted" pod security standard (the nearest
# plain Kubernetes has to OpenShift's restricted-v2 policy). The namespace is removed at
# the end.
#
#   lite/helm_test.sh [image:tag]              one node
#   REPLICAS=3 lite/helm_test.sh [image:tag]   a cluster of three
#
# The cluster must be able to pull the image (on kind: kind load docker-image <image>).
# Default image: opensearch-lite:3.9.0.
#
# Environment:
#   KEEP=1        leave the namespace in place
#   NETPOL=skip   skip the check that other pods are kept out, on a cluster whose network
#                 does not enforce NetworkPolicies

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${1:-opensearch-lite:3.9.0}"
REPLICAS="${REPLICAS:-1}"
NS="opensearch-lite-test-$$"
URL="http://opensearch-lite:9200"

cleanup() {
  if [[ "${KEEP:-}" == 1 ]]; then return; fi
  kubectl delete namespace "$NS" --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  kubectl -n "$NS" get pods -o wide >&2 || true
  kubectl -n "$NS" get events --sort-by=.lastTimestamp 2>/dev/null | tail -15 >&2 || true
  kubectl -n "$NS" logs opensearch-lite-0 --tail 30 >&2 || true
  exit 1
}

# pod <name> <label>: a pod of the same image that only waits, to send requests from.
pod() {
  kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $1
  namespace: $NS
  labels: { $2 }
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  terminationGracePeriodSeconds: 0
  securityContext: { runAsNonRoot: true, runAsUser: 1000680001, seccompProfile: { type: RuntimeDefault } }
  containers:
    - name: client
      image: $IMAGE
      command: ["sleep", "3600"]
      securityContext: { allowPrivilegeEscalation: false, capabilities: { drop: [ALL] } }
EOF
}

# check <description> <text the answer must contain> <curl arguments...>, sent by the
# pod labelled as the frontend.
check() {
  local what="$1" want="$2"; shift 2
  local got
  got="$(kubectl -n "$NS" exec frontend -- curl -sS -m 120 -H 'Content-Type: application/json' "$@" 2>&1)" \
    || fail "$what: $got"
  [[ "$got" == *"$want"* ]] || fail "$what: expected '$want' in: ${got:0:600}"
  echo "ok   $what"
}

# eventually <description> <text> <curl arguments...>: the same, retried for three minutes.
eventually() {
  local what="$1" want="$2"; shift 2
  local got=""
  for _ in $(seq 1 60); do
    got="$(kubectl -n "$NS" exec frontend -- curl -sS -m 120 -H 'Content-Type: application/json' "$@" 2>&1)" || true
    if [[ "$got" == *"$want"* ]]; then echo "ok   $what"; return 0; fi
    sleep 3
  done
  fail "$what: expected '$want' in: ${got:0:600}"
}

echo "==> chart with $REPLICAS node(s) of $IMAGE in namespace $NS"
kubectl create namespace "$NS" >/dev/null
kubectl label namespace "$NS" pod-security.kubernetes.io/enforce=restricted >/dev/null

# OpenShift gives the pod a UID and an fsGroup from the namespace's range. Plain
# Kubernetes has to be told, so the test says what OpenShift would.
helm install opensearch-lite "$ROOT/lite/helm/opensearch-lite" -n "$NS" \
  --set image.repository="${IMAGE%:*}" --set image.tag="${IMAGE##*:}" \
  --set replicas="$REPLICAS" --set heap=512m --set persistence.size=1Gi \
  --set resources.requests.cpu=100m --set resources.requests.memory=1Gi \
  --set resources.limits.memory=1536Mi \
  --set podSecurityContext.runAsUser=1000680000 \
  --set podSecurityContext.fsGroup=1000680000 >/dev/null
kubectl -n "$NS" rollout status statefulset/opensearch-lite --timeout=10m >/dev/null \
  || fail "the pods did not become ready"
echo "ok   $REPLICAS pod(s) ready under the restricted policy"

uid="$(kubectl -n "$NS" exec opensearch-lite-0 -- id -u)"
[[ "$uid" == 1000680000 ]] || fail "expected the UID the namespace assigned, got $uid"
if kubectl -n "$NS" exec opensearch-lite-0 -- touch /usr/share/opensearch/config/probe 2>/dev/null; then
  fail "the root filesystem is writable"
fi
echo "ok   runs as UID $uid on a read-only root filesystem"

pod frontend "app.kubernetes.io/name: infradashboard"
pod stranger "role: stranger"
kubectl -n "$NS" wait --for=condition=Ready pod/frontend pod/stranger --timeout=180s >/dev/null \
  || fail "the client pods did not start"

check "a pod labelled as the frontend reaches port 9200" '"number" : "3.' "$URL/"
eventually "all nodes joined, green" "\"status\":\"green\",\"timed_out\":false,\"number_of_nodes\":$REPLICAS" \
  "$URL/_cluster/health?wait_for_nodes=$REPLICAS&wait_for_status=green&timeout=30s"
check "write" '"result":"created"' -X PUT "$URL/helm-test/_doc/1?refresh=true" -d '{"msg":"hello"}'
check "replicas: none on one node, one on a cluster" "\"number_of_replicas\":\"$(( REPLICAS > 1 ? 1 : 0 ))\"" \
  "$URL/helm-test/_settings"
check "SQL" '"total": 1' -X POST "$URL/_plugins/_sql" -d '{"query":"SELECT msg FROM helm-test"}'
check "Index Management" '"_id":"helm-test"' -X PUT "$URL/_plugins/_ism/policies/helm-test" \
  -d '{"policy":{"description":"test","default_state":"hot","states":[{"name":"hot","actions":[],"transitions":[]}]}}'

if [[ "${NETPOL:-}" == skip ]]; then
  echo "skip the NetworkPolicy check (NETPOL=skip)"
else
  if kubectl -n "$NS" exec stranger -- curl -s -m 8 -o /dev/null "$URL/" 2>/dev/null; then
    fail "a pod without the frontend's label reached port 9200: either this cluster's network does not enforce NetworkPolicies (then rerun with NETPOL=skip) or the policy is too wide"
  fi
  echo "ok   a pod without the frontend's label is kept out of port 9200"
  node_ip="$(kubectl -n "$NS" get pod opensearch-lite-0 -o jsonpath='{.status.podIP}')"
  if kubectl -n "$NS" exec frontend -- curl -s -m 8 -o /dev/null "http://$node_ip:9300/" 2>/dev/null; then
    fail "the frontend's label opened port 9300 (node to node) as well"
  fi
  echo "ok   and nobody but OpenSearch's own pods reaches port 9300"
fi

# The pod is deleted and comes back: on one node the volume kept the data, on a cluster
# the node rejoins.
kubectl -n "$NS" delete pod opensearch-lite-0 >/dev/null
kubectl -n "$NS" rollout status statefulset/opensearch-lite --timeout=10m >/dev/null \
  || fail "the deleted pod did not come back"
eventually "after a pod is deleted and comes back: all nodes, green" "\"status\":\"green\",\"timed_out\":false,\"number_of_nodes\":$REPLICAS" \
  "$URL/_cluster/health?wait_for_nodes=$REPLICAS&wait_for_status=green&timeout=30s"
check "and the document is still there" '"msg":"hello"' "$URL/helm-test/_doc/1"

echo "==> chart checks passed"
