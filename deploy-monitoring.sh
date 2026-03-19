#!/usr/bin/env bash
# deploy-monitoring.sh — Deploys Prometheus + Grafana monitoring stack to the cluster.
# Usage: bash deploy-monitoring.sh
#
# Installs:
#   - Helm (if not already installed)
#   - kube-prometheus-stack (Prometheus, Grafana, node-exporter, kube-state-metrics)
#
# After deployment, access Grafana:
#   kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80
#   Open http://localhost:3000  (admin / prom-operator)
#
# Pre-built dashboards include per-core CPU, memory, thread counts, and pod-level metrics.

set -euo pipefail

NAMESPACE="monitoring"

# --- Install Helm if needed ---
if ! command -v helm &>/dev/null; then
  echo "=== Installing Helm ==="
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  echo ""
fi

echo "=== Helm version ==="
helm version --short
echo ""

# --- Add prometheus-community chart repo ---
echo "=== Adding prometheus-community Helm repo ==="
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm repo update
echo ""

# --- Deploy kube-prometheus-stack ---
echo "=== Deploying kube-prometheus-stack to namespace '$NAMESPACE' ==="
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace "$NAMESPACE" --create-namespace \
  --set prometheus.prometheusSpec.retention=7d \
  --set prometheus.prometheusSpec.resources.requests.memory=256Mi \
  --set prometheus.prometheusSpec.resources.requests.cpu=100m \
  --set prometheus.prometheusSpec.resources.limits.memory=512Mi \
  --set grafana.adminPassword=prom-operator \
  --set grafana.persistence.enabled=false \
  --set grafana.resources.requests.memory=128Mi \
  --set grafana.resources.requests.cpu=50m \
  --set grafana.resources.limits.memory=256Mi \
  --set nodeExporter.enabled=true \
  --set kubeStateMetrics.enabled=true \
  --wait --timeout 5m

echo ""
echo "=== Deployment complete ==="
echo ""

# --- Show status ---
echo "Pods in $NAMESPACE:"
kubectl get pods -n "$NAMESPACE" -o wide
echo ""

echo "Services in $NAMESPACE:"
kubectl get svc -n "$NAMESPACE"
echo ""

echo "============================================"
echo "  Monitoring stack is running!"
echo "============================================"
echo ""
echo "  Access Grafana:"
echo "    kubectl port-forward -n $NAMESPACE svc/kube-prometheus-stack-grafana 3000:80"
echo "    Open http://localhost:3000"
echo "    Login: admin / prom-operator"
echo ""
echo "  Useful dashboards (pre-installed):"
echo "    - Node Exporter / Nodes        → per-core CPU, load, threads"
echo "    - K8s / Compute Resources       → cluster & node CPU/memory"
echo "    - K8s / Compute Resources / Pod → per-pod breakdown"
echo ""
echo "  Quick CLI checks:"
echo "    kubectl top nodes"
echo "    kubectl top pods -A"
echo ""
