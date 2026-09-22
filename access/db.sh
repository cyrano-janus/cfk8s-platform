#!/usr/bin/env bash
# Lebenszyklus einer Anwendungsdatenbank in APP_NAMESPACE - anlegen, ansehen,
# Zugangsdaten holen, vollständig entfernen.
#
#   ./access/db.sh up | status | creds | forward | events | down
#
# Nimmt von sich aus die Kubeconfig aus `make app-access`, also den
# eingeschränkten ServiceAccount und nicht den Administrator-Kontext. Wer einen
# anderen Zugang will, setzt KUBECONFIG vorher selbst.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."          # immer vom Repo-Wurzelverzeichnis aus

: "${KUBECONFIG:=$PWD/access/kubeconfig-app.yaml}"
export KUBECONFIG
DB="${DB:-meine-db}"                             # DB=andere-db ./access/db.sh up
MANIFEST="access/beispiel-datenbank.yaml"

if [ ! -f "$KUBECONFIG" ]; then
  echo "Keine Kubeconfig unter $KUBECONFIG - erst 'make app-access' laufen lassen." >&2
  exit 1
fi
NS=$(kubectl config view --minify -o jsonpath='{.contexts[0].context.namespace}')

case "${1:-help}" in

up)
  DB="$DB" envsubst < "$MANIFEST" | kubectl apply -f -
  echo
  echo ">> warte, bis die Datenbank bereit ist (erster Lauf dauert - das Image wird geladen)"
  # Auf den Zustand warten, nicht auf eine Zeitspanne: `kubectl wait` kennt die
  # Bedingung, die CNPG selbst setzt. Ohne --timeout bliebe es bei einem
  # Fehlschlag ewig stehen.
  if kubectl wait --for=condition=Ready "cluster/$DB" --timeout=300s 2>/dev/null; then
    echo
    "$0" creds
  else
    echo
    echo "Noch nicht bereit. Was fehlt, sagt meist:" >&2
    echo "  ./access/db.sh events" >&2
    exit 1
  fi
  ;;

status)
  kubectl get cluster "$DB" 2>/dev/null || { echo "Keine Datenbank '$DB' in $NS."; exit 1; }
  echo; kubectl get pods,pvc,svc -l "cnpg.io/cluster=$DB"
  ;;

creds)
  # CNPG legt die Zugangsdaten selbst ab - sie werden nirgends vergeben.
  echo "   URI (clusterintern):"
  echo -n "   "; kubectl get secret "$DB-app" -o jsonpath='{.data.uri}' | base64 -d; echo
  echo
  echo "   Von außerhalb des Clusters zuerst einen Tunnel öffnen:"
  echo "     ./access/db.sh forward"
  echo "   und dann im URI host:port durch 127.0.0.1:5432 ersetzen."
  ;;

forward)
  echo ">> $DB-rw auf 127.0.0.1:5432 - mit Strg-C beenden"
  kubectl port-forward "svc/$DB-rw" 5432:5432
  ;;

events)
  kubectl get events --sort-by=.lastTimestamp | tail -20
  echo; echo "=== Log des Datenbank-Pods:"
  kubectl logs -l "cnpg.io/cluster=$DB" --tail=20 2>/dev/null || echo "   (noch kein Pod)"
  ;;

down)
  # Löschen ist nicht rückgängig zu machen, und der Name der Datenbank steckt
  # in einer Variablen - deshalb wird gefragt, und zwar mit dem Zielnamen im
  # Text. Wer es in einem Skript braucht: FORCE=1 ./access/db.sh down
  echo "Löscht Datenbank '$DB' in Namespace '$NS' - mit allen Daten."
  if [ "${FORCE:-}" != "1" ]; then
    read -r -p "Wirklich? Dann den Namen '$DB' eintippen: " antwort
    [ "$antwort" = "$DB" ] || { echo "Abgebrochen."; exit 1; }
  fi

  kubectl delete cluster "$DB" --ignore-not-found --wait=true

  # Gegenprobe statt Vertrauen: CNPG hängt PVCs und Secrets als Eigentum an den
  # Cluster, die Garbage Collection räumt sie also normalerweise mit weg. Ob
  # das hier wirklich passiert ist, wird nachgesehen - ein übrig gebliebenes
  # PVC belegt Speicher und lässt ein späteres `up` auf alten Daten aufsetzen.
  echo
  echo ">> Rückstände?"
  reste=$(kubectl get pvc,secret,svc,pod -l "cnpg.io/cluster=$DB" \
            -o name --ignore-not-found 2>/dev/null || true)
  if [ -z "$reste" ]; then
    echo "   nichts übrig - vollständig entfernt."
  else
    echo "$reste" | sed 's/^/   /'
    echo ">> entferne sie"
    # shellcheck disable=SC2086
    kubectl delete $reste --ignore-not-found >/dev/null
    echo "   erledigt."
  fi

  # Nachgemessen in CNPG 1.30: von den vier Secrets trägt nur <cluster>-app das
  # Label cnpg.io/cluster, -ca, -server und -replication nicht. Die Suche oben
  # fände sie also nicht. Sie hängen zwar per ownerReference am Cluster und
  # verschwinden mit ihm - diese Liste ist die Absicherung für den Fall, dass
  # das Cluster-Objekt schon weg war und die Secrets verwaist zurückblieben.
  for s in "$DB-app" "$DB-ca" "$DB-server" "$DB-replication"; do
    kubectl delete secret "$s" --ignore-not-found >/dev/null 2>&1 || true
  done
  echo
  echo "Der Namespace '$NS' und der Zugang bleiben bestehen."
  echo "Zugang sperren: make app-access-revoke"
  ;;

*)
  sed -n '2,9p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'
  echo
  echo "  up       Datenbank anlegen und warten, bis sie bereit ist"
  echo "  status   Cluster, Pods, Volumes, Services"
  echo "  creds    Zugangsdaten aus dem Secret"
  echo "  forward  Tunnel auf 127.0.0.1:5432"
  echo "  events   Ereignisse und Pod-Log bei Problemen"
  echo "  down     Datenbank vollständig löschen (fragt nach)"
  echo
  echo "  DB=<name> davorsetzen für eine andere Datenbank als '$DB'."
  ;;
esac
