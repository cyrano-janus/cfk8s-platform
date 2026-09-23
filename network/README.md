# Netzwerkregeln, die keine Security Group sein können

Hier liegt genau eine Regel, und sie steht hier, weil eine Application Security
Group sie **unter Cilium** nicht ausdrücken kann.

> **Diese Plattform fährt Calico** (`CNI` in `versions.env`), und dort wird die
> Regel nicht gebraucht: die ASG aus `security-groups/` trägt, der
> `policy-agent` übersetzt sie in eine Calico-`NetworkPolicy`, und die
> Anwendung erreicht ihren Dienst. `make network` überspringt sich deshalb
> selbst, solange eine andere CNI als Cilium läuft.
>
> Die Datei bleibt, weil der Upstream beide CNIs unterstützt und der Befund
> unter Cilium unverändert gilt. Gemessen in [FINDINGS #32](../FINDINGS.md).

**Der Kern:** Cilium löst einen Service auf die Backend-Pod-IP auf, *bevor* es
die Regel auswertet, und prüft dann gegen die **Endpunkt-Identität** des
Ziel-Pods. Eine CIDR-Regel trifft eine Endpunkt-Identität nie. Die
ASG-Übersetzung von Cloud Foundry kennt aber nur CIDRs.

Gemessen am Drop-Monitor (`cilium-dbg monitor --type drop`), für die ClusterIP
und für eine LoadBalancer-Adresse identisch:

```
drop (Policy denied) identity 59404->1446: 10.244.2.207 -> 10.244.1.62:5432 tcp SYN
```

Daraus folgt: **eine LoadBalancer-Adresse ändert daran nichts.** Sie ist für
Cilium kein „außen", solange der Client im selben Cluster sitzt. Die
Gegenprobe steht in `FINDINGS.md` #32.

## Was hier nicht steht

`security-groups/backing-services.json` bleibt bestehen. Sie ist der Weg, der
auf einem echten Cloud Foundry richtig ist, und sie greift dort auch — nur
eben nicht für ein Ziel im selben Cluster. Wer die Ports dort ändert, ändert
sie in `backing-services-egress.yaml` mit.

## Gegenprobe

Die Regel einmal ausschalten und nachsehen, ob sie anschlägt:

```
kubectl --context kind-cfk8s delete -f network/backing-services-egress.yaml
cf restart letzter-eintrag        # muss wieder "i/o timeout" melden
make network                      # zurück
```
