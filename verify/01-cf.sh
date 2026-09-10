#!/usr/bin/env bash
# Cloud Foundry selbst: laufen die Komponenten, und ist es das echte CAPI?
cd "$(dirname "$0")/.." && set -a && . versions.env && set +a && . verify/lib.sh
echo "Cloud Foundry"
check "Knoten bereit" "0" \
  "\$K get nodes --no-headers | grep -vc ' Ready '"
# Terminating zaehlt nicht als Fehler: direkt nach einem Rollout ist der alte
# Pod noch da, und ein Check, der danach eine halbe Minute rot ist, erzieht
# zum Wegsehen.
#
# Gemeldet werden die NAMEN, nicht eine Zahl: "erwartet 0, erhalten 2" schickt
# den Betreiber auf dieselbe Suche, die der Check gerade gemacht hat.
#
# Direkt nach `make start` ist hier oefter etwas rot, das sich von selbst
# faengt - nfsbroker etwa brauchte fuenf Neustarts. Das ist kein Grund fuer eine
# Ausnahme im Check, sondern einer, ihn ein paar Minuten spaeter noch einmal zu
# fahren.
lahm=$($K get pods -A --no-headers 2>/dev/null \
  | grep -vE ' (Running|Succeeded|Completed|Terminating) ' \
  | awk '{print $2"("$4")"}' | tr '\n' ' ' | sed 's/ $//')
check "keine Pods außerhalb von Running/Succeeded" "" "printf '%s' \"\$lahm\""
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
# Ohne Buildpacks ist kein `cf push` moeglich, und das faellt sonst erst an
# einem fehlgeschlagenen Staging auf: "missing flag: -buildpackOrder" nennt
# weder die Ursache noch den Weg. `make cf-up` laedt sie, aber wer den Cluster
# von Hand hochgezogen hat, hat sie nicht.
buildpacks=$(cf curl /v3/buildpacks 2>/dev/null | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: raise SystemExit
print(" ".join(r["name"] for r in d.get("resources",[])))' 2>/dev/null)
for b in go_buildpack binary_buildpack; do
  contains "Buildpack vorhanden: $b" "$b" "printf '%s' \"\$buildpacks\""
done
finish
