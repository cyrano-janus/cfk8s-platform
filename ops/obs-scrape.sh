#!/usr/bin/env bash
# Der Weg vom Observability-Cluster zu den Metriken des Brokers im
# Plattform-Cluster: Knotenport dort, Vertrauensanker und ScrapeConfig hier.
#
# Beruehrt ZWEI Cluster und nennt deshalb bei jedem Aufruf den Kontext.
set -euo pipefail
cd "$(dirname "$0")/.." && set -a && . versions.env && set +a

PLATTFORM="kind-${KIND_CLUSTER_NAME}"
OBS="kind-${OBS_CLUSTER_NAME}"

echo ">> Knotenport fuer /metrics im Plattform-Cluster"
kubectl --context "${PLATTFORM}" apply -f observability/broker-metrics-nodeport.yaml >/dev/null
echo "   ${BROKER_METRICS_NODEPORT} -> osb-broker:443"

# Nur ca.crt wandert. Das Quell-Secret traegt auch tls.key - den privaten
# Schluessel der Plattform-CA. Wer das ganze Secret kopiert, verteilt die
# Faehigkeit, Zertifikate auszustellen, an einen Beobachter, der nur pruefen
# soll.
echo ">> Plattform-CA in den Observability-Cluster"
ca=$(mktemp) && trap 'rm -f "$ca"' EXIT
kubectl --context "${PLATTFORM}" -n cert-manager get secret osb-platform-ca \
  -o jsonpath='{.data.ca\.crt}' | base64 -d > "$ca"
kubectl --context "${OBS}" -n "${OBS_NAMESPACE}" create secret generic cfk8s-platform-ca \
  --from-file=ca.crt="$ca" --dry-run=client -o yaml | \
  kubectl --context "${OBS}" apply -f - >/dev/null
echo "   Secret cfk8s-platform-ca (nur ca.crt)"

echo ">> ScrapeConfig"
kubectl --context "${OBS}" apply -f observability/scrape-osb-broker.yaml >/dev/null
echo "   osb-broker -> cfk8s-control-plane:${BROKER_METRICS_NODEPORT}"
