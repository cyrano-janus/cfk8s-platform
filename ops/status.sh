#!/usr/bin/env bash
# Ist-Zustand der Plattform auf einen Blick. Ändert nichts.
set -uo pipefail
cd "$(dirname "$0")/.." && set -a && . versions.env && set +a
CTX="kind-${KIND_CLUSTER_NAME}"
K="kubectl --context $CTX"

echo "Cluster"
if ! $K get nodes >/dev/null 2>&1; then
  echo "   nicht erreichbar - angehalten? 'make start'"
  exit 1
fi
$K get nodes --no-headers | awk '{printf "   %-28s %s\n", $1, $2}'

echo "Cloud Foundry ($CF_SYSTEM_NAMESPACE)"
nicht_bereit=$($K -n "$CF_SYSTEM_NAMESPACE" get pods --no-headers 2>/dev/null | grep -vcE ' (Running|Completed) ')
gesamt=$($K -n "$CF_SYSTEM_NAMESPACE" get pods --no-headers 2>/dev/null | wc -l)
echo "   $((gesamt - nicht_bereit))/$gesamt Pods laufen"
[ "$nicht_bereit" -gt 0 ] && $K -n "$CF_SYSTEM_NAMESPACE" get pods --no-headers | grep -vE ' (Running|Completed) ' | awk '{printf "   %-40s %s\n", $1, $3}'

echo "Broker"
$K -n "$BROKER_NAMESPACE" get deploy "$BROKER_FULLNAME" --no-headers 2>/dev/null \
  | awk '{printf "   %-28s %s\n", $1, $2}' || echo "   nicht ausgerollt"

echo "Registrierung"
cf service-brokers 2>/dev/null | tail -n +3 | awk '{printf "   %-20s %s\n", $1, $2}' || echo "   CF nicht angemeldet - 'make cf-login'"

echo "Service-Instanzen"
n=$(cf curl /v3/service_instances?per_page=200 2>/dev/null | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("resources",[])))' 2>/dev/null || echo "?")
echo "   $n"
