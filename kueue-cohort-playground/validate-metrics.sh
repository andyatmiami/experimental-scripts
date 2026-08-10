#!/usr/bin/env bash
set -euo pipefail

PROM_URL="${PROM_URL:-http://localhost:9090}"
PASS=0
FAIL=0
WARN=0

# Colors (if terminal supports them)
if [[ -t 1 ]]; then
  GREEN='\033[0;32m'
  RED='\033[0;31m'
  YELLOW='\033[0;33m'
  CYAN='\033[0;36m'
  NC='\033[0m'
else
  GREEN='' RED='' YELLOW='' CYAN='' NC=''
fi

prom_query() {
  local query="$1"
  curl -sf "${PROM_URL}/api/v1/query" --data-urlencode "query=${query}" 2>/dev/null
}

prom_query_value() {
  local query="$1"
  local result
  result=$(prom_query "${query}")
  if [[ $? -ne 0 ]] || [[ -z "${result}" ]]; then
    echo "ERROR"
    return 1
  fi
  echo "${result}" | python3 -c "
import sys, json
data = json.load(sys.stdin)
if data['status'] != 'success':
    print('ERROR')
    sys.exit(1)
results = data['data']['result']
if not results:
    print('EMPTY')
else:
    for r in results:
        labels = ', '.join(f'{k}={v}' for k, v in sorted(r['metric'].items()) if k != '__name__')
        print(f'{r[\"value\"][1]}\t{labels}')
" 2>/dev/null
}

check_metric() {
  local name="$1"
  local expected_min="${2:-1}"
  local result
  result=$(prom_query "${name}")

  if [[ -z "${result}" ]]; then
    printf "  ${RED}FAIL${NC}  %-50s  (query failed - is Prometheus accessible at ${PROM_URL}?)\n" "${name}"
    FAIL=$((FAIL + 1))
    return
  fi

  local count
  count=$(echo "${result}" | python3 -c "
import sys, json
data = json.load(sys.stdin)
print(len(data.get('data', {}).get('result', [])))
" 2>/dev/null)

  if [[ -z "${count}" ]] || [[ "${count}" == "0" ]]; then
    printf "  ${RED}FAIL${NC}  %-50s  (0 series, expected >= %s)\n" "${name}" "${expected_min}"
    FAIL=$((FAIL + 1))
  elif [[ "${count}" -ge "${expected_min}" ]]; then
    printf "  ${GREEN}OK${NC}    %-50s  (%s series)\n" "${name}" "${count}"
    PASS=$((PASS + 1))
  else
    printf "  ${YELLOW}WARN${NC}  %-50s  (%s series, expected >= %s)\n" "${name}" "${count}" "${expected_min}"
    WARN=$((WARN + 1))
  fi
}

check_value() {
  local description="$1"
  local query="$2"
  local expected="$3"
  local result
  result=$(prom_query_value "${query}" | head -1 | cut -f1)

  if [[ "${result}" == "ERROR" ]] || [[ "${result}" == "EMPTY" ]]; then
    printf "  ${RED}FAIL${NC}  %-50s  (no data)\n" "${description}"
    FAIL=$((FAIL + 1))
  elif [[ "${result}" == "${expected}" ]]; then
    printf "  ${GREEN}OK${NC}    %-50s  = %s (expected %s)\n" "${description}" "${result}" "${expected}"
    PASS=$((PASS + 1))
  else
    printf "  ${YELLOW}WARN${NC}  %-50s  = %s (expected %s)\n" "${description}" "${result}" "${expected}"
    WARN=$((WARN + 1))
  fi
}

echo "============================================"
echo "  Validating Kueue Metrics in Prometheus"
echo "  Target: ${PROM_URL}"
echo "============================================"

# Check Prometheus is reachable
if ! curl -sf "${PROM_URL}/-/ready" &>/dev/null; then
  echo ""
  echo -e "${RED}ERROR: Prometheus is not reachable at ${PROM_URL}${NC}"
  echo ""
  echo "Try one of:"
  echo "  kubectl port-forward -n monitoring svc/kube-prom-stack-kube-prome-prometheus 9090:9090"
  echo "  PROM_URL=http://localhost:XXXX ./validate-metrics.sh"
  exit 1
fi

echo ""
echo -e "${CYAN}=== Kueue ClusterQueue Metrics ===${NC}"
check_metric "kueue_cluster_queue_nominal_quota" 5
check_metric "kueue_cluster_queue_resource_usage" 1
check_metric "kueue_cluster_queue_borrowing_limit" 5
check_metric "kueue_cluster_queue_lending_limit" 1
check_metric "kueue_cluster_queue_resource_reservation" 1
check_metric "kueue_cluster_queue_info" 5

echo ""
echo -e "${CYAN}=== Kueue Cohort Metrics ===${NC}"
check_metric "kueue_cohort_info" 4
check_metric "kueue_cohort_subtree_quota" 1

echo ""
echo -e "${CYAN}=== Kueue LocalQueue Metrics ===${NC}"
check_metric "kueue_local_queue_resource_usage" 1
check_metric "kueue_local_queue_resource_reservation" 1
check_metric "kueue_local_queue_pending_workloads" 1
check_metric "kueue_local_queue_status" 5

echo ""
echo -e "${CYAN}=== Recording Rules: Join Metric ===${NC}"
check_metric "kueue:local_queue_info" 5

echo ""
echo -e "${CYAN}=== Recording Rules: Guaranteed Quota ===${NC}"
check_metric "kueue:namespace_guaranteed_quota" 5

echo ""
echo -e "${CYAN}=== Recording Rules: Intermediate ===${NC}"
check_metric "kueue:cq_cohort_available" 5

echo ""
echo -e "${CYAN}=== Recording Rules: Borrowable ===${NC}"
check_metric "kueue:namespace_borrowable_quota" 1

echo ""
echo -e "${CYAN}=== Recording Rules: Usage ===${NC}"
check_metric "kueue:namespace_resource_usage" 1

echo ""
echo -e "${CYAN}=== Spot-Check Values ===${NC}"
echo "  (Checking guaranteed quota for each CQ's namespace)"
check_value "team-ml guaranteed (cpu)" \
  'kueue:namespace_guaranteed_quota{namespace="team-ml-project",resource="cpu"}' "1"
check_value "team-nlp guaranteed (cpu)" \
  'kueue:namespace_guaranteed_quota{namespace="team-nlp-project",resource="cpu"}' "1"
check_value "serving guaranteed (cpu)" \
  'kueue:namespace_guaranteed_quota{namespace="serving-project",resource="cpu"}' "2"
check_value "team-a guaranteed (cpu)" \
  'kueue:namespace_guaranteed_quota{namespace="team-a-project",resource="cpu"}' "1"
check_value "team-b guaranteed (cpu)" \
  'kueue:namespace_guaranteed_quota{namespace="team-b-project",resource="cpu"}' "1"

echo ""
echo -e "${CYAN}=== LQ Info Exporter (dynamic join) ===${NC}"
check_metric "kueue_local_queue_info" 1

# Summary
echo ""
echo "============================================"
echo -e "  Results: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC}, ${YELLOW}${WARN} warnings${NC}"
echo "============================================"

if [[ ${FAIL} -gt 0 ]]; then
  echo ""
  echo "Troubleshooting tips:"
  echo "  - Wait 60s after setup for metrics to populate"
  echo "  - Check Prometheus targets: ${PROM_URL}/targets"
  echo "  - Check recording rules: ${PROM_URL}/rules"
  echo "  - Verify Kueue is running: kubectl -n kueue-system get pods"
  exit 1
fi
