#!/usr/bin/env bash
# Misst Prometheus wirklich? Die Frage beantwortet nur Prometheus selbst.
#
# Ein laufender Pod ist kein Messwert: der Vorgaenger dieses Clusters lief 25
# Tage lang fehlerfrei und hatte NULL Ziele, weil ein ServiceMonitor auf einen
# Portnamen zeigte, den es nicht gab. Niemand hat es bemerkt, weil nichts rot
# war. Deshalb fragt dieser Lauf die Ziele ab und nicht die Pods.
set -uo pipefail
cd "$(dirname "$0")/.." && set -a && . versions.env && set +a && . verify/lib.sh

CTX="kind-${OBS_CLUSTER_NAME}"
K="kubectl --context ${CTX}"
PROM="http://127.0.0.1:9090"

echo "Observability"

check "Prometheus bereit" "1" \
  "\$K -n $OBS_NAMESPACE get statefulset -l app.kubernetes.io/name=prometheus -o jsonpath='{.items[0].status.readyReplicas}'"
check "Grafana bereit" "1" \
  "\$K -n $OBS_NAMESPACE get deploy -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].status.readyReplicas}'"

# Ohne Datentraeger ist die Aufbewahrungsfrist eine Zusage ohne Deckung.
check "Prometheus schreibt auf einen Datentraeger" "Bound" \
  "\$K -n $OBS_NAMESPACE get pvc -l app.kubernetes.io/name=prometheus -o jsonpath='{.items[0].status.phase}'"

check "Prometheus antwortet am Wirt" "200" \
  "curl -s -o /dev/null -w '%{http_code}' --max-time 10 $PROM/-/ready"

ziele=$(curl -s --max-time 10 "$PROM/api/v1/targets?state=active" 2>/dev/null)

check "mindestens ein Scrape-Ziel" "ja" \
  "printf '%s' \"\$ziele\" | grep -q '\"scrapeUrl\"' && echo ja || echo nein"

# Die eigentliche Frage. `health: up` heisst: verbunden, TLS geprueft, Antwort
# gelesen. Alles davor kann gruen sein und trotzdem nichts messen.
#
# ABER: `up` beweist nicht, dass der Weg JETZT offen ist. Prometheus haelt die
# Verbindung offen (keep-alive), und Conntrack leitet sie weiter, auch wenn der
# Knotenport laengst geloescht ist - gemessen 75 Sekunden lang, mit Scrapes von
# elf Millisekunden. Wer den Weg aendert und gleich danach hier Gruen sieht,
# hat nichts belegt; dafuer muss der Prometheus-Pod neu starten
# (observability/README.md).
check "Ziel osb-broker ist up" "up" \
  "printf '%s' \"\$ziele\" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(next((t[\"health\"] for t in d[\"data\"][\"activeTargets\"] if t[\"labels\"].get(\"component\")==\"osb-broker\"), \"kein Ziel\"))'"

# Ein up-Ziel ohne Messwerte waere ein leerer Endpunkt. Gefragt wird eine
# Reihe, die es nur beim Broker gibt.
check "Messwerte des Brokers liegen vor" "ja" \
  "curl -s --max-time 10 --get --data-urlencode 'query=osb_last_operation_state' $PROM/api/v1/query | grep -q '\"osb_last_operation_state\"' && echo ja || echo nein"

# Die Nachbarcluster. Vier Ziele im Anwendungs-Cluster: zwei am kubelet
# (Ressourcen und Knotenzustand), eines am Ingress, eines an
# kube-state-metrics. Faellt eines aus, fehlt im Dashboard eine Haelfte - und
# zwar ohne rote Meldung, denn ein Panel ohne Daten sieht aus wie ein Panel
# ohne Ereignisse.
check "Ziele im Anwendungs-Cluster: alle up" "4" \
  "curl -s --max-time 10 '$PROM/api/v1/targets?state=active' | python3 -c 'import json,sys; d=json.load(sys.stdin); print(sum(1 for t in d[\"data\"][\"activeTargets\"] if t[\"labels\"].get(\"cluster\")==\"apps\" and t[\"health\"]==\"up\"))'"

finish
