# Befehle: Datenbank im Namespace `app-dev`

Alles zum Kopieren, in der Reihenfolge, in der man es braucht. Nichts hier
setzt ein Skript voraus.

Die Beispiele heißen durchgehend `meine-db` — für eine andere Datenbank den
Namen an allen Stellen ersetzen.

---

## 0. Zugang setzen

Einmal pro Terminal, aus dem Repo-Verzeichnis:

```bash
export KUBECONFIG="$PWD/access/kubeconfig-app.yaml"
```

Der Namespace `app-dev` steckt schon darin — kein `-n` nötig.

Gibt es die Datei nicht, oder wurde der Cluster neu gebaut:

```bash
make app-access
```

---

## 1. Datenbank anlegen

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
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      memory: 512Mi
EOF
```

Benutzer und Passwort werden **nicht** vergeben — CNPG erzeugt sie (Schritt 3).

---

## 2. Zusehen, bis sie steht

```bash
kubectl get cluster meine-db -w
```

Fertig bei `Cluster in healthy state`. Abbrechen mit Strg-C.

Oder warten, statt zuzusehen:

```bash
kubectl wait --for=condition=Ready cluster/meine-db --timeout=300s
```

Was dazugehört:

```bash
kubectl get pods,pvc,svc -l cnpg.io/cluster=meine-db
```

---

## 3. Zugangsdaten holen

Der komplette Verbindungs-URI:

```bash
kubectl get secret meine-db-app -o jsonpath='{.data.uri}' | base64 -d; echo
```

Einzelne Werte:

```bash
kubectl get secret meine-db-app -o jsonpath='{.data.username}' | base64 -d; echo
kubectl get secret meine-db-app -o jsonpath='{.data.password}' | base64 -d; echo
kubectl get secret meine-db-app -o jsonpath='{.data.dbname}'   | base64 -d; echo
```

Für Java:

```bash
kubectl get secret meine-db-app -o jsonpath='{.data.jdbc-uri}' | base64 -d; echo
```

---

## 4. Verbinden

**Läuft die Anwendung im Cluster**, genügt der Host aus dem URI:
`meine-db-rw` (Schreiben und Lesen) bzw. `meine-db-ro` (nur Lesen).

**Läuft sie außerhalb**, zuerst einen Tunnel öffnen — das Terminal bleibt
belegt, Strg-C beendet ihn:

```bash
kubectl port-forward svc/meine-db-rw 5432:5432
```

In einem zweiten Terminal verbindet sich die Anwendung dann gegen
`127.0.0.1:5432` — Benutzer, Passwort und Datenbankname aus Schritt 3.

**Eine SQL-Eingabe braucht dafür keinen Tunnel.** `psql` ist auf diesem Rechner
nicht installiert, im Datenbank-Pod aber schon:

```bash
kubectl exec -it meine-db-1 -- psql -U postgres appdb
```

Einzelne Abfrage ohne Sitzung:

```bash
kubectl exec meine-db-1 -- psql -U postgres appdb -c 'select version();'
```

(`kubectl` meldet dabei `Defaulted container "postgres"` — das ist nur ein
Hinweis, dass der Pod zwei Container hat, kein Fehler.)

Wer `psql` lieber auf dem Wirt hätte — `sudo apt install postgresql-client` —,
verbindet sich durch den Tunnel so:

```bash
PGPASSWORD=$(kubectl get secret meine-db-app -o jsonpath='{.data.password}' | base64 -d) \
  psql -h 127.0.0.1 -p 5432 -U app -d appdb
```

---

## 5. Wenn etwas klemmt

```bash
kubectl get events --sort-by=.lastTimestamp | tail -20
kubectl describe cluster meine-db | tail -30
kubectl logs -l cnpg.io/cluster=meine-db --tail=50
```

---

## 6. Datenbank vollständig löschen

**Das löscht die Daten. Es gibt kein Zurück.**

```bash
kubectl delete cluster meine-db
```

Damit verschwinden Pod, Services und die vier Secrets. Danach **nachsehen** —
gemessen bleiben PVC und Pod noch einen Moment stehen:

```bash
kubectl get cluster,pod,pvc,svc,secret | grep meine-db
```

Was dort noch auftaucht, gezielt entfernen:

```bash
kubectl delete pvc,pod -l cnpg.io/cluster=meine-db --ignore-not-found
```

Ein übrig gebliebenes Volume belegt Speicher und ließe eine später gleich
benannte Datenbank auf den alten Daten aufsetzen.

Blieben Secrets zurück — nur `meine-db-app` trägt das Label, die anderen drei
findet man nur über den Namen:

```bash
kubectl delete secret meine-db-app meine-db-ca meine-db-server meine-db-replication --ignore-not-found
```

Am Ende muss das hier leer sein:

```bash
kubectl get cluster,pod,pvc,svc,secret | grep meine-db
```

---

## 7. Zugang sperren

Der Namespace und alle Datenbanken darin bleiben bestehen, nur das Token
verschwindet:

```bash
make app-access-revoke
```

Neues Token: `make app-access`.
