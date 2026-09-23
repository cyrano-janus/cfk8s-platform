# Anwendungs-Cluster

Ein **eigener kind-Cluster** für Anwendungen, die Nutzern gehören.

Er liegt neben der Plattform und nicht in ihr, aus demselben Grund wie der
Observability-Cluster: In `cfk8s` ist `make down` ein normaler Arbeitsschritt.
Was Nutzer betreiben, darf davon nicht abhängen.

**Cloud Foundry bleibt daneben bestehen.** Wer `cf push` will, benutzt weiter
`cfk8s`; wer einen Namespace und `kubectl` will, bekommt beides hier. Die
beiden Wege wissen nichts voneinander — das ist Absicht, keine Lücke.

```
make apps-up                      # Cluster, Ingress, Datenbank-Operator
make apps-openbao                 # Geheimnisspeicher (einmalig)
make apps-mandant NAME=anna       # Namespace, Rechte, Kubeconfig, Geheimnispfad
make apps-verify                  # trägt der Weg von außen?
```

Nach jedem Start des Clusters — auf diesem Rechner also jeden Morgen:

```
make openbao-unseal
```

Ein versiegelter OpenBao läuft, antwortet und gibt **nichts** heraus; jede
Anwendung, die ein Geheimnis braucht, hängt. `make apps-verify` schlägt
deshalb an, solange er zu ist.

| | |
|---|---|
| Adressen der Anwendungen | `http://<name>.k8s.127-0-0-1.nip.io:8080` |
| Kubeconfig eines Mandanten | `apps/kubeconfig-<name>.yaml` (lokal, nie im Repo) |
| Geheimnisspeicher | <http://openbao.k8s.127-0-0-1.nip.io:8080> |

## Warum die krummen Ports

**80 und 443 am Wirt gehören Cloud Foundry.** Nachgesehen mit `docker port`:
`cfk8s-worker` bildet sie auf seinen Gorouter ab. Ein zweiter Cluster kann sie
nicht auch belegen, also liegen die Anwendungen hier auf **8080** und **8443**.

Aus demselben Grund ein eigenes Namensschema: CF-Anwendungen heißen
`*.apps.127-0-0-1.nip.io`, die hier `*.k8s.127-0-0-1.nip.io`. Wer eine Adresse
sieht, weiß damit sofort, welche Plattform sie bedient.

## Was ein Mandant bekommt — und was nicht

`make apps-mandant NAME=anna` legt an: einen Namespace `anna`, einen
ServiceAccount `anna-deployer`, eine Rolle und eine Kubeconfig.

Erlaubt ist darin, was zum Betreiben einer Anwendung gehört: Pods,
Deployments, Services, Ingresses, ConfigMaps, Secrets, Jobs, PVCs — und
`clusters.postgresql.cnpg.io`, also eine eigene Datenbank über denselben
Operator, den die Plattform benutzt.

**Nicht erlaubt ist alles andere**, und zwar mit Absicht: keine anderen
Namespaces, keine Knoten, keine ClusterRoles, kein Vergeben von Rechten. Die
Rolle ist eine `Role`, keine `ClusterRole` — sie endet an der Grenze des
Namespace.

Die Kubeconfig trägt ein gültiges Token und ist deshalb von `.gitignore`
ausgeschlossen. Sie gehört dem Mandanten, nicht dem Repo.

## Geheimnisse

Warum hier ein Geheimnisspeicher steht, was er im Betrieb bringt und was er auf
diesem Laptop **nicht** leistet — dazu die Abgrenzung zu CredHub auf der
CF-Seite: [GEHEIMNISSE.md](GEHEIMNISSE.md).

Kurz: Jeder Mandant bekommt beim Anlegen einen eigenen Pfad
`mandanten/<name>/`, eine Policy darauf, eine Anmelderolle, ein Anmeldeskript
und einen `SecretStore` in seinem Namespace. **Werte legt er selbst ab** — mit
dem Token, das ohnehin in seiner Kubeconfig steht; die Anwendung holt sie über
ein `ExternalSecret`. In Git steht dann eine Referenz, nie ein Wert.

`make apps-geheimnis` bleibt dem Betreiber für Übernahmen und Notfälle.

## Für Mandanten: [BEFEHLE.md](BEFEHLE.md)

Alles zum Kopieren, in der Reihenfolge, in der man es braucht — Zugang setzen,
Anwendung ausrollen, veröffentlichen, Datenbank anlegen und einbinden,
Fehlersuche, Abräumen. Jeder Befehl dort ist einmal gelaufen; was danebensteht,
ist die Ausgabe, die dabei kam.

Die Kurzfassung:

## Eine Anwendung ausrollen

Aus Sicht des Mandanten, mit seiner Kubeconfig:

```bash
export KUBECONFIG="$PWD/apps/kubeconfig-anna.yaml"

kubectl create deployment hallo --image=nginx
kubectl expose deployment hallo --port=80
kubectl create ingress hallo --rule="hallo.k8s.127-0-0-1.nip.io/*=hallo:80"

curl http://hallo.k8s.127-0-0-1.nip.io:8080
```

Eine Datenbank dazu:

```bash
kubectl apply -f - <<'EOF'
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: meine-db
spec:
  instances: 1
  storage:
    size: 1Gi
  bootstrap:
    initdb:
      database: appdb
      owner: app
EOF
```

CNPG legt Benutzer und Passwort selbst an; sie stehen im Secret
`meine-db-app`, das die Anwendung als Umgebungsvariablen einbinden kann.

## Die Ingressklasse ist der Standard — und das musste sie werden

`kubectl create ingress` ohne `--class` erzeugt einen Ingress **ohne**
Klassenangabe. Ist keine Klasse als Standard markiert, fühlt sich kein
Controller zuständig: Der Ingress steht da, der Aufruf endet in einem `404`,
und nichts im Cluster meldet einen Fehler. Genau so lief der erste Versuch.

Deshalb trägt `nginx` hier `ingressclass.kubernetes.io/is-default-class: true`,
und `apps-verify` prüft das. Ein Mandant soll den Befehl oben tippen können,
ohne eine Klasse zu kennen.

Zu wissen: Der Standard wirkt beim **Anlegen**. Ein Ingress, der vorher ohne
Klasse entstand, bleibt ohne — er muss neu erstellt werden.

## Einen Mandanten wieder entfernen

```
make apps-mandant-weg NAME=anna
```

Zeigt erst, was im Namespace liegt, und fragt dann nach. Mit dem Namespace
verschwinden auch Datenbanken und deren Datenträger.

## Warum `apps-verify` den Weg prüft und nicht die Pods

Ein Ingress-Controller, der läuft, dessen Port am Wirt aber nicht ankommt,
sieht von innen gesund aus und ist für jeden Nutzer unerreichbar. Der Lauf
fragt deshalb von **außen** an und erwartet `404` — der Controller lebt und
kennt die angefragte Adresse nur nicht. Das ist hier die richtige Antwort.

Zusätzlich prüft er, dass in diesem Cluster **kein Broker** liegt. Fände sich
einer, wäre etwas verwechselt worden: Der Broker gehört zur Plattform, nicht zu
den Anwendungen.

## Was noch fehlt

- ~~Metriken~~ — erledigt: `make apps-metrics` macht diesen Cluster im
  Observability-Cluster sichtbar (Dashboard „Anwendungs-Cluster"). Der Zugang
  ist ein ServiceAccount, der nur Metriken lesen darf; die Einzelheiten stehen
  in [`../observability/README.md`](../observability/README.md).
- **TLS.** Die Anwendungen sprechen heute nur HTTP. Für echte Zertifikate
  bräuchte es cert-manager wie auf der Plattform.
- **Zugänge auf Zeit für Datenbanken.** OpenBao kann kurzlebige
  Postgres-Benutzer erzeugen statt fester Passwörter — dafür bräuchte er einen
  Verwaltungszugang zu jeder Mandanten-Datenbank, und die entstehen dynamisch.
- **Grenzen je Mandant.** Es gibt keine ResourceQuota — ein Mandant kann heute
  so viel Speicher anfordern, wie der Laptop hergibt.
