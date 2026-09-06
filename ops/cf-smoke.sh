#!/usr/bin/env bash
# Der Lebenszyklus über die echte cf-CLI, mit Behauptungen statt Augenschein.
#
# Aufruf über `make cf-smoke`.
#
# WOZU, WENN ES SCHON `make conformance` GIBT
#
# `conformance` prüft den BROKER: es spricht direkt mit ihm und sagt, ob er
# OSB 2.17 einhält. Das hier prüft das ZUSAMMENSPIEL — ob Cloud Foundry die
# Zusagen des Brokers auch so liest, wie er sie meint. Das ist eine andere
# Frage, und keiner der beiden Läufe beantwortet die des anderen:
#
#   - Der Broker gibt `plan_updateable` je Plan aus. Ob der Cloud Controller
#     daraufhin einen Planwechsel selbst ablehnt, sieht nur, wer ihn fragt.
#   - Der Broker führt `maintenance_info`. Ob daraus ein `upgrade available`
#     wird, entscheidet die Plattform.
#   - Ein `cf update-service -c` erreicht den Broker überhaupt nur, wenn die
#     Plattform es weiterreicht.
#
# Diese drei waren auf der Vorgängerplattform nicht prüfbar, weil ihr
# OSB-Client kein PATCH kannte. Sie sind seit dem 2026-09-06 belegt — und ohne
# diesen Lauf wären sie es genau einmal gewesen.
#
# NICHT TEIL VON `make verify`
#
# `verify` ist read-only und läuft in Sekunden. Dieser Lauf legt eine echte
# Datenbank an und wieder ab; bei CloudNativePG sind das Minuten.
set -uo pipefail
cd "$(dirname "$0")/.." && set -a && . versions.env && set +a && . verify/lib.sh

INSTANZ="${CF_SMOKE_INSTANCE:-cf-smoke}"
ANGEBOT=cnpg-postgresql
PLAN=small
PLAN_ANDERER=large

# Aufräumen vorweg statt hinterher raten: ein abgebrochener Vorlauf hinterlässt
# sonst eine Instanz, und der nächste Lauf scheitert am Namen statt an der
# Sache.
vorbereiten() {
  cf delete-service-key "$INSTANZ" k1 -f >/dev/null 2>&1
  cf delete-service "$INSTANZ" -f --wait >/dev/null 2>&1
}
trap 'vorbereiten' EXIT

echo "Cloud-Foundry-Rauchtest (Minuten)"
if ! cf target >/dev/null 2>&1; then
  fail "keine CF-Sitzung" "vorher: make cf-login"
  finish
fi
vorbereiten

# --- Anlegen ------------------------------------------------------------
if cf create-service "$ANGEBOT" "$PLAN" "$INSTANZ" --wait >/dev/null 2>&1; then
  pass "cf create-service $ANGEBOT $PLAN"
else
  fail "cf create-service $ANGEBOT $PLAN" "$(cf service "$INSTANZ" 2>&1 | tail -3)"
  finish
fi

guid=$(cf service "$INSTANZ" --guid 2>/dev/null | tr -d '\r\n')
cr="osb-$guid"
check "die Ressource des Operators existiert wirklich" "$cr" \
  "\$K -n $INSTANCE_NAMESPACE get cluster $cr -o jsonpath='{.metadata.name}'"
check "und sie wird gesund" "True" \
  "\$K -n $INSTANCE_NAMESPACE get cluster $cr -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}'"

# --- Parameter-Update ---------------------------------------------------
# Der Fall, der über die Vorgängerplattform gar nicht beim Broker ankam: die
# CLI meldete Erfolg, ein PATCH gab es nie.
if cf update-service "$INSTANZ" -c '{"storageSize":"2Gi"}' --wait >/dev/null 2>&1; then
  pass "cf update-service -c wird angenommen"
else
  fail "cf update-service -c wird angenommen"
fi
# Angenommen heißt nicht angekommen. Geprüft wird die RESSOURCE, nicht die
# Antwort der CLI.
check "der Parameter erreicht den Operator wirklich" "2Gi" \
  "\$K -n $INSTANCE_NAMESPACE get cluster $cr -o jsonpath='{.spec.storage.size}'"

# --- Planwechsel --------------------------------------------------------
# Keine ausgelieferte Definition sagt ihn zu. Der Cloud Controller muss ihn
# deshalb SELBST ablehnen, ohne den Broker zu fragen.
ausgabe=$(cf update-service "$INSTANZ" -p "$PLAN_ANDERER" 2>&1)
if printf '%s' "$ausgabe" | grep -qi "does not support changing plans"; then
  pass "nicht zugesagter Planwechsel wird von CF abgelehnt"
elif printf '%s' "$ausgabe" | grep -qi "OK"; then
  fail "nicht zugesagter Planwechsel wird von CF abgelehnt" \
       "er wurde vollzogen - plan_updateable wird nicht gelesen"
else
  fail "nicht zugesagter Planwechsel wird von CF abgelehnt" "$(printf '%s' "$ausgabe" | tail -2)"
fi

# --- Upgrade ------------------------------------------------------------
# Nennt kein Plan einen Stand, gibt es nichts anzuzeigen und nichts
# auszulösen. Das ist konform und wird übersprungen, nicht bestanden.
stand=$(cf curl "/v3/service_plans?service_offering_names=$ANGEBOT" 2>/dev/null | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: raise SystemExit
print(" ".join((p.get("maintenance_info") or {}).get("version","") for p in d.get("resources",[])).strip())' 2>/dev/null)
if [ -z "$stand" ]; then
  skip=1
  printf "  \033[33mÜBERSPR\033[0m  Upgrade-Pfad: kein Plan von %s nennt einen Stand (maintenanceInfo)\n" "$ANGEBOT"
else
  verfuegbar=$(cf curl "/v3/service_instances/$guid" 2>/dev/null | \
    python3 -c 'import json,sys; print(json.load(sys.stdin).get("upgrade_available"))' 2>/dev/null)
  if [ "$verfuegbar" = "True" ]; then
    if cf upgrade-service "$INSTANZ" -f --wait >/dev/null 2>&1; then
      danach=$(cf curl "/v3/service_instances/$guid" 2>/dev/null | \
        python3 -c 'import json,sys; print(json.load(sys.stdin).get("upgrade_available"))' 2>/dev/null)
      [ "$danach" = "False" ] && pass "cf upgrade-service hebt den Stand der Instanz" \
        || fail "cf upgrade-service hebt den Stand der Instanz" "danach immer noch upgrade_available=$danach"
    else
      fail "cf upgrade-service hebt den Stand der Instanz" "der Aufruf schlug fehl"
    fi
  else
    pass "kein Upgrade ausstehend - die Instanz steht auf dem Stand ihres Plans"
  fi
fi

# --- Bind ---------------------------------------------------------------
if cf create-service-key "$INSTANZ" k1 --wait >/dev/null 2>&1; then
  pass "cf create-service-key"
  schluessel=$(cf service-key "$INSTANZ" k1 2>/dev/null)
  for feld in username password uri; do
    contains "die Credentials tragen $feld" "\"$feld\"" "printf '%s' \"\$schluessel\""
  done
else
  fail "cf create-service-key"
fi

# --- Abräumen -----------------------------------------------------------
cf delete-service-key "$INSTANZ" k1 -f >/dev/null 2>&1
if cf delete-service "$INSTANZ" -f --wait >/dev/null 2>&1; then
  pass "cf delete-service"
else
  fail "cf delete-service"
fi
# Der teure Fall: die Plattform meldet Erfolg, und im Cluster steht die
# Datenbank weiter. Genau das war FINDINGS #7.
check "keine Rückstände im Cluster" "" \
  "\$K -n $INSTANCE_NAMESPACE get cluster $cr -o jsonpath='{.metadata.name}' 2>/dev/null"

finish
