#!/usr/bin/env bash
# Den Anwendungs-Cluster im Observability-Cluster sichtbar machen.
#
# Beruehrt ZWEI Cluster: hier die Endpunkte und der Lesezugang, dort die
# ScrapeConfigs und das Zugangsgeheimnis.
set -euo pipefail
cd "$(dirname "$0")/.." && set -a && . versions.env && set +a

APPS="kind-${APPS_CLUSTER_NAME}"
OBS="kind-${OBS_CLUSTER_NAME}"

echo ">> kube-state-metrics ${KUBE_STATE_METRICS_VERSION}"
helm repo add prometheus-community "${KPS_REPO}" >/dev/null 2>&1 || true
helm repo update prometheus-community >/dev/null
helm --kube-context "${APPS}" upgrade --install kube-state-metrics \
  prometheus-community/kube-state-metrics \
  --version "${KUBE_STATE_METRICS_VERSION}" \
  --namespace metrics-access --create-namespace \
  -f apps/kube-state-values.yaml \
  --wait --timeout 5m >/dev/null
echo "   bereit"

echo ">> Lesezugang und Knotenports"
kubectl --context "${APPS}" apply -f apps/metrics-access.yaml >/dev/null
echo "   ServiceAccount prometheus-scraper, NodePorts ${APPS_INGRESS_METRICS_NODEPORT} und ${APPS_KSM_NODEPORT}"

# Token UND CA in ein Secret im Observability-Cluster. Das Token gehoert einem
# ServiceAccount, der ausschliesslich Metriken lesen darf - was hier
# hinuebergeht, oeffnet nichts anderes.
echo ">> Zugang in den Observability-Cluster"
for i in $(seq 1 30); do
  tok=$(kubectl --context "${APPS}" -n metrics-access get secret prometheus-scraper-token \
        -o jsonpath='{.data.token}' 2>/dev/null || true)
  [ -n "${tok:-}" ] && break
  [ "$i" = 30 ] && { echo "   kein Token nach 30 Versuchen"; exit 1; }
  sleep 1
done
tmp=$(mktemp -d) && trap 'rm -rf "$tmp"' EXIT
printf '%s' "$tok" | base64 -d > "$tmp/token"
kubectl --context "${APPS}" -n metrics-access get secret prometheus-scraper-token \
  -o jsonpath='{.data.ca\.crt}' | base64 -d > "$tmp/ca.crt"

kubectl --context "${OBS}" -n "${OBS_NAMESPACE}" create secret generic apps-scraper \
  --from-file=token="$tmp/token" --from-file=ca.crt="$tmp/ca.crt" \
  --dry-run=client -o yaml | kubectl --context "${OBS}" apply -f - >/dev/null
echo "   Secret apps-scraper (Token und CA)"

kubectl --context "${OBS}" apply -f observability/scrape-apps.yaml >/dev/null
echo "   vier ScrapeConfigs: cadvisor, kubelet, ingress, kube-state"
