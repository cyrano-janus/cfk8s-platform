#!/usr/bin/env bash
# Einen Wert in den Pfad eines Mandanten legen.
#
# Aufruf: make apps-geheimnis NAME=anna PFAD=dienst-x FELD=api_key [WERT=...]
#
# Ohne WERT wird der Wert von der Tastatur gelesen, ohne ihn anzuzeigen. Das
# ist der bessere Weg: Was auf der Befehlszeile steht, landet in der
# Shell-Historie und in der Prozessliste - ein Geheimnis, das man im Klartext
# eintippt, steht danach in ~/.bash_history.
set -euo pipefail
cd "$(dirname "$0")/.." && set -a && . versions.env && set +a

name="${NAME:-}"; pfad="${PFAD:-}"; feld="${FELD:-}"; wert="${WERT:-}"
[ -n "$name" ] && [ -n "$pfad" ] && [ -n "$feld" ] || {
  echo "   Aufruf: make apps-geheimnis NAME=<mandant> PFAD=<pfad> FELD=<feld> [WERT=<wert>]"
  echo "   Beispiel: make apps-geheimnis NAME=anna PFAD=dienst-x FELD=api_key"
  exit 1
}
# Ein Feld mit Bindestrich landet im Secret, ist als Umgebungsvariable aber
# nicht lesbar - $api-key gibt es in keiner Shell. Lieber hier abfangen als
# spaeter im Container suchen lassen.
printf '%s' "$feld" | grep -Eq '^[A-Za-z_][A-Za-z0-9_]*$' || {
  echo "   '$feld' taugt nicht als Feldname: Buchstaben, Ziffern und Unterstriche,"
  echo "   Anfang ein Buchstabe. Ein Bindestrich waere im Container nicht lesbar."
  exit 1
}

CTX="kind-${APPS_CLUSTER_NAME}"
K="kubectl --context ${CTX}"
NS="${OPENBAO_NAMESPACE}"

$K -n "$name" get serviceaccount "${name}-deployer" >/dev/null 2>&1 || {
  echo "   Mandant '$name' existiert nicht - make apps-mandant NAME=$name"; exit 1; }

if [ -z "$wert" ]; then
  printf '   Wert fuer %s/%s (bleibt unsichtbar): ' "$pfad" "$feld"
  read -rs wert; echo
  [ -n "$wert" ] || { echo "   leer, abgebrochen"; exit 1; }
fi

tok=$(python3 -c "import json;print(json.load(open('${OPENBAO_INIT_FILE}'))['root_token'])")
# `kv patch` statt `kv put`: put ersetzt den gesamten Pfad, und wer ein zweites
# Feld ablegt, loescht damit das erste. Das faellt erst auf, wenn eine
# Anwendung ihren Schluessel verliert.
$K -n "${NS}" exec openbao-0 -- env BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN="$tok" \
  bao kv patch "mandanten/${name}/${pfad}" "${feld}=${wert}" >/dev/null 2>&1 \
  || $K -n "${NS}" exec openbao-0 -- env BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN="$tok" \
       bao kv put "mandanten/${name}/${pfad}" "${feld}=${wert}" >/dev/null
echo "   abgelegt: mandanten/${name}/${pfad} · Feld ${feld}"
echo
echo "   Der Mandant holt ihn mit einem ExternalSecret auf key: ${name}/${pfad}"
echo "   (apps/BEFEHLE.md, Abschnitt 7)"
