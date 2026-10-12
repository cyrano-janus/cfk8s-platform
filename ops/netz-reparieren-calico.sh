#!/usr/bin/env bash
# Nach einem Neustart des Wirts: Calico wieder in Gang bringen (FINDINGS #34).
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

# Die Pods stehen auf `status.phase: Running`, nur ihre Conditions fehlen -
# deshalb findet `--field-selector=status.phase!=Running` sie NICHT. Gesucht
# wird ueber die Ready-Condition, und die ist bei einer Leiche schlicht leer.
leichen() {
  $K get pods -n "$1" -o json 2>/dev/null | python3 -c '
import sys, json
d = json.load(sys.stdin)
for p in d.get("items", []):
    st = p.get("status", {})
    ready = [c for c in st.get("conditions", []) if c.get("type") == "Ready"]
    # Keine Ready-Condition = der kubelet meldet zu diesem Pod gar nichts mehr.
    if not ready:
        print(p["metadata"]["name"])
'
}

echo ">> Calico-Pods ohne Lebenszeichen entfernen"
ANZ=0
for p in $(leichen calico-system); do
  $K delete pod -n calico-system "$p" --force --grace-period=0 >/dev/null 2>&1 || true
  ANZ=$((ANZ + 1))
done
echo "   ${ANZ} entfernt (sie werden von DaemonSet und Deployment neu erzeugt)"

echo ">> warte auf calico-node"
$K wait --for=condition=Ready pod -l k8s-app=calico-node -n calico-system --timeout=5m

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
echo
echo "   VERMERK: Die Wirkung dieses Targets ist noch nicht am Kaltstart"
echo "   gemessen - beim ersten Auftreten lief ein Umweg mit. Siehe FINDINGS"
echo "   #34, Abschnitt 'Nicht belegt'. Wer es einmal am frisch gestarteten"
echo "   Wirt fahren laesst, nimmt diesen Vermerk heraus."
