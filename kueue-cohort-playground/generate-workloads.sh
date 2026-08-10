#!/usr/bin/env bash
set -euo pipefail

SCENARIO="${1:-}"
JOB_DURATION="${JOB_DURATION:-600}"
JOB_CPU="${JOB_CPU:-250m}"
JOB_MEM="${JOB_MEM:-64Mi}"

ALL_NAMESPACES="team-ml-project team-nlp-project serving-project team-a-project team-b-project"

usage() {
  cat <<'EOF'
Usage: generate-workloads.sh SCENARIO

Scenarios:
  normal       Baseline usage matching the worked example
               team-ml: 3 jobs (750m), team-nlp: 1 job (250m), serving: 6 jobs (1500m)
  borrowing    Push team-ml past nominal (1000m) to force borrowing
               Adds 4 jobs -> total 1750m, borrows 750m from research Cohort
  exhaustion   Push team-ml past ceiling -> some jobs will pend
               Adds 6 more jobs beyond what the Cohort can supply
  flat         Generate workloads for the flat topology
               team-a: 3 jobs (750m), team-b: 5 jobs (1250m, forces borrowing)
  all          Run normal + borrowing + exhaustion + flat in sequence
  clean        Delete all workload jobs across all namespaces
  status       Show ClusterQueue, LocalQueue, and workload state

Environment variables:
  JOB_DURATION  Sleep duration in seconds (default: 600)
  JOB_CPU       CPU request per job (default: 250m)
  JOB_MEM       Memory request per job (default: 64Mi)

EOF
  exit 1
}

submit_job() {
  local ns="$1" name="$2" cpu="${3:-${JOB_CPU}}" duration="${4:-${JOB_DURATION}}"

  if kubectl get job "${name}" -n "${ns}" &>/dev/null; then
    echo "  ${ns}/${name}: already exists, skipping"
    return
  fi

  cat <<EOF | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: ${name}
  namespace: ${ns}
  labels:
    kueue.x-k8s.io/queue-name: default
    lab: denominator
spec:
  suspend: true
  template:
    spec:
      containers:
      - name: sleep
        image: busybox:latest
        command: ["sleep", "${duration}"]
        resources:
          requests:
            cpu: "${cpu}"
            memory: "${JOB_MEM}"
      restartPolicy: Never
EOF
  echo "  ${ns}/${name}: submitted (${cpu} cpu, ${duration}s)"
}

submit_batch() {
  local ns="$1" prefix="$2" count="$3" cpu="${4:-${JOB_CPU}}"
  for i in $(seq 1 "${count}"); do
    submit_job "${ns}" "${prefix}-${i}" "${cpu}"
  done
}

show_status() {
  echo ""
  echo "=== ClusterQueue Status ==="
  kubectl get clusterqueues -o wide 2>/dev/null || echo "  (none found)"

  echo ""
  echo "=== LocalQueue Status ==="
  kubectl get localqueues -A -o wide 2>/dev/null || echo "  (none found)"

  echo ""
  echo "=== Workloads ==="
  kubectl get workloads -A -o wide 2>/dev/null || echo "  (none found)"

  echo ""
  echo "=== Jobs by Namespace ==="
  for ns in ${ALL_NAMESPACES}; do
    local count
    count=$(kubectl get jobs -n "${ns}" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [[ "${count}" -gt 0 ]]; then
      echo "--- ${ns} (${count} jobs) ---"
      kubectl get jobs -n "${ns}" --no-headers 2>/dev/null | while read -r line; do
        echo "  ${line}"
      done
    fi
  done
}

case "${SCENARIO}" in
  normal)
    echo "=== Scenario: Normal Usage ==="
    echo "Matches baseline worked example: team-ml=750m, team-nlp=250m, serving=1500m"
    echo ""
    submit_batch team-ml-project   "ml-work"       3
    submit_batch team-nlp-project  "nlp-work"      1
    submit_batch serving-project   "serving-work"   6
    ;;

  borrowing)
    echo "=== Scenario: Borrowing ==="
    echo "Adding 4 jobs to team-ml (total 1750m with normal, nominal=1000m -> borrows 750m)"
    echo ""
    submit_batch team-ml-project "ml-borrow" 4
    ;;

  exhaustion)
    echo "=== Scenario: Exhaustion ==="
    echo "Adding 6 jobs to team-ml beyond ceiling -> some will pend"
    echo ""
    submit_batch team-ml-project "ml-exhaust" 6
    ;;

  flat)
    echo "=== Scenario: Flat Topology ==="
    echo "team-a: 3 jobs (750m), team-b: 5 jobs (1250m, forces borrowing past nominal 1000m)"
    echo ""
    submit_batch team-a-project "ta-work" 3
    submit_batch team-b-project "tb-work" 5
    ;;

  all)
    echo "Running all scenarios in sequence..."
    echo ""
    "$0" normal
    echo ""
    echo "Waiting 10s for admission..."
    sleep 10
    "$0" borrowing
    echo ""
    echo "Waiting 10s for admission..."
    sleep 10
    "$0" exhaustion
    echo ""
    echo "Waiting 10s for admission..."
    sleep 10
    "$0" flat
    echo ""
    show_status
    ;;

  clean)
    echo "=== Cleaning all workload jobs ==="
    for ns in ${ALL_NAMESPACES}; do
      deleted=$(kubectl delete jobs -l lab=denominator -n "${ns}" --ignore-not-found 2>&1 | grep -c 'deleted' || true)
      echo "  ${ns}: ${deleted} jobs deleted"
    done
    echo ""
    echo "Waiting for workloads to be cleaned up..."
    sleep 5
    remaining=$(kubectl get workloads -A --no-headers 2>/dev/null | wc -l | tr -d ' ')
    echo "  Remaining workloads: ${remaining}"
    ;;

  status)
    show_status
    ;;

  *)
    usage
    ;;
esac

if [[ "${SCENARIO}" != "status" && "${SCENARIO}" != "all" && "${SCENARIO}" != "clean" ]]; then
  echo ""
  echo "Run './generate-workloads.sh status' to see queue state"
  echo "Run './validate-metrics.sh' to verify Prometheus metrics"
fi
