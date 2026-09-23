#!/usr/bin/env bash
# Der Observability-Cluster: kind-Cluster, Namespace, kube-prometheus-stack.
#
# Idempotent - ein zweiter Lauf legt nichts doppelt an und macht nichts kaputt.
set -euo pipefail
cd "$(dirname "$0")/.." && set -a && . versions.env && set +a

CTX="kind-${OBS_CLUSTER_NAME}"
K="kubectl --context ${CTX}"
H="helm --kube-context ${CTX}"

# Das Passwort zuerst pruefen, nicht zuletzt: ein Cluster, der steht, und ein
# Helm-Lauf, der an einer fehlenden Datei scheitert, ist der teuerste Abbruch.
if [ ! -f observability/values.local.yaml ]; then
  echo "   FEHLT: observability/values.local.yaml"
  echo "   cp observability/values.local.yaml.example observability/values.local.yaml"
  echo "   und ein Grafana-Passwort setzen."
  exit 1
fi

if kind get clusters 2>/dev/null | grep -qx "${OBS_CLUSTER_NAME}"; then
  echo "   Cluster ${OBS_CLUSTER_NAME} existiert"
else
  echo ">> kind-Cluster ${OBS_CLUSTER_NAME}"
  kind create cluster --name "${OBS_CLUSTER_NAME}" --config observability/kind.yaml
fi

$K apply -f observability/namespace.yaml >/dev/null
echo "   Namespace ${OBS_NAMESPACE} da"

echo ">> kube-prometheus-stack ${KPS_VERSION}"
helm repo add prometheus-community "${KPS_REPO}" >/dev/null 2>&1 || true
helm repo update prometheus-community >/dev/null
$H upgrade --install observability prometheus-community/kube-prometheus-stack \
  --version "${KPS_VERSION}" \
  --namespace "${OBS_NAMESPACE}" \
  -f observability/values.yaml \
  -f observability/values.local.yaml \
  --wait --timeout 10m >/dev/null
echo "   Prometheus:  http://127.0.0.1:9090"
echo "   Grafana:     http://127.0.0.1:3000  (Benutzer admin)"
