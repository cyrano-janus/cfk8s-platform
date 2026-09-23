#!/usr/bin/env bash
# Ein Mandant im Anwendungs-Cluster: Namespace, ServiceAccount, Rolle - und
# eine Kubeconfig, die ihm ausgehaendigt wird.
#
# Aufruf: make apps-mandant NAME=<name>
set -euo pipefail
cd "$(dirname "$0")/.." && set -a && . versions.env && set +a

name="${1:-}"
if [ -z "$name" ]; then echo "   Aufruf: make apps-mandant NAME=<name>"; exit 1; fi
# Der Name wird Namespace UND Teil von Hostnamen. Was hier durchrutscht, faellt
# erst beim ersten Ingress auf, mit einer Meldung ueber ein ungueltiges Label.
if ! printf '%s' "$name" | grep -Eq '^[a-z]([-a-z0-9]{0,30}[a-z0-9])?$'; then
  echo "   '$name' taugt nicht als Name: nur Kleinbuchstaben, Ziffern und Striche,"
  echo "   Anfang ein Buchstabe, hoechstens 32 Zeichen."
  exit 1
fi

CTX="kind-${APPS_CLUSTER_NAME}"
K="kubectl --context ${CTX}"

echo ">> Mandant ${name}"
sed "s/MANDANT/${name}/g" apps/mandant.yaml | $K apply -f - >/dev/null
echo "   Namespace, ServiceAccount und Rolle"

# Auf das Token warten: Kubernetes fuellt das Secret asynchron. Wer sofort
# liest, schreibt eine Kubeconfig ohne Token - und die scheitert spaeter mit
# "Unauthorized", weit weg von hier.
for i in $(seq 1 30); do
  tok=$($K -n "${name}" get secret "${name}-deployer-token" -o jsonpath='{.data.token}' 2>/dev/null || true)
  [ -n "${tok:-}" ] && break
  [ "$i" = 30 ] && { echo "   kein Token nach 30 Versuchen"; exit 1; }
  sleep 1
done

ziel="apps/kubeconfig-${name}.yaml"
ca=$($K config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
srv=$($K config view --raw --minify -o jsonpath='{.clusters[0].cluster.server}')
cat > "${ziel}" <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: ${APPS_CLUSTER_NAME}
    cluster:
      certificate-authority-data: ${ca}
      server: ${srv}
contexts:
  - name: ${name}
    context:
      cluster: ${APPS_CLUSTER_NAME}
      namespace: ${name}
      user: ${name}-deployer
current-context: ${name}
users:
  - name: ${name}-deployer
    user:
      token: $(printf '%s' "${tok}" | base64 -d)
EOF
chmod 600 "${ziel}"
echo "   Kubeconfig: ${ziel}"
echo
echo "   Der Mandant benutzt sie so:"
echo "     export KUBECONFIG=\"\$PWD/${ziel}\""
echo "     kubectl get pods"
echo "   Seine Adressen: http://<name>.${APPS_DOMAIN}:${APPS_HTTP_PORT}"
