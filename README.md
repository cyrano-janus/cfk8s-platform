# cfk8s-platform

Entwicklungs- und Testplattform für den OSB-Broker aus
[`../osb-broker-go`](../osb-broker-go): **echtes Cloud Foundry auf kind**, plus
die Operatoren, die der Broker bedient.

Cloud Foundry selbst kommt von
[`cloudfoundry/kind-deployment`](https://github.com/cloudfoundry/kind-deployment) —
`cloud_controller_ng`, UAA, Diego, gorouter, credhub, loggregator, als
Helm-Charts auf drei kind-Knoten. Dieses Repo baut das nicht nach, es klont den
Upstream auf einen gepinnten Commit und ruft ihn auf. Gebaut wird hier alles
daneben: PKI für Broker-TLS, Service-Operatoren, Broker, Registrierung,
Akzeptanzprüfungen.

## Warum nicht mehr Korifi

Der Vorgänger fuhr Korifi, einen **Nachbau** der CF-API auf Kubernetes. Zwei
Gründe für den Wechsel:

- **Korifi ist upstream archiviert** (Cloud Foundry RFC 0060).
- **Der Nachbau war unvollständig, und zwar an einer Stelle, die zählt.**
  Korifis OSB-Client kennt kein `PATCH /v2/service_instances/:id`. Damit waren
  `cf update-service -c`, der Planwechsel und `cf upgrade-service` gar nicht
  prüfbar — drei Symptome einer fehlenden Methode.

Hier laufen alle drei. Belegt am 2026-09-06: ein Parameter-Update erreicht den
Broker und ändert die Ressource wirklich; ein nicht zugesagter Planwechsel wird
vom Cloud Controller mit *„The service does not support changing plans"*
abgelehnt, ohne den Broker zu fragen; und `cf upgrade-service` hebt eine Instanz
von `upgrade available: yes` auf `no`.

## Loslegen

```
make cf-up        # Cloud Foundry (rund 9 Minuten)
make cf-login
make deps pki
make services
cp broker/values.local.yaml.example broker/values.local.yaml   # Passwort setzen
make broker
make register
make security-groups   # sonst erreicht keine App ihren gebundenen Dienst
make verify
```

`make security-groups` ist keine Kür. Cloud Foundry schottet Anwendungen vom
Service-Netz des Clusters ab; ohne die Gruppe läuft jeder Verbindungsversuch
einer App zu ihrer Datenbank in einen `i/o timeout`. Gemessen mit
`samples/db-probe`: mit Gruppe 3 ms, ohne Gruppe fünf Sekunden bis zum Timeout.

**Unter Cilium reicht die Gruppe nicht** — dort prüft die CNI gegen die
Endpunkt-Identität des Ziel-Pods, und eine CIDR-Regel trifft die nie. Für
diesen Fall liegt in [`network/`](network/README.md) eine Umgehung, die
`make network` anwendet; unter Calico überspringt sich das Target selbst. Die
Langfassung steht in `FINDINGS.md` #32.

Zwei Prüfläufe, die verschiedene Fragen beantworten:

```
make verify       # read-only, Sekunden — läuft der Aufbau?
make cf-smoke     # Minuten — liest Cloud Foundry die Zusagen des Brokers so,
                  #           wie er sie meint?
make conformance  # Minuten — hält der Broker allein OSB 2.17 ein?
```

`make help` listet alles. `make status` zeigt den Ist-Zustand.

## Anhalten und wieder starten

```
make stop            # gibt rund 6 GiB Speicher frei, verliert nichts
make start           # rund zwei Minuten
make verify-restart  # ist wirklich alles wiedergekommen?
```

**Ein paar Minuten Geduld nach `make start`.** Einzelne Komponenten und die
CF-Anwendungen brauchen Anläufe — `nfsbroker` etwa fing sich beim fünften
Neustart, eine gepushte App war nach wenigen Minuten wieder da. Wer sofort
prüft, sieht Rot, das keines ist.

**Nach einem Neustart des Wirts entscheidet eine Prüfung, welcher Fall vorliegt.**
Manchmal vergibt Docker den Knoten-Containern neue Adressen; Cilium findet die
Knoten dann nicht wieder, und keine CF-Komponente löst mehr einen Namen auf. Das
sieht aus wie Anlaufschwierigkeiten, ist aber stabil falsch und heilt **nicht**
durch Warten — gemessen acht Stunden und über 350 Neustarts lang (FINDINGS #33).
Es passiert aber **nicht** bei jedem Neustart. Welcher Fall vorliegt, sagen zwei
Befehle:

```
kubectl --context kind-cfk8s get nodes -o custom-columns=\
  'NAME:.metadata.name,IP:.status.addresses[?(@.type=="InternalIP")].address'
docker inspect -f '{{.Name}} {{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' \
  cfk8s-control-plane cfk8s-worker cfk8s-worker2
```

Weichen die Listen ab, ist `make netz-reparieren` fällig, und Warten hilft nie.
Stimmen sie überein, ist Warten genau richtig — dann steht die Plattform nach
rund 20 Minuten von selbst.

**Restart-Zähler nach einem Neustart des Wirts sind kein Befund.** Alle Pods
zeigen `Exit Code 255` / `Reason: Unknown` zur Sekunde des Herunterfahrens, und
die Zähler wachsen mit jedem Boot: Komponenten ohne Startabhängigkeit um eins,
der `cloud-controller` um rund zwanzig, weil CF die BOSH-Startreihenfolge
erwartet und auf Kubernetes alles gleichzeitig hochkommt. Dreistellige Zähler
sind nach ein paar Wochen normal. Was zählt, ist **wann** der letzte Neustart
war: liegt er in den ersten Minuten nach dem Boot, ist die Komponente gesund
(FINDINGS #33, Nachtrag).

## Aufbau

| Pfad | Was |
|---|---|
| `versions.env` | **Alle** Versionen, einschließlich des gepinnten Upstream-Commits |
| `cf/` | Der geklonte Upstream (nicht mitversioniert, per Commit gepinnt) |
| `pki/` | Plattform-CA über cert-manager, für Broker-TLS |
| `services/*/service.env` | Ein Operator ist ein Verzeichnis mit einer Datei |
| `broker/` | Chart-Werte; `values.local.yaml` trägt das Passwort und bleibt lokal |
| `ops/` | Werkzeuge: Katalog abfragen, verwaiste Einträge aufräumen, Konformität, Status |
| `verify/` | Akzeptanzprüfungen, read-only, Sekunden |
| `FINDINGS.md` | Das Messprotokoll: Beobachtung, verifizierte Ursache, Vorschlag |

## Was hier belegt wird — und was nicht

**Belegt ist der Protokollvertrag.** `cloud_controller_ng` hier ist dieselbe
Software wie auf einem Zielsystem; ein Befund über das OSB-Verhalten überträgt
sich.

**Nicht belegt ist der Betrieb.** Der Broker liegt hier im selben Cluster wie
CF, auf einem Zielsystem läuft er getrennt. Ziel-Namespace, Vertrauensanker und
Netzweg bleiben offen — siehe [FINDINGS.md](FINDINGS.md) #30 und #31 und
[CLAUDE.md](CLAUDE.md).
