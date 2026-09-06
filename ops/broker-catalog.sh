#!/usr/bin/env bash
# OSB-Katalog des Brokers direkt abfragen, ohne CF. Ändert nichts.
#
# Aufruf über `make broker-catalog`.
#
# Der Broker terminiert seit Phase 4.5 TLS, deshalb geht das nicht mehr mit
# einem curl-Pod und einer http-URL. Die CA steckt im Zertifikats-Secret, das
# cert-manager für den Broker erzeugt (bei einem CA-Issuer legt cert-manager
# ca.crt mit ins Secret) — also gibt es sie hier ohne zweite Quelle.
#
# Zugriff über Port-Forward statt aus einem Pod heraus: so kann curl vom Host
# aus mit --cacert gegen eine lokale Datei prüfen, ohne die CA erst in den
# Broker-Namespace zu spiegeln.
set -uo pipefail
cd "$(dirname "$0")/.." && set -a && . versions.env && set +a

CTX="kind-${KIND_CLUSTER_NAME}"
K="kubectl --context $CTX"

TMP=$(mktemp -d)
# Aufräumen auch bei Abbruch: sonst bleibt ein Port-Forward-Prozess stehen und
# der Port ist beim nächsten Lauf belegt.
cleanup() { [ -n "${PF_PID:-}" ] && kill "$PF_PID" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT

$K -n "$BROKER_NAMESPACE" get secret "$BROKER_FULLNAME-tls" -o jsonpath='{.data.ca\.crt}' \
  | base64 -d > "$TMP/ca.crt"
user=$($K -n "$BROKER_NAMESPACE" get secret "$BROKER_FULLNAME-auth" -o jsonpath='{.data.username}' | base64 -d)
pass=$($K -n "$BROKER_NAMESPACE" get secret "$BROKER_FULLNAME-auth" -o jsonpath='{.data.password}' | base64 -d)

$K -n "$BROKER_NAMESPACE" port-forward "svc/$BROKER_FULLNAME" 18443:443 >/dev/null 2>&1 &
PF_PID=$!
# Der Forward braucht einen Moment; ohne das Warten trifft der erste curl ins Leere.
for _ in $(seq 1 20); do
  curl -sf --cacert "$TMP/ca.crt" https://localhost:18443/healthz >/dev/null 2>&1 && break
  sleep 0.5
done

# --resolve statt -k: der Servername muss zum Zertifikat passen, sonst prüft
# der Aufruf nichts. Das Zertifikat trägt den Service-DNS-Namen, erreichbar ist
# der Broker aber über localhost.
curl -sS --cacert "$TMP/ca.crt" \
  --resolve "$BROKER_FULLNAME.$BROKER_NAMESPACE.svc.cluster.local:18443:127.0.0.1" \
  --user "$user:$pass" \
  -H 'X-Broker-API-Version: 2.17' \
  "https://$BROKER_FULLNAME.$BROKER_NAMESPACE.svc.cluster.local:18443/v2/catalog"
