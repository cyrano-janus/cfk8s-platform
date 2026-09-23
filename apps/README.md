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
make apps-mandant NAME=anna       # Namespace, Rechte, Kubeconfig für "anna"
make apps-verify                  # trägt der Weg von außen?
```

| | |
|---|---|
| Adressen der Anwendungen | `http://<name>.k8s.127-0-0-1.nip.io:8080` |
| Kubeconfig eines Mandanten | `apps/kubeconfig-<name>.yaml` (lokal, nie im Repo) |

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

- **Metriken.** Der Observability-Cluster sieht diesen hier noch nicht. Der Weg
  dorthin ist derselbe wie beim Broker — Knotenport, Docker-DNS, ScrapeConfig —
  und damit eine Datei, kein Umbau.
- **TLS.** Die Anwendungen sprechen heute nur HTTP. Für echte Zertifikate
  bräuchte es cert-manager wie auf der Plattform.
- **Grenzen je Mandant.** Es gibt keine ResourceQuota — ein Mandant kann heute
  so viel Speicher anfordern, wie der Laptop hergibt.
