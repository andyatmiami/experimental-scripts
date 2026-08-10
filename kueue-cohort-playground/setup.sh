#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_NAME="kueue-cohort-playground"
KUEUE_VERSION="0.18.4"

echo "============================================"
echo "  Kueue Cohort Playground Setup"
echo "============================================"
echo ""

# Prerequisites check
for cmd in kind helm kubectl; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: ${cmd} is required but not found in PATH"
    exit 1
  fi
done

# Step 1: Create KinD cluster
echo "=== [1/7] Creating KinD cluster '${CLUSTER_NAME}' ==="
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  echo "Cluster already exists, skipping creation"
  kubectl cluster-info --context "kind-${CLUSTER_NAME}" 2>/dev/null || true
else
  kind create cluster --name "${CLUSTER_NAME}" \
    --config "${SCRIPT_DIR}/manifests/kind-config.yaml"
fi
kubectl config use-context "kind-${CLUSTER_NAME}"
echo ""

# Step 2: Install kube-prometheus-stack
echo "=== [2/7] Installing kube-prometheus-stack ==="
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm repo update prometheus-community
helm upgrade --install kube-prom-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace \
  --set prometheus.service.type=NodePort \
  --set prometheus.service.nodePort=30090 \
  --set grafana.service.type=NodePort \
  --set grafana.service.nodePort=30030 \
  --set alertmanager.enabled=false \
  --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
  --set prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues=false \
  --set prometheus.prometheusSpec.ruleSelectorNilUsesHelmValues=false \
  --set-json 'prometheus.prometheusSpec.serviceMonitorNamespaceSelector={}' \
  --set-json 'prometheus.prometheusSpec.ruleNamespaceSelector={}' \
  --set-json 'prometheus.prometheusSpec.podMonitorNamespaceSelector={}' \
  --set prometheus.prometheusSpec.retention=4h \
  --set prometheus.prometheusSpec.resources.requests.memory=256Mi \
  --set prometheus.prometheusSpec.resources.requests.cpu=100m \
  --wait --timeout 5m
echo ""

# Step 3: Install Kueue
echo "=== [3/7] Installing Kueue v${KUEUE_VERSION} ==="
helm upgrade --install kueue oci://registry.k8s.io/kueue/charts/kueue \
  --namespace kueue-system --create-namespace \
  --version "${KUEUE_VERSION}" \
  --values "${SCRIPT_DIR}/manifests/kueue-values.yaml" \
  --wait --timeout 5m
echo ""

# Step 4: Wait for Kueue controller
echo "=== [4/7] Waiting for Kueue controller ==="
kubectl -n kueue-system rollout status deployment/kueue-controller-manager --timeout=120s
echo ""

# Step 5: Apply Cohort topologies
echo "=== [5/7] Applying Cohort topologies ==="
kubectl apply -f "${SCRIPT_DIR}/manifests/topology-hierarchical.yaml"
kubectl apply -f "${SCRIPT_DIR}/manifests/topology-flat.yaml"

echo "Waiting for ClusterQueues to become active..."
for cq in team-ml team-nlp serving team-a team-b; do
  echo -n "  ${cq}: "
  if kubectl wait --for=jsonpath='{.status.conditions[?(@.type=="Active")].status}'=True \
    clusterqueue/"${cq}" --timeout=60s 2>/dev/null; then
    echo "active"
  else
    echo "WARNING: not active (check: kubectl describe clusterqueue ${cq})"
  fi
done
echo ""

# Step 6: Apply recording rules
echo "=== [6/7] Applying recording rules ==="
kubectl apply -f "${SCRIPT_DIR}/manifests/recording-rules.yaml"
echo ""

# Step 7: Deploy LQ info exporter
echo "=== [7/7] Deploying LQ info exporter ==="
kubectl apply -f "${SCRIPT_DIR}/manifests/lq-info-exporter.yaml"
echo ""

# Done
echo "============================================"
echo "  Kueue Cohort Playground is ready!"
echo "============================================"
echo ""
echo "Access:"
echo "  Prometheus:  http://localhost:9090"
echo "  Grafana:     http://localhost:3000  (admin / prom-operator)"
echo ""
echo "If NodePort access doesn't work, use port-forward:"
echo "  kubectl port-forward -n monitoring svc/kube-prom-stack-kube-prome-prometheus 9090:9090"
echo "  kubectl port-forward -n monitoring svc/kube-prom-stack-grafana 3000:80"
echo ""
echo "Next steps:"
echo "  ./generate-workloads.sh normal      # baseline usage"
echo "  ./generate-workloads.sh borrowing   # force borrowing"
echo "  ./generate-workloads.sh exhaustion  # exceed ceiling -> pending"
echo "  ./generate-workloads.sh flat        # flat topology workloads"
echo "  ./generate-workloads.sh all         # all scenarios in sequence"
echo "  ./generate-workloads.sh status      # show queue state"
echo "  ./validate-metrics.sh               # verify metrics + rules"
