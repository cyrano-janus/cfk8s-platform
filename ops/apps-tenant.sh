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
# ---------------------------------------------------------------- Geheimnisse
# Der Mandant bekommt seinen Pfad im Geheimnisspeicher, eine Policy, die nur
# diesen Pfad erlaubt, eine Anmelderolle fuer seinen ServiceAccount und einen
# SecretStore in seinem Namespace. Damit kann er ExternalSecrets schreiben,
# ohne irgendetwas einzurichten.
#
# Laeuft OpenBao nicht, wird dieser Teil UEBERSPRUNGEN statt abzubrechen: ein
# Mandant muss auch auf einem Cluster ohne Geheimnisspeicher anlegbar sein -
# sonst haengt das Anlegen an einem Dienst, der damit nichts zu tun hat.
NS_BAO="${OPENBAO_NAMESPACE}"
if $K -n "${NS_BAO}" get pod openbao-0 >/dev/null 2>&1 \
   && $K -n "${NS_BAO}" exec openbao-0 -- env BAO_ADDR=http://127.0.0.1:8200 \
        bao status -format=json 2>/dev/null | grep -q '"sealed": *false'; then

  tokbao=$(python3 -c "import json;print(json.load(open('${OPENBAO_INIT_FILE}'))['root_token'])")
  bao_tok() { $K -n "${NS_BAO}" exec -i openbao-0 -- \
                env BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN="$tokbao" "${@}"; }

  echo ">> Geheimnisspeicher"
  # Die Policy nennt den Pfad zweimal: KV Version 2 legt Werte unter
  # <mount>/data/<pfad> ab, seine Metadaten aber unter <mount>/metadata/<pfad>.
  # Wer nur den ersten Pfad erlaubt, kann schreiben und lesen - aber nicht
  # auflisten, und `bao kv list` scheitert mit permission denied.
  printf 'path "mandanten/data/%s/*" { capabilities = ["create","read","update","delete","list"] }\npath "mandanten/metadata/%s/*" { capabilities = ["list","read","delete"] }\n' "$name" "$name" \
    | bao_tok bao policy write "mandant-$name" - >/dev/null
  bao_tok bao write "auth/kubernetes/role/$name" \
    bound_service_account_names="${name}-deployer" \
    bound_service_account_namespaces="$name" \
    policies="mandant-$name" ttl=1h >/dev/null
  echo "   Pfad mandanten/${name}/, Policy und Anmelderolle"

  $K apply -f - >/dev/null <<EOF
apiVersion: external-secrets.io/v1
kind: SecretStore
metadata:
  name: openbao
  namespace: ${name}
spec:
  provider:
    vault:
      server: http://openbao.${NS_BAO}.svc:8200
      path: mandanten
      version: v2
      auth:
        kubernetes:
          mountPath: kubernetes
          role: ${name}
          serviceAccountRef:
            name: ${name}-deployer
EOF
  echo "   SecretStore 'openbao' im Namespace ${name}"
else
  echo "   (kein entsiegelter OpenBao - Geheimnisspeicher uebersprungen)"
fi

echo
echo "   Der Mandant benutzt sie so:"
echo "     export KUBECONFIG=\"\$PWD/${ziel}\""
echo "     kubectl get pods"
echo "   Seine Adressen: http://<name>.${APPS_DOMAIN}:${APPS_HTTP_PORT}"
