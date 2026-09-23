#!/usr/bin/env bash
# Dashboards aus observability/dashboards/ nach Grafana bringen.
#
# Ueber eine ConfigMap und nicht ueber die Oberflaeche: was jemand in Grafana
# zusammenklickt, liegt in dessen Datenbank und ist nach einem Neuaufbau weg.
# Das Sidecar von kube-prometheus-stack sucht ConfigMaps mit dem Label
# grafana_dashboard=1 (nachgesehen am Deployment, nicht geraten) und legt jede
# gefundene Datei in Grafana ab.
set -euo pipefail
cd "$(dirname "$0")/.." && set -a && . versions.env && set +a

OBS="kind-${OBS_CLUSTER_NAME}"

for f in observability/dashboards/*.json; do
  [ -e "$f" ] || { echo "   keine Dashboards gefunden"; exit 0; }
  name="grafana-dashboard-$(basename "$f" .json)"
  # Erst pruefen, dann ausliefern: ein kaputtes JSON wuerde das Sidecar still
  # ueberspringen, und in Grafana fehlte das Dashboard ohne jede Meldung.
  python3 -m json.tool "$f" >/dev/null || { echo "   FEHLER: $f ist kein gueltiges JSON"; exit 1; }
  kubectl --context "${OBS}" -n "${OBS_NAMESPACE}" create configmap "$name" \
    --from-file="$(basename "$f")=$f" --dry-run=client -o yaml | \
    kubectl --context "${OBS}" label -f - --local --dry-run=client -o yaml grafana_dashboard=1 | \
    kubectl --context "${OBS}" apply -f - >/dev/null
  echo "   $name"
done
echo "   Grafana holt sie binnen einer Minute; Ordner 'General' unter http://127.0.0.1:3000"
