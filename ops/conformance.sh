#!/usr/bin/env bash
# Konformitaets-Gate direkt gegen den ausgerollten Broker, ohne Cloud Foundry.
#
# Aufruf über `make conformance`.
#
# WARUM DIREKT UND NICHT ÜBER DIE CF-CLI
#
# Weil ein Gate, das den Build blockiert, den BROKER prüfen muss und nicht das
# Zusammenspiel mit einer bestimmten Plattform. Über die CLI misst man beides
# zugleich und weiß bei Rot nicht, welches von beiden schuld ist.
#
# Dazu zwei Dinge, die die CLI grundsätzlich nicht zeigt. Cloud Foundry hält
# eine eigene Kopie des Katalogs; sie ist so alt wie das letzte
# `cf update-service-broker`, und `cf marketplace` zeigt sie, nicht den Broker.
# Und die Plattform fängt einiges ab, bevor der Broker gefragt wird — einen
# nicht zugesagten Planwechsel etwa lehnt der Cloud Controller selbst ab. Was
# der Broker in dem Fall täte, sagt nur ein direkter Aufruf.
#
# NICHT TEIL VON `make verify`
#
# `verify` ist read-only und läuft in Sekunden. Dieser Lauf legt eine echte
# Instanz an, bindet sie, aktualisiert sie und räumt wieder ab — bei
# CloudNativePG sind das Minuten. Ein Akzeptanztest, der Minuten kostet, wird
# nicht mehr aufgerufen, wenn er die schnellen mit ausbremst.
set -uo pipefail
cd "$(dirname "$0")/.." && set -a && . versions.env && set +a

CTX="kind-${KIND_CLUSTER_NAME}"
K="kubectl --context $CTX"
PORT="${CONFORMANCE_PORT:-18443}"

TMP=$(mktemp -d)
# Aufräumen auch bei Abbruch: sonst bleibt ein Port-Forward stehen und der Port
# ist beim nächsten Lauf belegt. Die Zugangsdaten liegen unter $TMP und
# verschwinden mit ihm.
cleanup() { [ -n "${PF_PID:-}" ] && kill "$PF_PID" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT

echo ">> baue osb-gate aus $BROKER_SRC"
( cd "$BROKER_SRC" && go build -o "$TMP/osb-gate" ./cmd/osb-gate/ ) || exit 1

$K -n "$BROKER_NAMESPACE" get secret "$BROKER_FULLNAME-tls" -o jsonpath='{.data.ca\.crt}' \
  | base64 -d > "$TMP/ca.crt"
user=$($K -n "$BROKER_NAMESPACE" get secret "$BROKER_FULLNAME-auth" -o jsonpath='{.data.username}' | base64 -d)
pass=$($K -n "$BROKER_NAMESPACE" get secret "$BROKER_FULLNAME-auth" -o jsonpath='{.data.password}' | base64 -d)

$K -n "$BROKER_NAMESPACE" port-forward "svc/$BROKER_FULLNAME" "$PORT:443" >/dev/null 2>&1 &
PF_PID=$!
for _ in $(seq 1 20); do
  curl -sf --cacert "$TMP/ca.crt" "https://localhost:$PORT/healthz" >/dev/null 2>&1 && break
  sleep 0.5
done

# Service und Plan werden vorgegeben, nicht geraten: welcher Eintrag im Katalog
# vorn steht, ist keine Zusage des Brokers, und ein Bericht über den falschen
# Service sagt nichts.
SVC="${CONFORMANCE_SERVICE_ID:-}"
PLAN="${CONFORMANCE_PLAN_ID:-}"
# Ein Parameter, den der Plan wirklich erlaubt. Ohne ihn sondiert die
# update-parameters-Pruefung mit einem erfundenen Schluessel, den der Broker zu
# Recht mit 400 ablehnt - die Pruefung sagt dann nichts und wird uebersprungen.
# Genau der Pfad soll hier aber belegt werden.
UPDATE_PARAM="${CONFORMANCE_UPDATE_PARAMETER:-}"
args=(--url "https://localhost:$PORT" --user "$user" --pass "$pass" --ca-cert "$TMP/ca.crt" --insecure)
[ -n "$SVC" ] && args+=(--service-id "$SVC")
[ -n "$PLAN" ] && args+=(--plan-id "$PLAN")
[ -n "$UPDATE_PARAM" ] && args+=(--update-parameter "$UPDATE_PARAM")

echo ">> osb-gate gegen den ausgerollten Broker"
"$TMP/osb-gate" "${args[@]}"
rc=$?

# Rückstände sind ein eigener Befund: ein Lauf, der aufgeräumt zu haben glaubt
# und es nicht hat, hinterlässt Datenbanken, für die niemand mehr zuständig ist.
echo
echo ">> Rückstände"
left_cr=$($K get clusters.postgresql.cnpg.io -A --no-headers 2>/dev/null | grep -c 'conformance' || true)
left_st=$($K get osbserviceinstances,osbservicebindings -A --no-headers 2>/dev/null | grep -c 'conformance' || true)
if [ "$left_cr" = "0" ] && [ "$left_st" = "0" ]; then
  printf "  \033[32mOK\033[0m    keine Rückstände\n"
else
  printf "  \033[31mFEHL\033[0m  %s Operator-Ressourcen, %s Broker-Datensätze übrig\n" "$left_cr" "$left_st"
  rc=1
fi

exit $rc
