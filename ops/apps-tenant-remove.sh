#!/usr/bin/env bash
# Einen Mandanten samt allem entfernen, was er betreibt.
#
# Das Gegenstueck zu apps-tenant.sh. Es fragt nach, weil mit dem Namespace
# auch Datenbanken und deren Datentraeger verschwinden - und die gehoeren
# nicht uns.
set -euo pipefail
cd "$(dirname "$0")/.." && set -a && . versions.env && set +a

name="${1:-}"
[ -n "$name" ] || { echo "   Aufruf: make apps-mandant-weg NAME=<name>"; exit 1; }

CTX="kind-${APPS_CLUSTER_NAME}"
K="kubectl --context ${CTX}"

$K get namespace "$name" >/dev/null 2>&1 || { echo "   Mandant $name existiert nicht"; exit 0; }

echo "   Im Namespace $name liegen:"
$K -n "$name" get deploy,sts,svc,ingress,cluster.postgresql.cnpg.io,pvc --no-headers 2>/dev/null | sed 's/^/     /' || true
printf '   Alles davon loeschen, Datenbanken eingeschlossen? [j/N] '
read -r a; [ "$a" = "j" ] || { echo "   abgebrochen"; exit 1; }

$K delete namespace "$name" --wait=true >/dev/null
rm -f "apps/kubeconfig-${name}.yaml"
echo "   $name entfernt, Kubeconfig geloescht"
