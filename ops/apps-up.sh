#!/usr/bin/env bash
# Der Anwendungs-Cluster: kind-Cluster, Ingress, Datenbank-Operator.
# Idempotent - ein zweiter Lauf aendert nichts.
set -euo pipefail
cd "$(dirname "$0")/.." && set -a && . versions.env && set +a

CTX="kind-${APPS_CLUSTER_NAME}"
K="kubectl --context ${CTX}"
H="helm --kube-context ${CTX}"

if kind get clusters 2>/dev/null | grep -qx "${APPS_CLUSTER_NAME}"; then
  echo "   Cluster ${APPS_CLUSTER_NAME} existiert"
else
  echo ">> kind-Cluster ${APPS_CLUSTER_NAME}"
  kind create cluster --name "${APPS_CLUSTER_NAME}" --config apps/kind.yaml
fi

echo ">> ingress-nginx ${INGRESS_NGINX_VERSION}"
helm repo add ingress-nginx "${INGRESS_NGINX_REPO}" >/dev/null 2>&1 || true
helm repo update ingress-nginx >/dev/null
$H upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --version "${INGRESS_NGINX_VERSION}" \
  --namespace ingress-nginx --create-namespace \
  -f apps/ingress-values.yaml \
  --wait --timeout 5m >/dev/null
echo "   erreichbar am Wirt auf ${APPS_HTTP_PORT} (http) und ${APPS_HTTPS_PORT} (https)"

# Der Datenbank-Operator kommt aus DERSELBEN Beschreibung wie auf der
# Plattform - services/cloudnative-pg/service.env nennt URL und Wartepunkt.
# Die Datei hier zweitzuschreiben hiesse, zwei Quellen fuer eine Wahrheit zu
# halten; beim naechsten Versionswechsel zoege eine nach und die andere nicht.
( set -a; . services/cloudnative-pg/service.env; set +a
  echo ">> ${NAME} ${VERSION}"
  $K apply --server-side -f "${URL}" >/dev/null
  $K -n "${WAIT_NS}" rollout status "deploy/${WAIT_DEPLOY}" --timeout=5m >/dev/null
  echo "   Operator bereit" )

echo
echo "   Ein Mandant entsteht mit: make apps-mandant NAME=<name>"
