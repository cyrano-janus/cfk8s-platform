#!/usr/bin/env bash
# Baut eine eigenständige Kubeconfig für den ServiceAccount aus
# access/app-access.yaml und prüft anschließend nach, dass sie genau so viel
# kann wie vorgesehen - und nicht mehr.
#
# Aufgerufen von `make app-access`. Erwartet CTX, APP_NAMESPACE,
# APP_SERVICE_ACCOUNT und APP_KUBECONFIG aus der Umgebung.
set -euo pipefail

KUBECTL="kubectl --context ${CTX}"
SECRET="${APP_SERVICE_ACCOUNT}-token"

# ---------------------------------------------------------------- Token holen
# Das Token entsteht nicht im selben Moment wie das Secret - der
# TokenController füllt es nach. Ohne diese Schleife liefert der erste Lauf
# nach `kubectl apply` eine Kubeconfig mit leerem Token, und der Fehler fällt
# erst beim ersten Zugriff der App auf.
TOKEN=""
for _ in $(seq 1 30); do
  TOKEN=$($KUBECTL -n "${APP_NAMESPACE}" get secret "${SECRET}" \
            -o jsonpath='{.data.token}' 2>/dev/null | base64 -d 2>/dev/null || true)
  [ -n "${TOKEN}" ] && break
  sleep 1
done

if [ -z "${TOKEN}" ]; then
  # Fallback: manche Cluster stellen langlebige Token-Secrets nicht mehr aus.
  # Dann ein kurzlebiges Token - die Kubeconfig läuft dann ab und muss über
  # `make app-access` erneuert werden. Das Skript sagt es unten.
  echo "   Hinweis: kein Token im Secret - weiche auf ein befristetes aus" >&2
  TOKEN=$($KUBECTL -n "${APP_NAMESPACE}" create token "${APP_SERVICE_ACCOUNT}" --duration=8760h 2>/dev/null \
          || $KUBECTL -n "${APP_NAMESPACE}" create token "${APP_SERVICE_ACCOUNT}")
  BEFRISTET=1
fi

# ------------------------------------------------------- Adresse und Anker
# Beides steht in der Kubeconfig des Betreibers. Der Port ist NICHT stabil:
# kind vergibt ihn beim Anlegen des Clusters neu. Nach jedem `make cf-up` muss
# diese Datei deshalb neu erzeugt werden.
SERVER=$($KUBECTL config view --minify -o jsonpath='{.clusters[0].cluster.server}')
CA=$($KUBECTL config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')

umask 077
cat > "${APP_KUBECONFIG}" <<EOF
# Erzeugt von \`make app-access\` - nicht von Hand ändern, nicht committen.
#
# Gültig NUR auf diesem Rechner: ${SERVER} ist an das Loopback-Interface
# gebunden. Aus einem Container ohne Host-Netz oder von einem anderen Rechner
# ist diese Adresse nicht erreichbar.
#
# Der Port wechselt bei jedem Neuaufbau des Clusters. Danach: make app-access
apiVersion: v1
kind: Config
current-context: ${APP_SERVICE_ACCOUNT}
clusters:
  - name: ${CTX}
    cluster:
      server: ${SERVER}
      certificate-authority-data: ${CA}
contexts:
  - name: ${APP_SERVICE_ACCOUNT}
    context:
      cluster: ${CTX}
      namespace: ${APP_NAMESPACE}
      user: ${APP_SERVICE_ACCOUNT}
users:
  - name: ${APP_SERVICE_ACCOUNT}
    user:
      token: ${TOKEN}
EOF
chmod 600 "${APP_KUBECONFIG}"
echo "   Kubeconfig: ${APP_KUBECONFIG}"
[ -n "${BEFRISTET:-}" ] && echo "   ACHTUNG: befristetes Token - bei Ablauf 'make app-access' erneut"

# ------------------------------------------------------------- Gegenprobe
# Eine Rechtevergabe ohne Gegenprobe ist eine Vermutung. Geprüft wird beides:
# dass das Erlaubte geht, UND dass das Verbotene scheitert. Nur der zweite Teil
# belegt, dass die Role wirklich am Namespace endet.
echo "   Gegenprobe:"
ERR=0
darf() {  # darf <erwartet: ja|nein> <beschreibung> <kubectl-auth-can-i-argumente...>
  local erwartet=$1 text=$2; shift 2
  local ist
  ist=$(KUBECONFIG="${APP_KUBECONFIG}" kubectl auth can-i "$@" 2>/dev/null || true)
  [ "$ist" = "yes" ] && ist=ja || ist=nein
  if [ "$ist" = "$erwartet" ]; then
    printf '     %-4s %s\n' "ok" "$text ($ist)"
  else
    printf '     %-4s %s: erwartet %s, ist %s\n' "FEHL" "$text" "$erwartet" "$ist"; ERR=1
  fi
}

darf ja   "Datenbank anlegen in ${APP_NAMESPACE}"    create clusters.postgresql.cnpg.io -n "${APP_NAMESPACE}"
darf ja   "DB-Passwort lesen in ${APP_NAMESPACE}"    get    secrets                     -n "${APP_NAMESPACE}"
darf ja   "App ausrollen in ${APP_NAMESPACE}"        create deployments.apps            -n "${APP_NAMESPACE}"
darf nein "Secrets in ${CF_SYSTEM_NAMESPACE} lesen"  get    secrets                     -n "${CF_SYSTEM_NAMESPACE}"
darf nein "Broker-Instanzen anfassen"                delete clusters.postgresql.cnpg.io -n "${INSTANCE_NAMESPACE}"
darf nein "Knoten sehen"                             list   nodes
darf nein "Namespaces anlegen"                       create namespaces

exit $ERR
