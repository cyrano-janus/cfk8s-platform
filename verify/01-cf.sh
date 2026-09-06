#!/usr/bin/env bash
# Cloud Foundry selbst: laufen die Komponenten, und ist es das echte CAPI?
cd "$(dirname "$0")/.." && set -a && . versions.env && set +a && . verify/lib.sh
echo "Cloud Foundry"
check "Knoten bereit" "0" \
  "\$K get nodes --no-headers | grep -vc ' Ready '"
# Terminating zaehlt nicht als Fehler: direkt nach einem Rollout ist der alte
# Pod noch da, und ein Check, der danach eine halbe Minute rot ist, erzieht
# zum Wegsehen.
check "keine Pods außerhalb von Running/Succeeded" "0" \
  "\$K get pods -A --no-headers | awk '{print \$4}' | grep -vcE '^(Running|Succeeded|Completed|Terminating)$'"
# Die Komponenten, die den Unterschied zu einem Nachbau ausmachen. capi ist
# cloud_controller_ng - dieselbe Software, die ein Zielsystem fährt; genau
# deshalb ist ein Befund hier eine Aussage über das Zielsystem.
# Die Namen sind die des Upstreams, nicht die der Helm-Charts: das Chart heißt
# capi, das Workload cloud-controller. Wer nach dem Chartnamen sucht, findet
# nichts und merkt es nicht.
for d in cloud-controller uaa bbs auctioneer gorouter credhub nats; do
  check "Komponente bereit: $d" "0" \
    "\$K -n $CF_SYSTEM_NAMESPACE get deploy,sts $d -o json 2>/dev/null | python3 -c \"
import json,sys
try: o=json.load(sys.stdin)
except Exception: print(1); raise SystemExit
i=o.get('items',[o])
print(0 if i and all((x['status'].get('readyReplicas') or 0) >= 1 for x in i) else 1)\""
done
# Ein Nachbau meldet sich mit einem Suffix (Korifi: 3.117.0+cf-k8s). Steht hier
# eine reine Versionsnummer, ist es das Original.
version=$(cf curl /v3/info 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("cf_on_k8s",""))' 2>/dev/null)
if [ "$version" = "True" ] || [ "$version" = "true" ]; then
  fail "CF ist das Original, kein Nachbau" "die API meldet cf_on_k8s=true"
else
  pass "CF ist das Original, kein Nachbau"
fi
finish
