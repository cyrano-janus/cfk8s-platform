#!/usr/bin/env bash
# Nach einem Neustart des Wirts: Calico wieder in Gang bringen (FINDINGS #34).
#
# Am 2026-10-31 zum ersten Mal am kalten Wirt gemessen, ohne Umweg: 57 Pods,
# davon 50 tot, danach 56 laufend. Dabei kamen die beiden Schritte heraus, die
# unten stehen - das Wegraeumen der Leichen allein genuegte NICHT.
#
# Das Calico-Gegenstueck zu `netz-reparieren`, und es tut etwas ANDERES. Unter
# Cilium (#33) tragen die Endpunkt-Objekte veraltete Adressen und die
# Komponenten werden neu gestartet. Hier sind die Adressen richtig - der Ring
# ist ein anderer: Calico faehrt `linuxDataplane: BPF` und ersetzt damit
# kube-proxy. Uebersetzt niemand die ClusterIP 10.96.0.1, kommen
# tigera-operator und calico-typha nicht hoch, denn sie brauchen genau sie -
# und sie entsteht erst, wenn calico-node laeuft.
#
# WAS HIER AUSDRUECKLICH NICHT GETAN WIRD: ein ConfigMap
# `kubernetes-services-endpoint` anlegen. Das ist der allgemein dokumentierte
# Calico-Ausweg aus diesem Ring und hier nachweislich schaedlich - diese
# Installation traegt `bpfNetworkBootstrap: Enabled`, und der Operator
# verweigert dann die Arbeit mit "requirements are not met". Gemessen, siehe
# FINDINGS #34.
set -euo pipefail
cd "$(dirname "$0")/.." && set -a && . versions.env && set +a

K="kubectl --context kind-${KIND_CLUSTER_NAME}"

# Unter einer anderen CNI ist weder gemessen, ob der Befund auftritt, noch was
# ihn behebt. Dasselbe Argument wie bei netz-reparieren, nur andersherum.
if [ "${CNI}" != "calico" ]; then
  echo "   CNI=${CNI}: dieses Target gilt fuer Calico. Fuer Cilium ist"
  echo "   make netz-reparieren zustaendig (FINDINGS #33)."
  exit 1
fi

# Die Pods stehen auf `status.phase: Running` - deshalb findet
# `--field-selector=status.phase!=Running` sie NICHT.
#
# Eine Leiche zeigt sich auf ZWEI Arten, und die zweite kam erst am Kaltstart
# dazu (FINDINGS #34):
#
#   1. Die Ready-Condition fehlt ganz. Der kubelet meldet zu diesem Pod gar
#      nichts mehr.
#   2. Die Ready-Condition steht auf False, und JEDER Container meldet
#      `terminated` mit reason `Unknown`. Das ist der haeufigere Fall: der
#      kubelet hat seine Container ueber den Neustart des Wirts verloren und
#      sagt das auch - er meldet nur eben etwas, statt zu schweigen.
#
# Nur Form 1 zu suchen war der Grund, warum dieses Target beim ersten Lauf am
# kalten Wirt "0 entfernt" meldete und danach fuenf Minuten vergeblich auf
# calico-node wartete: 50 von 57 Pods trugen Form 2.
#
# `all` statt `any`: ein Pod, von dessen Containern noch einer laeuft, wird in
# Ruhe gelassen. Lieber eine Leiche uebersehen als einen lebenden Pod toeten.
leichen() {
  $K get pods -n "$1" -o json 2>/dev/null | python3 -c '
import sys, json
d = json.load(sys.stdin)
for p in d.get("items", []):
    st = p.get("status", {})
    ready = [c for c in st.get("conditions", []) if c.get("type") == "Ready"]
    if not ready:
        print(p["metadata"]["name"])
        continue
    cs = st.get("containerStatuses") or []
    if cs and all(
        ((c.get("state") or {}).get("terminated") or {}).get("reason") == "Unknown"
        for c in cs
    ):
        print(p["metadata"]["name"])
'
}

# Vor dem Aufraeumen: traegt calico-node ueberhaupt die richtige Adresse?
#
# Der tigera-operator gibt dem DaemonSet die Adresse des API-Servers FEST mit
# (KUBERNETES_APISERVER_ENDPOINTS). Daraus baut der Init-Container
# ebpf-bootstrap die NAT-Map, die 10.96.0.1 uebersetzt - das ist der
# Mechanismus hinter `bpfNetworkBootstrap: Enabled`, mit dem Calico den Ring
# aus #34 eigentlich selbst oeffnet.
#
# Nach einem Neustart des Wirts vergibt Docker die Adressen der
# Knoten-Container neu, und dann zeigt diese Variable auf einen anderen
# Knoten - gemessen am 2026-10-31 auf den Worker statt auf die Control-Plane.
# Der bootstrap meldet trotzdem Erfolg ("Included kubernetes service
# (10.96.0.1:443) and endpoints (172.18.0.12:6443) in the Nat Maps"), und
# install-cni scheitert danach an "connection refused". Leichen wegraeumen
# allein genuegt dann NICHT: die neuen Pods laufen in denselben Fehler.
#
# Das ist dieselbe Wurzel wie #33 - eine veraltete Docker-Adresse -, nur an
# einer anderen Stelle. Korrigieren muss es dieses Target, denn der Operator
# taete es selbst, kommt aber ohne die Uebersetzung nicht hoch. Sobald er
# laeuft, schreibt er die Variable ohnehin neu; der Eingriff haelt also nur,
# bis das Richtige wieder greift.
#
# Quelle der Wahrheit ist das Endpoints-Objekt und nicht `docker inspect`:
# Kubernetes pflegt es selbst, und es war im Fehlerfall nachweislich korrekt.
echo ">> API-Adresse im DaemonSet pruefen"
SOLL=$($K get endpoints kubernetes \
         -o jsonpath='{.subsets[0].addresses[0].ip}:{.subsets[0].ports[0].port}' 2>/dev/null)
IST=$($K get ds -n calico-system calico-node -o jsonpath=\
'{range .spec.template.spec.initContainers[?(@.name=="ebpf-bootstrap")].env[?(@.name=="KUBERNETES_APISERVER_ENDPOINTS")]}{.value}{end}' 2>/dev/null)
if [ -z "${SOLL}" ]; then
  echo "   Endpoints-Objekt 'kubernetes' ist leer - hier stimmt etwas anderes nicht."
  exit 1
elif [ -z "${IST}" ]; then
  echo "   Das DaemonSet traegt keine feste Adresse (${SOLL} waere die richtige)."
elif [ "${IST}" != "${SOLL}" ]; then
  echo "   veraltet: ${IST} -> ${SOLL}"
  $K set env ds/calico-node -n calico-system --containers=ebpf-bootstrap \
     "KUBERNETES_APISERVER_ENDPOINTS=${SOLL}" >/dev/null
else
  echo "   stimmt (${IST})"
fi

echo ">> Calico-Pods ohne Lebenszeichen entfernen"
ANZ=0
for p in $(leichen calico-system); do
  $K delete pod -n calico-system "$p" --force --grace-period=0 >/dev/null 2>&1 || true
  ANZ=$((ANZ + 1))
done
echo "   ${ANZ} entfernt (sie werden von DaemonSet und Deployment neu erzeugt)"

# `wait --for=condition=Ready pod -l ...` waere hier falsch: es merkt sich die
# Pods, die es beim Aufruf vorfindet. Korrigiert der Schritt oben die Adresse,
# rollt das DaemonSet neu aus, die gemerkten Namen verschwinden - und das
# Kommando laeuft in seinen Timeout, obwohl die Ersatz-Pods laengst laufen.
# Genau das ist am 2026-10-31 passiert. `rollout status` verfolgt stattdessen
# das DaemonSet.
echo ">> warte auf calico-node"
$K rollout status ds/calico-node -n calico-system --timeout=5m

echo ">> Leichen im uebrigen Cluster entfernen"
ANZ=0
for ns in $($K get ns -o jsonpath='{.items[*].metadata.name}'); do
  for p in $(leichen "$ns"); do
    $K delete pod -n "$ns" "$p" --force --grace-period=0 >/dev/null 2>&1 || true
    ANZ=$((ANZ + 1))
  done
done
echo "   ${ANZ} entfernt"

# Die Gegenprobe gehoert ins Target, nicht in eine Erinnerung: ohne sie meldet
# es Erfolg, sobald Pods laufen - und ob die ClusterIP-Uebersetzung wirklich
# wieder steht, haette dann niemand geprueft. Genau sie ist hier das Kranke.
echo ">> Gegenprobe: uebersetzt wieder jemand die ClusterIP?"
if $K -n "${CF_SYSTEM_NAMESPACE}" exec nats-0 -c nats -- \
     getent hosts "postgresql.${CF_SYSTEM_NAMESPACE}.svc.cluster.local" >/dev/null 2>&1; then
  echo "   Dienstnamen loesen wieder auf."
else
  echo "   Aufloesung geht NICHT - der Befund ist ein anderer, siehe FINDINGS #34"
  exit 1
fi

echo "   Die CF-Komponenten brauchen danach einige Minuten; make status zeigt es."
