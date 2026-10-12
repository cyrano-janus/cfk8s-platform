#!/usr/bin/env bash
# OpenBao und der External Secrets Operator im Anwendungs-Cluster.
#
# Drei Schritte, die zusammengehoeren: der Speicher wird installiert, EINMALIG
# initialisiert (dabei entstehen die Entsiegelungsschluessel) und dann
# eingerichtet - Kubernetes-Anmeldung und ein KV-Speicher fuer die Mandanten.
#
# Idempotent: Ein zweiter Lauf initialisiert nicht neu (das wuerde den
# vorhandenen Speicher unbrauchbar machen), sondern entsiegelt nur und setzt
# die Einrichtung erneut - was folgenlos ist.
set -euo pipefail
cd "$(dirname "$0")/.." && set -a && . versions.env && set +a

CTX="kind-${APPS_CLUSTER_NAME}"
K="kubectl --context ${CTX}"
H="helm --kube-context ${CTX}"
NS="${OPENBAO_NAMESPACE}"
POD="openbao-0"

# Jeder bao-Aufruf laeuft IM Pod. Ein Client auf dem Wirt haette den Vorteil
# kuerzerer Zeilen und den Nachteil, dass er erst installiert werden muesste -
# und dass die Anleitung dann von einer Version abhinge, die hier niemand
# pinnt.
bao() { $K -n "${NS}" exec "${POD}" -- env BAO_ADDR=http://127.0.0.1:8200 "${@}"; }
bao_tok() {
  local t; t=$(python3 -c "import json;print(json.load(open('${OPENBAO_INIT_FILE}'))['root_token'])")
  $K -n "${NS}" exec "${POD}" -- env BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN="$t" "${@}"
}

echo ">> OpenBao ${OPENBAO_CHART_VERSION}"
helm repo add openbao "${OPENBAO_REPO}" >/dev/null 2>&1 || true
helm repo update openbao >/dev/null
# KEIN --wait: der Pod wird nie bereit, solange OpenBao versiegelt ist. Seine
# Bereitschaftspruefung meldet genau das - und ein Helm, das darauf wartet,
# liefe in jedem frischen Aufbau in den Timeout.
#
# Das Image wird hier ausdruecklich gesetzt und kommt nicht aus dem Chart.
# Das ist keine Stilfrage: das Chart dieser Linie traegt 2.6.3, und drei
# Luecken schliessen erst mit 2.6.4. In voller Laenge steht der Grund bei
# OPENBAO_VERSION in versions.env.
$H upgrade --install openbao openbao/openbao \
  --version "${OPENBAO_CHART_VERSION}" \
  --set server.image.tag="${OPENBAO_VERSION}" \
  --namespace "${NS}" --create-namespace \
  -f apps/openbao-values.yaml >/dev/null
echo "   ausgerollt (der Pod bleibt unbereit, solange versiegelt - das ist richtig so)"

# Das Chart setzt `updateStrategy: OnDelete`. Der StatefulSet-Controller
# ersetzt den Pod dann NICHT von selbst - ein Versionswechsel landet im
# Manifest und bleibt dort liegen. Das ist Absicht des Charts: ein
# Geheimnisspeicher soll nicht unbeaufsichtigt durchrollen, weil er nach jedem
# Neustart versiegelt ist und von Hand geoeffnet werden muss.
#
# Hier ist das Gegenteil richtig: direkt unter dieser Zeile wird ohnehin
# gewartet und entsiegelt. Ohne diesen Schritt meldet das Target eine neue
# Version, waehrend die alte weiterlaeuft - ein Sicherheitsupdate, das nur auf
# dem Papier steht und beim Nachsehen keinen Verdacht erregt.
#
# Verglichen wird die Revision des LAUFENDEN Pods mit der, die das StatefulSet
# ausrollen will. Nicht `currentRevision` gegen `updateRevision`: unter
# OnDelete fuehrt der Controller `currentRevision` nie nach, die beiden stehen
# also dauerhaft auseinander - ein Target, das daran haengt, loescht den Pod
# bei JEDEM Lauf und ist nicht idempotent (Regel 7).
POD_REV=$($K -n "${NS}" get pod "${POD}" -o jsonpath='{.metadata.labels.controller-revision-hash}' 2>/dev/null || true)
UPD=$($K -n "${NS}" get sts openbao -o jsonpath='{.status.updateRevision}')
if [ -n "${POD_REV}" ] && [ "${POD_REV}" != "${UPD}" ]; then
  echo ">> ausstehende Revision durchsetzen (OnDelete: der Pod geht nicht von allein)"
  # Die Daten liegen auf dem PVC, nicht im Pod - das Loeschen kostet sie nicht.
  $K -n "${NS}" delete pod "${POD}" --wait=true >/dev/null
  echo "   ${POD} neu, versiegelt - wird gleich geoeffnet"
fi

echo ">> warte, bis der Prozess antwortet"
for i in $(seq 1 60); do
  # `bao status` gibt 2 zurueck, wenn versiegelt, und 0 wenn offen. Beides
  # heisst: er antwortet. Nur ein Fehler beim Aufruf selbst heisst "noch nicht".
  if $K -n "${NS}" exec "${POD}" -- env BAO_ADDR=http://127.0.0.1:8200 bao status >/dev/null 2>&1 \
     || [ $? = 2 ]; then break; fi
  [ "$i" = 60 ] && { echo "   OpenBao antwortet nach 60 Versuchen nicht"; exit 1; }
  sleep 2
done
echo "   antwortet"

if [ -f "${OPENBAO_INIT_FILE}" ]; then
  echo ">> bereits initialisiert (${OPENBAO_INIT_FILE})"
else
  echo ">> einmalige Initialisierung"
  # Ein Schluessel, ein Anteil. In einem echten Betrieb waeren es fuenf, von
  # denen drei zusammenkommen muessen, verteilt auf verschiedene Personen -
  # genau das ist der Sinn des Verfahrens. Hier saessen alle Anteile ohnehin
  # in derselben Datei auf demselben Rechner; mehrere waeren eine Verkleidung.
  bao bao operator init -key-shares=1 -key-threshold=1 -format=json > "${OPENBAO_INIT_FILE}"
  chmod 600 "${OPENBAO_INIT_FILE}"
  echo "   Schluessel in ${OPENBAO_INIT_FILE} (600, nicht im Repo)"
fi

ops/apps-openbao-unseal.sh

echo ">> Kubernetes-Anmeldung"
# Damit sich eine Anwendung mit ihrem ServiceAccount-Token anmelden kann.
# OpenBao prueft es gegen die TokenReview-API DIESES Clusters - deshalb muss er
# hier stehen und nicht im Observability-Cluster.
bao_tok bao auth enable kubernetes 2>/dev/null || echo "   war schon aktiv"
bao_tok sh -c 'bao write auth/kubernetes/config \
  kubernetes_host="https://$KUBERNETES_PORT_443_TCP_ADDR:443"' >/dev/null
echo "   eingerichtet"

echo ">> KV-Speicher fuer die Mandanten"
bao_tok bao secrets enable -path=mandanten -version=2 kv 2>/dev/null || echo "   war schon da"
echo "   unter mandanten/<name>/"

echo ">> External Secrets Operator ${ESO_CHART_VERSION}"
helm repo add external-secrets "${ESO_REPO}" >/dev/null 2>&1 || true
helm repo update external-secrets >/dev/null
$H upgrade --install external-secrets external-secrets/external-secrets \
  --version "${ESO_CHART_VERSION}" \
  --namespace external-secrets --create-namespace \
  --set installCRDs=true \
  --wait --timeout 5m >/dev/null
echo "   bereit"

echo
echo "   Ein Mandant bekommt seinen Pfad mit: make apps-mandant NAME=<name>"
