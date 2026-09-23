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

## Dashboards

```
make obs-dashboards
```

Liegt als **Datei im Repo** (`dashboards/*.json`) und wird als ConfigMap
ausgeliefert; Grafanas Sidecar sucht das Label `grafana_dashboard=1` und legt
jede gefundene Datei ab. Was jemand stattdessen in der Oberfläche
zusammenklickt, liegt in Grafanas Datenbank und ist nach einem Neuaufbau weg.

Vorhanden sind zwei: **„OSB-Broker"** und **„Laptop"**.

**„OSB-Broker"** (<http://127.0.0.1:3000>, Ordner *General*), mit
zehn Panels in vier Reihen: Zustand (erreichbar, aktive Instanzen und
Bindungen, Lesefehler), Vorgänge einmal als Summe und einmal als Zuwachs,
Antworten nach HTTP-Status und Antwortzeit-Quantile, zuletzt die Abfragen der
asynchronen Vorgänge und eine Tabelle je Angebot und Plan.

Zwei Entscheidungen darin sind absichtlich und sollten beim Ändern bleiben:

- **Keine Ampelfarben auf HTTP-Status.** 410 und 422 sind im OSB-Protokoll
  reguläre Antworten — 410 Gone beim zweiten Abräumen, 422 bei einem nicht
  zugesagten Planwechsel. Rot gefärbt läsen sie sich als Störung, obwohl sie
  belegen, dass der Broker sich richtig verhält.
- **Die Antwortzeit-Quantile rechnen über 15 Minuten**, nicht über 5. Hier
  kommen Anfragen in Schüben; über ein kurzes Fenster ohne Verkehr liefert das
  Quantil keinen Wert, sondern eine Lücke.

**„Laptop"** zeigt den Rechner selbst: Arbeitsspeicher, CPU-Last,
Datenträger und je eine Top-Ten nach Speicher, CPU und Netzwerk. Die Daten
kommen von zwei Messfühlern, die als Container **auf dem Wirt** laufen:

```
make obs-host
```

`node-exporter` liefert die Werte des Rechners, `cAdvisor` die je Container.
Beide hängen am Docker-Netz `kind` und brauchen deshalb keinen veröffentlichten
Port — Prometheus erreicht sie über ihren Namen. Sie laufen **nicht** im
Cluster: ein Exporter dort misst den kind-Knoten-Container, nicht den Laptop;
die Zahlen sähen plausibel aus und wären falsch. Gegenprobe beim Aufbau: 23,3
GiB / 8 Kerne / 467,9 GiB gegen `free`, `nproc` und `df` — identisch.

Zwei Grenzen dieser Sicht stehen in den Panel-Beschreibungen und gehören dazu:

- **Ein kind-Knoten erscheint als EIN Container.** Was darin an Pods läuft,
  sieht cAdvisor von außen nicht. Für die Pod-Ebene müsste man den
  kubelet-Endpunkt im jeweiligen Cluster abfragen.
- **Plattenbelegung je Container gibt es nicht.** cAdvisor meldet
  `container_fs_usage_bytes` nur für den Wirt insgesamt, ohne `name`-Label —
  Docker mit overlay2 liefert die Aufschlüsselung nicht. An dieser Stelle steht
  deshalb der Netzwerkverkehr, nicht eine Zahl, die es nicht gibt.

Nach einer Änderung an einer `.json` erneut `make obs-dashboards` — das Target
prüft das JSON, bevor es ausliefert. Ein kaputtes überspränge das Sidecar
stillschweigend, und in Grafana fehlte das Dashboard ohne jede Meldung.

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

## Cloud Foundry misst sich selbst — nur nicht in Prometheus' Sprache

Gemessen am 2026-09-23. Die Frage ist wichtig, weil sie darüber entscheidet,
wie die Plattform überhaupt in dieses Bild kommt.

**Es gibt nichts zu scrapen.** Kein einziger Container in `cf-system`
deklariert einen Metrik-Port; der einzige `metrics`-Port im ganzen Namespace
gehört dem Istio-Sidecar und stammt nicht von Cloud Foundry.

**Gemessen wird trotzdem, und zwar laufend.** CF schickt seine Zahlen als
Loggregator-Envelopes — Gauges und Counter — durch `forwarder-agent` →
`loggregator-agent` → `doppler` → `log-cache`. Über die CF-API abgefragt
(`https://log-cache.cf.127-0-0-1.nip.io/api/v1/meta`, mit dem Token aus
`cf oauth-token`) kennt log-cache zwölf Quellen, zehn davon Plattform:

```
auctioneer   bbs   cloud_controller   doppler   gorouter   locket
rep   reverse_log_proxy   route-emitter   ssh_proxy
```

Die Daten sind aktuell — der jüngste Envelope war eine Sekunde alt —, und
`gorouter` allein liefert in 100 Envelopes **40 verschiedene Messgrößen**:
`uptime`, `routed_app_requests`, `websocket_upgrades`, `routes_pruned`,
`total_dropped_messages` und weitere.

**Der PromQL-Endpunkt von log-cache antwortet, liefert hier aber nichts.**
log-cache bringt unter `/api/v1/query` eine Prometheus-kompatible Schnittstelle
mit. Sie antwortet im richtigen Format und mit einem Fehler:

```
$ query=uptime{source_id="gorouter"}
{"status":"error","errorType":"bad_data","error":"Metrics not available"}
```

Und das für einen Gauge-Namen, von dem eine Sekunde zuvor ein frischer Wert
gelesen wurde. **Warum, ist ungeklärt** — ob die Engine in dieser
Konfiguration abgeschaltet ist, eine andere Autorisierung verlangt oder die
Reihen anders adressiert werden, ist nicht untersucht. Wer diesen Weg gehen
will, fängt hier an.

Daraus die drei Wege, in aufsteigender Zukunftssicherheit:

1. **log-cache als Grafana-Datenquelle.** Der direkteste Weg, ohne zusätzliche
   Komponente — sobald die Frage oben beantwortet ist.
2. **Eine Brücke**, die log-cache liest und als `/metrics` ausliefert. Trägt
   sicher, ist aber selbstgebaut, und was hier selbstgebaut wird, muss hier
   gepflegt werden.
3. **Der Upstream-Weg.** Genau dieses Problem ist der Grund für den RFC
   „Provide CF Platform Logs over Otel" und den offenen `otel-collector`-PR im
   `kind-deployment`. Fällt CF auf OTel, entfällt die Brücke.

Der Unterschied zum Broker ist damit benannt: **er** liefert Prometheus-
Metriken direkt und wird gescrapt; **die Plattform** liefert ihre Zahlen in
Loggregators Format, und das Verbindungsstück dorthin fehlt.

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
- **Das Verbindungsstück zu den Metriken der Plattform** — sie fließen, sie
  sind nur nicht abholbar (siehe den Abschnitt darüber). Erster Schritt: die
  ungeklärte Antwort des PromQL-Endpunkts von log-cache.
