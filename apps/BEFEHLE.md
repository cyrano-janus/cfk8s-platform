# Befehle: eine Anwendung im Anwendungs-Cluster

Alles zum Kopieren, in der Reihenfolge, in der man es braucht. Jeder Befehl
hier ist einmal gelaufen; was danebensteht, ist die Ausgabe, die dabei kam.

Die Beispiele heißen durchgehend `meine-app` und `meine-db` — für etwas
anderes den Namen an allen Stellen ersetzen.

---

## Bevor es losgeht

**Den Namespace legst du nicht selbst an.** Deine Zugangsdaten gelten für
genau einen Namespace, und das Anlegen weiterer ist dir bewusst verwehrt — ein
Mandant soll seinen Nachbarn nicht sehen. Wer einen Namespace braucht, bittet
den Betreiber der Plattform darum; der führt einen Befehl aus

```bash
make apps-mandant NAME=<dein-name>
```

und händigt die entstandene Datei `kubeconfig-<dein-name>.yaml` aus. Darin
steckt alles: Adresse des Clusters, dein Namespace, dein Zugangsschlüssel.

Gebraucht wird außerdem **`kubectl`** auf dem eigenen Rechner. Prüfen mit
`kubectl version --client`.

---

## 0. Zugang setzen

Einmal pro Terminal:

```bash
export KUBECONFIG="/pfad/zu/kubeconfig-meinname.yaml"
```

Dein Namespace steckt schon darin — **kein `-n` nötig**, und du landest nie
versehentlich woanders.

## 1. Nachsehen, ob es geht

```bash
kubectl get pods
```

Beim ersten Mal kommt `No resources found in <dein-name> namespace.` Das ist
die richtige Antwort: Der Zugang steht, und es läuft noch nichts.

---

## 2. Eine Anwendung ausrollen

```bash
kubectl create deployment meine-app --image=nginx:alpine
kubectl expose deployment meine-app --port=80
```

```
deployment.apps/meine-app created
service/meine-app exposed
```

Warten, bis sie läuft:

```bash
kubectl rollout status deploy/meine-app
```

## 3. Von außen erreichbar machen

```bash
kubectl create ingress meine-app \
  --rule="meine-app.k8s.127-0-0-1.nip.io/*=meine-app:80"
```

Danach:

```bash
curl http://meine-app.k8s.127-0-0-1.nip.io:8080
```

**Der Port 8080 gehört dazu**, auch wenn es ungewohnt aussieht: Die Ports 80
und 443 des Rechners sind von Cloud Foundry belegt, deshalb liegt dieser
Cluster daneben auf 8080 (und 8443 für https).

Die Adresse darfst du frei wählen, solange sie auf `.k8s.127-0-0-1.nip.io`
endet. `nip.io` löst jeden solchen Namen auf `127.0.0.1` auf — es muss nichts
eingetragen werden.

---

## 4. Wenn etwas nicht geht

```bash
kubectl get pods                      # läuft es überhaupt?
kubectl describe pod <pod-name>       # warum nicht? (unten unter "Events")
kubectl logs deploy/meine-app         # was sagt die Anwendung selbst?
kubectl logs deploy/meine-app -f      # mitlesen, während es passiert
kubectl exec -it deploy/meine-app -- sh   # in den Container hinein
```

---

## 5. Eine Datenbank

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

Zusehen, bis sie steht (dauert etwa eine Minute):

```bash
kubectl get cluster.postgresql.cnpg.io -w
```

```
meine-db   41s   1   1   Cluster in healthy state   meine-db-1
```

**Benutzer und Passwort vergibst du nicht** — der Operator erzeugt sie und legt
sie in ein Secret namens `meine-db-app`:

```bash
kubectl get secret meine-db-app -o go-template='{{range $k,$v := .data}}{{$k}} {{end}}'
```

```
dbname fqdn-jdbc-uri fqdn-uri host jdbc-uri password pgpass port uri user username
```

Einen einzelnen Wert ansehen:

```bash
kubectl get secret meine-db-app -o jsonpath='{.data.host}' | base64 -d
```

## 6. Die Datenbank in die Anwendung einbinden

Der bequemste Weg ist `envFrom`: Damit werden **alle** Felder des Secrets zu
Umgebungsvariablen im Container.

```bash
kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: meine-app
spec:
  replicas: 1
  selector:
    matchLabels: { app: meine-app }
  template:
    metadata:
      labels: { app: meine-app }
    spec:
      containers:
        - name: web
          image: nginx:alpine
          ports:
            - containerPort: 80
          envFrom:
            - secretRef:
                name: meine-db-app
EOF
```

Nachsehen, ob die Werte angekommen sind:

```bash
kubectl exec deploy/meine-app -- sh -c 'echo $host $port $dbname $username'
```

```
meine-db-rw 5432 appdb app
```

Deine Anwendung liest also `$host`, `$port`, `$dbname`, `$username`,
`$password` — oder gleich `$uri`, die alles in einer Zeichenkette enthält.

**Gegenprobe, ob die Datenbank wirklich antwortet.** Ein Wegwerf-Pod, der
dieselben Zugangsdaten benutzt wie deine Anwendung:

```bash
kubectl run dbtest --image=postgres:16-alpine --restart=Never \
  --overrides='{"spec":{"containers":[{"name":"dbtest","image":"postgres:16-alpine","envFrom":[{"secretRef":{"name":"meine-db-app"}}],"command":["sh","-c","PGPASSWORD=$password psql -h $host -U $username -d $dbname -c \'select version();\' -t -A"]}]}}'

kubectl logs dbtest
kubectl delete pod dbtest
```

```
PostgreSQL 18.4 (Debian 18.4-1.pgdg13+1) on x86_64-pc-linux-gnu, ...
```

Kommt diese Zeile, steht alles: Netzweg, Zugangsdaten, Datenbank.

---

## 7. Eine neue Version ausrollen

```bash
kubectl set image deploy/meine-app web=nginx:1.27-alpine
kubectl rollout status deploy/meine-app
```

Zurück, wenn es schiefging:

```bash
kubectl rollout undo deploy/meine-app
```

## 8. Abräumen

```bash
kubectl delete ingress meine-app
kubectl delete service meine-app
kubectl delete deployment meine-app
kubectl delete cluster.postgresql.cnpg.io meine-db   # LÖSCHT DIE DATEN
```

---

## Was nicht geht — und warum

Diese Befehle scheitern mit `Forbidden`, und das ist Absicht:

```bash
kubectl get namespaces        # fremde Namespaces sehen
kubectl get pods -n kube-system
kubectl get nodes             # den Cluster selbst ansehen
```

```
Error from server (Forbidden): namespaces is forbidden: User
"system:serviceaccount:meinname:meinname-deployer" cannot list resource
"namespaces" in API group "" at the cluster scope
```

Deine Rechte enden an der Grenze deines Namespace. Innerhalb davon darfst du
alles, was zum Betreiben einer Anwendung gehört; außerhalb nichts. Wer mehr
braucht, spricht mit dem Betreiber.

---

## Häufige Stolpersteine

**`curl` bekommt 404, obwohl alles läuft.** Zwei Ursachen sind häufig:

- Der Port fehlt. Es ist `:8080`, nicht der Standardport.
- Der Hostname im Ingress stimmt nicht mit dem aufgerufenen überein. Prüfen
  mit `kubectl get ingress` — die Spalte `HOSTS` muss genau das enthalten, was
  im `curl` steht.

**Der Pod bleibt `Pending`.** Meist fehlt Platz oder ein Datenträger.
`kubectl describe pod <name>` nennt den Grund unter *Events*.

**`ImagePullBackOff`.** Der Image-Name stimmt nicht, oder das Image liegt in
einer Registry, die der Cluster nicht erreicht.

**Die Datenbank bleibt in `Setting up primary`.** Das ist normal und dauert
etwa eine Minute — `kubectl get cluster.postgresql.cnpg.io -w` zeigt den
Fortschritt.

**`error: You must be logged in to the server (Unauthorized)`.** Die
Kubeconfig zeigt auf einen Cluster, der neu gebaut wurde; das alte Token gilt
nicht mehr. Beim Betreiber eine neue anfordern.
