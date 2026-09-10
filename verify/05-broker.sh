#!/usr/bin/env bash
# Der Broker: läuft er, ist er bei CF registriert, und deckt sich sein Katalog
# mit dem, was CF davon führt?
cd "$(dirname "$0")/.." && set -a && . versions.env && set +a && . verify/lib.sh
echo "Service Broker"
check "Broker-Pod verfügbar" "1" \
  "\$K -n $BROKER_NAMESPACE get deploy $BROKER_FULLNAME -o jsonpath='{.status.readyReplicas}'"

# Nicht CNPG hart nennen: die installierten Operatoren stehen in
# services/*/service.env, aus denen `make services` sie auch ausrollt. So
# wachsen die Akzeptanzkriterien mit, wenn ein Service dazukommt.
for f in services/*/service.env; do
  [ -f "$f" ] || continue
  ( set -a; . "$f"; set +a
    check "Operator verfügbar: $NAME $VERSION" "1" \
      "\$K -n $WAIT_NS get deploy $WAIT_DEPLOY -o jsonpath='{.status.readyReplicas}'"
    exit $FAILED ) || FAILED=1
done

# Er wird von `make instance-namespace` angelegt und von niemandem sonst. Fehlt
# er, scheitert jedes Provision - und zwar mit einer Meldung des Brokers, die
# zwar den Namen nennt, aber den Betreiber nicht auf sein eigenes Target stösst.
check "Namespace der Instanzen vorhanden" "$INSTANCE_NAMESPACE" \
  "\$K get namespace $INSTANCE_NAMESPACE -o jsonpath='{.metadata.name}'"

# Ohne diese Regel provisioniert und bindet der Broker fehlerfrei, und die
# Anwendung kommt trotzdem nicht an ihren Dienst - der Lebenszyklus ist gruen
# und der Zweck verfehlt (FINDINGS #32). Eine ASG kann sie nicht ersetzen:
# Cilium prueft gegen die Endpunkt-Identitaet, nicht gegen die Adresse.
check "Egress cf-workloads -> Instanzen erlaubt" "cf-apps-to-backing-services" \
  "\$K get ciliumclusterwidenetworkpolicy cf-apps-to-backing-services -o jsonpath='{.metadata.name}'"

check "Broker-Service auf 443" "443" \
  "\$K -n $BROKER_NAMESPACE get svc $BROKER_FULLNAME -o jsonpath='{.spec.ports[0].port}'"

# Der Broker terminiert selbst TLS. Ein registrierter Broker auf einer
# https-URL heißt: Cloud Foundry hat das Zertifikat akzeptiert - genau die
# Frage, die auf einem Zielsystem als "Vertrauensanker" offensteht.
brokers=$(cf service-brokers 2>/dev/null || true)
contains "Broker bei CF registriert" "$BROKER_NAME" "printf '%s' \"\$brokers\""
contains "Broker-URL ist https" "https://" "printf '%s' \"\$brokers\""

# Beide Richtungen des Katalogs. Die eine: was ausgerollt ist, muss CF kennen -
# hier fällt auf, wenn der Broker nach einer Definitions-Änderung nicht neu
# gestartet wurde. Die andere: was CF kennt, muss ausgerollt sein - Cloud
# Foundry entfernt Angebote NICHT, die aus dem Katalog verschwinden
# (cloud_controller_ng #1911), und zeigt dann Dienste, die es nicht gibt.
offerings=$(cf curl /v3/service_offerings 2>/dev/null | \
  python3 -c 'import json,sys
try: d=json.load(sys.stdin)
except Exception: raise SystemExit
print(" ".join(r["name"] for r in d.get("resources",[])))' 2>/dev/null)
for d in $BROKER_DEFINITIONS; do
  contains "$d im CF-Katalog" "$d" "printf '%s' \"$offerings\""
done
for o in $offerings; do
  case " $BROKER_DEFINITIONS " in
    *" $o "*) pass "$o im CF-Katalog ist ausgerollt" ;;
    *) fail "$o steht in CFs Katalog, wird aber nicht ausgerollt" \
            "aufräumen mit: make broker-catalog-prune APPLY=1" ;;
  esac
done

# Ohne Freigabe erscheint ein Angebot im Marketplace GAR NICHT - anders als bei
# Korifi, wo Pläne nach der Registrierung nur unsichtbar, aber vorhanden sind.
access=$(cf service-access 2>/dev/null || true)
for d in $BROKER_DEFINITIONS; do
  contains "$d ist freigegeben" "$d" "printf '%s' \"\$access\""
done
finish
