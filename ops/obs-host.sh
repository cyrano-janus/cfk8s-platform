#!/usr/bin/env bash
# Die Messfuehler fuer den Wirt starten und bei Prometheus anmelden.
#
# Getrennt von obs-up, weil sie NICHT im Cluster laufen: sie messen den Laptop
# und brauchen dafuer Zugriff auf dessen Wurzelverzeichnis.
set -euo pipefail
cd "$(dirname "$0")/.." && set -a && . versions.env && set +a

OBS="kind-${OBS_CLUSTER_NAME}"

echo ">> node-exporter ${NODE_EXPORTER_VERSION} und cAdvisor ${CADVISOR_VERSION} auf dem Wirt"
# -p obs: ein eigener Compose-Projektname, damit diese beiden nicht mit dem
# nfs-server des CF-Upstream in einem Projekt landen.
docker compose -p obs -f observability/host/docker-compose.yml up -d --quiet-pull 2>&1 | tail -2

echo ">> ScrapeConfigs"
kubectl --context "${OBS}" apply -f observability/scrape-host.yaml >/dev/null
echo "   host-node      -> obs-node-exporter:9100"
echo "   host-container -> obs-cadvisor:8080"
