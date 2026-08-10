#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="kueue-cohort-playground"

echo "Deleting KinD cluster '${CLUSTER_NAME}'..."
kind delete cluster --name "${CLUSTER_NAME}"
echo "Done."
