# Observability

Ein **eigener kind-Cluster** neben der Plattform, nicht ein Namespace in ihr.

Der Grund ist der Zweck. `make down` löscht `cfk8s` vollständig; was in der
Plattform gemessen wurde, wäre mit gelöscht. Ein Beobachter, der mit dem
Beobachteten stirbt, kann über Läufe hinweg nichts aussagen — und genau das
ist hier die Frage: Verhält sich der Broker heute wie letzte Woche?

```
make obs-up       # Cluster, Prometheus, Grafana
make obs-scrape   # der Weg zum Broker im Plattform-Cluster
make obs-verify   # misst er wirklich?
```

| | |
|---|---|
| Prometheus | <http://127.0.0.1:9090> |
| Grafana | <http://127.0.0.1:3000>, Benutzer `admin` |

Das Grafana-Passwort steht in `values.local.yaml` und bleibt lokal. Die beiden
Adressen sind feste Knotenports aus `kind.yaml`, kein `port-forward` — ein
Port-Forward überlebt weder das Schließen des Terminals noch einen Neustart
des Pods.

## Was gemessen wird — und was bewusst nicht

Eingesammelt wird, was aus **`kind-cfk8s`** kommt: heute die Metriken des
OSB-Brokers.

Abgeschaltet sind `node-exporter`, `kube-state-metrics` und sämtliche
Kubernetes-Ziele des Stacks. Sie messen den Cluster, **in dem sie laufen** —
und das ist hier der Beobachter selbst. Wer sie anlässt, füllt Grafana mit
Kurven über den Beobachter und hält das für Monitoring. Der Alertmanager ist
aus dem gleichen Grund aus: ohne benannten Empfänger tut er nichts.

## Der Weg über die Clustergrenze

Drei Teile, und jeder hat einen Grund:

1. **Knotenport im Plattform-Cluster** (`broker-metrics-nodeport.yaml`). Der
   reguläre Service des Brokers ist eine ClusterIP und von außen nicht
   erreichbar. Ein **zweiter** Service statt einer Änderung am bestehenden:
   der gehört dem Helm-Release des Brokers, und eine Änderung daran wäre beim
   nächsten `make broker` weg.

2. **Der Name statt der Adresse.** Beide kind-Cluster hängen im Docker-Netz
   `kind`, in dem Docker die Container-Namen auflöst. Das Ziel heißt deshalb
   `cfk8s-control-plane:30443` und nicht `172.18.0.4:30443`. Nach einem
   Neustart des Wirts vergibt Docker neue Adressen (FINDINGS #33) — die Namen
   bleiben. Eine eingetragene IP wäre nach dem ersten Neustart still falsch.

3. **Echte TLS-Prüfung, kein `insecureSkipVerify`.** Der Broker terminiert TLS
   selbst, ausgestellt von der Plattform-CA. `make obs-scrape` holt deren
   `ca.crt` aus dem Plattform-Cluster — **nur** `ca.crt`, denn das Quell-Secret
   trägt auch den privaten Schlüssel der CA. Verbunden wird zum Knotennamen,
   geprüft gegen `serverName: osb-broker.osb-broker.svc`, weil das
   Broker-Zertifikat nur clusterinterne Namen führt.

Punkt 3 ist mehr als Sorgfalt: Auf der Cloud-Controller-Seite steht dieselbe
Frage als FINDINGS #31 offen, weil CF hier mit `skip_cert_verify: true` läuft.
Für den Metrikweg ist sie damit beantwortet.

## Warum `obs-verify` die Ziele fragt und nicht die Pods

Der Vorgänger dieses Clusters lief 25 Tage lang fehlerfrei und maß **nichts**:
ein ServiceMonitor zeigte auf einen Port namens `metrics`, den der Service
nicht hatte. Prometheus meldet so etwas nicht als Fehler — er hat schlicht
nichts zu tun. Alle Pods grün, null Ziele.

`obs-verify` fragt deshalb `/api/v1/targets` und verlangt `health: up`, und
danach eine Zeitreihe, die es nur beim Broker gibt. Ein laufender Pod ist kein
Messwert.

## Ein grünes Ziel beweist nicht, dass der Weg offen ist

Gemessen am 2026-09-23, als Gegenprobe zu genau diesem Aufbau: Der Knotenport
im Plattform-Cluster wurde gelöscht — und Prometheus meldete das Ziel noch
**75 Sekunden später** als `up`, mit Scrapes von elf Millisekunden und ohne
Fehler. Ein Verbindungsversuch aus demselben Docker-Netz scheiterte zur selben
Zeit.

Die Erklärung ist HTTP **keep-alive**: Prometheus hält die TCP-Verbindung zum
Ziel offen und stellt weitere Anfragen darüber. Solange Verkehr fließt, hält
auch Calicos Conntrack-Eintrag die Weiterleitung aufrecht, obwohl der Service,
der sie angelegt hat, nicht mehr existiert. Erst eine **neue** Verbindung
trifft auf die geänderte Wirklichkeit:

```
$ kubectl --context kind-observability -n observability     delete pod prometheus-observability-kube-prometh-prometheus-0
$ # danach:
health: down | dial tcp 172.18.0.4:30443: connect: connection refused
```

Daraus folgt für jede Messung an diesem Aufbau: **Wer den Weg ändert und
gleich danach ein grünes Ziel sieht, hat nichts bewiesen.** Entweder den
Prometheus-Pod neu starten oder lange genug warten, bis die Verbindung von
selbst abläuft. Dasselbe gilt in die andere Richtung — ein wiederhergestellter
Weg wird erst mit dem nächsten Verbindungsaufbau sichtbar.

## Was noch fehlt

- **Loki** für Logs, und ein Sammler davor. Loki nimmt Logs nicht selbst
  entgegen.
- **OpenTelemetry-Collector** als gemeinsamer Eingang für Metriken, Logs und
  Traces — und als Gegenstück ein Ziel für Traces, falls sie dazugehören
  sollen. Der Collector transportiert, er speichert nicht.
- **Die Logs von Cloud Foundry.** Sie kommen *nicht* aus Pod-Ausgaben: die
  Logs einer gepushten Anwendung laufen über Loggregator. Der vorgesehene Weg
  ist ein Syslog-Drain (`syslog-binding-cache` läuft bereits in `cf-system`)
  auf einen Empfänger hier. Wer stattdessen Container-Logs einsammelt, baut
  eine Pipeline, welche die eigentlichen Anwendungen nicht erfasst — und merkt
  es nicht.
- **Metriken der Plattform selbst** (Cloud Controller, Diego, Gorouter). Der
  Upstream bewegt sich hier: RFC „Provide CF Platform Logs over Otel" ist in
  Abstimmung, ein `otel-collector` liegt als PR im `kind-deployment`. Das
  abzuwarten ist billiger, als den Weg selbst zu erfinden.
