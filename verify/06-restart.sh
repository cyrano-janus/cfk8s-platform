#!/usr/bin/env bash
# Nach `make start`: ist wirklich alles wiedergekommen?
#
# **Warum das eine eigene Datei ist.** Ein angehaltener und wieder gestarteter
# Cluster sieht auf den ersten Blick aus wie ein laufender - die Knoten sind da,
# die Pods stehen. Was danach fehlt, merkt man erst beim nächsten Handgriff:
# eine Registrierung, die weg ist, ein Namespace, den niemand mehr anlegt, ein
# Zustand, den der Broker nicht mehr findet.
#
# Der Rückfallweg ist teuer. Kommt der Cluster nicht sauber hoch, kostet der
# Wiederaufbau nicht die neun Minuten von `make cf-up`, sondern dazu Buildpacks,
# Broker, Registrierung und Security Groups. Diese Prüfung sagt in Sekunden, ob
# das nötig ist.
cd "$(dirname "$0")/.." && set -a && . versions.env && set +a && . verify/lib.sh
echo "Nach dem Neustart"

check "Knoten wieder bereit" "0" \
  "\$K get nodes --no-headers | grep -vc ' Ready '"

# Die Komponente, an der alles haengt. Kommt sie nicht hoch, ist der Rest egal.
check "Cloud Controller wieder da" "0" \
  "\$K -n $CF_SYSTEM_NAMESPACE get deploy cloud-controller -o jsonpath='{.status.readyReplicas}' | grep -q '^[1-9]' && echo 0 || echo 1"

check "Broker wieder da" "1" \
  "\$K -n $BROKER_NAMESPACE get deploy $BROKER_FULLNAME -o jsonpath='{.status.readyReplicas}'"

# Der Namespace der Instanzen wird von `make instance-namespace` angelegt und
# von niemandem sonst - er ueberlebt einen Neustart, aber nicht ein `make down`.
check "Instanz-Namespace noch da" "$INSTANCE_NAMESPACE" \
  "\$K get namespace $INSTANCE_NAMESPACE -o jsonpath='{.metadata.name}'"

# Der Zustand des Brokers liegt in eigenen CRs. Sie zu verlieren hiesse: die
# Plattform kennt Instanzen, der Broker nicht mehr.
check "State-CRDs etabliert" "0" \
  "\$K get crd osbserviceinstances.broker.osb.io osbservicebindings.broker.osb.io >/dev/null 2>&1 && echo 0 || echo 1"

# Ab hier braucht es eine CF-Sitzung. Fehlt sie, ist das kein Fehlschlag des
# Neustarts - dann ist nur der Token abgelaufen.
if cf target >/dev/null 2>&1; then
  contains "Broker noch registriert" "$BROKER_NAME" "cf service-brokers 2>/dev/null"
  contains "Security Group noch gebunden" "backing-services" "cf running-security-groups 2>/dev/null"
else
  printf "  \033[33mÜBERSPR\033[0m  CF-Sitzung abgelaufen - 'make cf-login', dann erneut\n"
fi
finish
