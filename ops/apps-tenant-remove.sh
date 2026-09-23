#!/usr/bin/env bash
# Einen Mandanten samt allem entfernen, was er betreibt.
#
# Das Gegenstueck zu apps-tenant.sh. Es fragt nach, weil mit dem Namespace
# auch Datenbanken und deren Datentraeger verschwinden - und die gehoeren
# nicht uns.
set -euo pipefail
cd "$(dirname "$0")/.." && set -a && . versions.env && set +a

name="${1:-}"
[ -n "$name" ] || { echo "   Aufruf: make apps-mandant-weg NAME=<name>"; exit 1; }

CTX="kind-${APPS_CLUSTER_NAME}"
K="kubectl --context ${CTX}"

$K get namespace "$name" >/dev/null 2>&1 || { echo "   Mandant $name existiert nicht"; exit 0; }

echo "   Im Namespace $name liegen:"
$K -n "$name" get deploy,sts,svc,ingress,cluster.postgresql.cnpg.io,pvc --no-headers 2>/dev/null | sed 's/^/     /' || true
printf '   Alles davon loeschen, Datenbanken eingeschlossen? [j/N] '
read -r a; [ "$a" = "j" ] || { echo "   abgebrochen"; exit 1; }

# Erst der Geheimnisspeicher, dann der Namespace: Mit dem Namespace
# verschwindet der SecretStore ohnehin, aber Policy und Anmelderolle leben in
# OpenBao weiter. Eine Rolle ohne Namespace ist harmlos - eine Rolle, die
# wieder auflebt, wenn jemand denselben Namen neu vergibt, ist es nicht.
NS_BAO="${OPENBAO_NAMESPACE}"
if $K -n "${NS_BAO}" get pod openbao-0 >/dev/null 2>&1 \
   && $K -n "${NS_BAO}" exec openbao-0 -- env BAO_ADDR=http://127.0.0.1:8200 \
        bao status -format=json 2>/dev/null | grep -q '"sealed": *false'; then
  tokbao=$(python3 -c "import json;print(json.load(open('${OPENBAO_INIT_FILE}'))['root_token'])")
  bao_tok() { $K -n "${NS_BAO}" exec openbao-0 -- \
                env BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN="$tokbao" "${@}"; }
  bao_tok bao delete "auth/kubernetes/role/${name}" >/dev/null 2>&1 || true
  bao_tok bao policy delete "mandant-${name}" >/dev/null 2>&1 || true

  # KV Version 2 loescht NICHT rekursiv: `kv metadata delete mandanten/<name>`
  # nimmt nur diesen einen Schluessel mit, waehrend alles darunter stehen
  # bleibt. Gemessen beim ersten Abraeumen - Policy und Rolle waren weg, der
  # Pfad stand weiter in `bao kv list`. Das ist keine Kosmetik: Wer denselben
  # Mandantennamen neu vergibt, erbt die Geheimnisse seines Vorgaengers.
  for k in $(bao_tok bao kv list -format=json "mandanten/${name}" 2>/dev/null \
             | python3 -c 'import json,sys
try:
    [print(x) for x in json.load(sys.stdin)]
except Exception:
    pass' 2>/dev/null); do
    bao_tok bao kv metadata delete "mandanten/${name}/${k%/}" >/dev/null 2>&1 || true
  done
  bao_tok bao kv metadata delete "mandanten/${name}" >/dev/null 2>&1 || true
  echo "   Pfade, Policy und Anmelderolle in OpenBao entfernt"
fi

$K delete namespace "$name" --wait=true >/dev/null
rm -f "apps/kubeconfig-${name}.yaml"
echo "   $name entfernt, Kubeconfig geloescht"
