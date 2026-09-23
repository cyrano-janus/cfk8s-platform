#!/usr/bin/env bash
# Traegt der Anwendungs-Cluster? Geprueft wird der WEG, nicht der Pod-Zustand.
set -uo pipefail
cd "$(dirname "$0")/.." && set -a && . versions.env && set +a && . verify/lib.sh

CTX="kind-${APPS_CLUSTER_NAME}"
K="kubectl --context ${CTX}"

echo "Anwendungs-Cluster"

check "Knoten bereit" "True" \
  "\$K get nodes -o jsonpath='{.items[0].status.conditions[-1].type}{\"\\n\"}' | head -1 >/dev/null; \$K get nodes -o jsonpath='{.items[0].status.conditions[?(@.type==\"Ready\")].status}'"

check "Ingress-Controller bereit" "1" \
  "\$K -n ingress-nginx get deploy ingress-nginx-controller -o jsonpath='{.status.readyReplicas}'"

( set -a; . services/cloudnative-pg/service.env; set +a
  check "Datenbank-Operator bereit: $NAME $VERSION" "1" \
    "\$K -n $WAIT_NS get deploy $WAIT_DEPLOY -o jsonpath='{.status.readyReplicas}'"
  exit $FAILED ) || FAILED=1

# Ohne Standard-Klasse bleibt jeder Ingress ohne ausdrueckliche Angabe
# unbedient - lautlos: der Controller ignoriert ihn, und der Aufruf endet in
# einem 404, das wie ein Tippfehler in der Adresse aussieht. Genau so beim
# ersten Mandanten-Versuch gemessen.
check "nginx ist die Standard-Ingressklasse" "true" \
  "\$K get ingressclass nginx -o jsonpath='{.metadata.annotations.ingressclass\.kubernetes\.io/is-default-class}'"

# Der Ingress-Weg vom WIRT aus - nicht von innen. Ein Controller, der laeuft,
# aber dessen Port am Wirt nicht ankommt, sieht von innen gesund aus und ist
# fuer jeden Nutzer unerreichbar. 404 ist hier die richtige Antwort: der
# Controller lebt und kennt die angefragte Adresse nur nicht.
check "Ingress antwortet am Wirt (Port ${APPS_HTTP_PORT})" "404" \
  "curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://127.0.0.1:${APPS_HTTP_PORT}/"

# Die Plattform darf hier nicht mitreden: ein Mandant im Anwendungs-Cluster
# hat mit cfk8s nichts zu tun. Faende sich hier der Broker, waere etwas
# verwechselt worden.
check "kein Broker in diesem Cluster" "0" \
  "\$K get ns -o name 2>/dev/null | grep -c osb-broker"

finish
