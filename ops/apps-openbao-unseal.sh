#!/usr/bin/env bash
# OpenBao entsiegeln.
#
# Nach jedem Start des Clusters noetig - und das heisst auf diesem Rechner:
# jeden Morgen. Ein versiegelter OpenBao laeuft, antwortet und gibt NICHTS
# heraus; sein Pod meldet sich als nicht bereit, und jede Anwendung, die ein
# Geheimnis braucht, haengt.
#
# Dass ein Befehl genuegt, ist eine Bequemlichkeit dieses Entwicklungssystems.
# Im Betrieb kommen die Anteile von verschiedenen Personen oder aus einem
# zweiten Speicher - siehe apps/GEHEIMNISSE.md.
set -euo pipefail
cd "$(dirname "$0")/.." && set -a && . versions.env && set +a

CTX="kind-${APPS_CLUSTER_NAME}"
K="kubectl --context ${CTX}"
NS="${OPENBAO_NAMESPACE}"
POD="openbao-0"

[ -f "${OPENBAO_INIT_FILE}" ] || {
  echo "   ${OPENBAO_INIT_FILE} fehlt - wurde OpenBao je initialisiert?"
  echo "   make apps-openbao legt ihn an."
  exit 1
}

status=$($K -n "${NS}" exec "${POD}" -- env BAO_ADDR=http://127.0.0.1:8200 \
         bao status -format=json 2>/dev/null || true)
if printf '%s' "$status" | grep -q '"sealed": *false'; then
  echo "   bereits entsiegelt"
  exit 0
fi

key=$(python3 -c "import json;print(json.load(open('${OPENBAO_INIT_FILE}'))['unseal_keys_b64'][0])")
$K -n "${NS}" exec "${POD}" -- env BAO_ADDR=http://127.0.0.1:8200 \
  bao operator unseal "$key" >/dev/null
echo "   entsiegelt"

# Gegenprobe im Target, nicht in einer Erinnerung: ohne sie meldet der Lauf
# Erfolg, sobald der Befehl durchlief - ob der Speicher wirklich offen ist,
# haette dann niemand geprueft.
$K -n "${NS}" exec "${POD}" -- env BAO_ADDR=http://127.0.0.1:8200 \
  bao status -format=json 2>/dev/null | grep -q '"sealed": *false' \
  && echo "   Gegenprobe: Sealed = false" \
  || { echo "   Gegenprobe FEHLGESCHLAGEN - er ist weiter versiegelt"; exit 1; }
