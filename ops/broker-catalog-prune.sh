#!/usr/bin/env bash
# Verwaiste Katalogeinträge in Cloud Foundry finden und entfernen.
#
# Aufruf über `make broker-catalog-prune` (meldet nur) bzw.
# `make broker-catalog-prune APPLY=1` (löscht).
#
# **Warum es das braucht.** Cloud Foundry hält eine eigene Kopie des
# OSB-Katalogs und frischt sie bei `cf update-service-broker` auf. Was aus dem
# Katalog VERSCHWINDET, entfernt es dabei nicht: das Angebot bleibt stehen, und
# `cf marketplace` zeigt Dienste an, die der Broker nicht mehr ausstellt. Ein
# Entwickler bestellt dann etwas, das es nicht gibt.
#
# Das ist keine Eigenheit dieser Installation, sondern eine bekannte Lücke des
# Cloud Controllers (cloud_controller_ng #1911). Sie trifft ein Zielsystem
# genauso und geht nicht von selbst weg.
#
# Maßgeblich ist der Katalog des Brokers, LIVE abgefragt — nicht `definitions/`
# und nicht `versions.env`. Nur der Katalog sagt, was der laufende Broker
# wirklich ausstellt.
set -uo pipefail
cd "$(dirname "$0")/.." && set -a && . versions.env && set +a

APPLY="${APPLY:-0}"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

if ! ops/broker-catalog.sh > "$TMP/catalog.json" 2>"$TMP/err"; then
  echo "FEHLER: der Katalog des Brokers ist nicht abfragbar - ohne ihn wird nichts geloescht" >&2
  cat "$TMP/err" >&2
  exit 1
fi
cf curl /v3/service_offerings?per_page=200 > "$TMP/offerings.json" 2>/dev/null || {
  echo "FEHLER: CF nicht erreichbar - vorher 'make cf-login'" >&2; exit 1; }
cf curl /v3/service_instances?per_page=200 > "$TMP/instances.json" 2>/dev/null || true

python3 - "$TMP" "$BROKER_NAME" <<'PY' > "$TMP/plan.txt"
import json, sys
tmp, brokername = sys.argv[1], sys.argv[2]

catalog = json.load(open(f"{tmp}/catalog.json"))
namen = {s.get("name") for s in catalog.get("services", [])}
# Ein leerer oder unlesbarer Katalog darf NICHTS loeschen: er saehe aus wie
# "der Broker stellt nichts mehr aus" und raeumte den ganzen Marketplace ab.
if not namen:
    print("FEHLER: der Katalog nennt kein einziges Angebot - das wird nicht als "
          "'alles verwaist' gelesen", file=sys.stderr)
    sys.exit(1)

offerings = json.load(open(f"{tmp}/offerings.json")).get("resources", [])
try:
    instanzen = json.load(open(f"{tmp}/instances.json")).get("resources", [])
except Exception:
    instanzen = []

# Nur die Angebote DIESES Brokers. Ein fremder Broker im selben CF geht uns
# nichts an - und sein Angebot als verwaist zu melden waere schlicht falsch.
eigene = [o for o in offerings
          if (o.get("relationships", {}).get("service_broker", {})
               .get("data", {}) or {}).get("guid")
          and o.get("name")]
namen_map = {o["guid"]: o["name"] for o in eigene}
verwaist = [o for o in eigene if o["name"] not in namen]

# Eine Instanz auf einem verwaisten Angebot ist kein Aufraeumfall, sondern ein
# Befund: sie laeuft auf etwas, das der Broker nicht mehr kennt.
blockiert = []
for i in instanzen:
    plan = (i.get("relationships", {}).get("service_plan", {}).get("data") or {})
    if plan.get("guid"):
        blockiert.append(i.get("name"))

if not verwaist:
    print("OK|keine verwaisten Katalogeintraege")
    sys.exit(0)
for o in verwaist:
    print(f"WAISE|Angebot {o['name']} ({o['guid']})")
if blockiert:
    print(f"HINWEIS|es gibt {len(blockiert)} Service-Instanz(en) - vor dem Loeschen pruefen, "
          f"ob eine davon auf einem verwaisten Angebot laeuft")
if sys.argv[1] and "1" == __import__("os").environ.get("APPLY", "0"):
    for o in verwaist:
        print(f"DEL|{o['name']}")
PY
rc=$?
[ $rc -ne 0 ] && { cat "$TMP/plan.txt"; exit $rc; }

geloescht=0
while IFS='|' read -r art a; do
  case "$art" in
    OK)      echo "   $a" ;;
    WAISE)   echo "   verwaist: $a" ;;
    HINWEIS) echo "   HINWEIS: $a" ;;
    DEL)     cf purge-service-offering "$a" -f >/dev/null && geloescht=$((geloescht+1)) ;;
  esac
done < "$TMP/plan.txt"

if [ "$APPLY" = "1" ]; then
  echo "   -> $geloescht Angebote entfernt"
elif grep -q '^WAISE' "$TMP/plan.txt"; then
  echo "   -> nur gemeldet. Entfernen mit: make broker-catalog-prune APPLY=1"
fi
