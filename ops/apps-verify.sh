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

# Ein versiegelter OpenBao LAEUFT - sein Pod ist da, er antwortet, und er gibt
# nichts heraus. Wer nur auf den Pod schaut, haelt ihn fuer gesund, waehrend
# jede Anwendung, die ein Geheimnis braucht, haengt. Deshalb wird der Zustand
# gefragt, nicht die Bereitschaft.
if $K -n "${OPENBAO_NAMESPACE}" get pod openbao-0 >/dev/null 2>&1; then
  check "OpenBao ist entsiegelt" "false" \
    "\$K -n $OPENBAO_NAMESPACE exec openbao-0 -- env BAO_ADDR=http://127.0.0.1:8200 bao status -format=json 2>/dev/null | python3 -c 'import json,sys; print(str(json.load(sys.stdin)[\"sealed\"]).lower())'"
  # Der Weg von AUSSEN. Ein OpenBao, der im Cluster laeuft, aber von dort nicht
  # erreichbar ist, laesst jeden Mandanten mit seiner Schreibberechtigung
  # allein - und das faellt erst auf, wenn einer sie benutzen will.
  # 200 heisst entsiegelt und bereit; 503 kaeme bei versiegelt, 000 bei keinem
  # Weg.
  check "OpenBao antwortet am Ingress (Port ${APPS_HTTP_PORT})" "200" \
    "curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://${OPENBAO_HOST}:${APPS_HTTP_PORT}/v1/sys/health"
  check "External Secrets Operator bereit" "1" \
    "\$K -n external-secrets get deploy external-secrets -o jsonpath='{.status.readyReplicas}'"
else
  skip "OpenBao" "nicht installiert - make apps-openbao"
fi

# Die Plattform darf hier nicht mitreden: ein Mandant im Anwendungs-Cluster
# hat mit cfk8s nichts zu tun. Faende sich hier der Broker, waere etwas
# verwechselt worden.
check "kein Broker in diesem Cluster" "0" \
  "\$K get ns -o name 2>/dev/null | grep -c osb-broker"

finish
