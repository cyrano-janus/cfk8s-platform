# Zugang für eine eigene Anwendung

Für den Fall, dass eine Anwendung in diesem Cluster ihre eigene Datenbank
betreiben soll — direkt am CNPG-Operator, **nicht** über den OSB-Broker.

```
make app-access          # Namespace, Rechte und Kubeconfig anlegen
make app-access-revoke   # Zugang sperren, Daten behalten
```

Erzeugt wird `access/kubeconfig-app.yaml` (nicht im Git). Damit:

```
export KUBECONFIG="$PWD/access/kubeconfig-app.yaml"
kubectl apply -f access/beispiel-datenbank.yaml
kubectl get cluster meine-db -w
```

CNPG legt die Zugangsdaten selbst als Secret ab — sie werden nirgends vergeben:

```
kubectl get secret meine-db-app -o jsonpath='{.data.uri}' | base64 -d
```

Läuft die Anwendung außerhalb des Clusters, führt der Weg über einen Tunnel;
das Recht dazu ist in der Role enthalten:

```
kubectl port-forward svc/meine-db-rw 5432:5432
```

## Was dieser Zugang kann — und was nicht

Rechte bestehen **nur** im Namespace `app-dev` (`APP_NAMESPACE` in
`versions.env`): Datenbanken und die übrigen CNPG-Objekte, Secrets und
ConfigMaps, Deployments, Services, Jobs, dazu Lesen und Neustarten von Pods,
Logs, `exec` und `port-forward`. Die vollständige Liste mit Begründung je Block
steht in [app-access.yaml](app-access.yaml).

Nicht möglich sind: Zugriff auf Cloud Foundry, den Broker, cert-manager oder
die Operatoren; Lesen fremder Secrets; das Anlegen von Namespaces; jede Sicht
auf Knoten oder andere clusterweite Objekte. `make app-access` prüft das bei
jedem Lauf nach, in beide Richtungen — erlaubt *und* verboten.

## Grenzen, die bleiben

**Nur auf diesem Rechner.** kind bindet den API-Server an `127.0.0.1`. Von
einem anderen Rechner oder aus einem Container ohne Host-Netz ist die Adresse
in der Kubeconfig nicht erreichbar. Ein Container am Docker-Netz `kind` müsste
stattdessen `https://cfk8s-control-plane:6443` verwenden — dann trägt das
Serverzertifikat den Namen mit; von außerhalb des Wirts bräuchte es einen
SSH-Tunnel, und der Name im Zertifikat wäre zu prüfen.

**Der Port wechselt.** kind vergibt den Port des API-Servers bei jedem Anlegen
des Clusters neu. Nach `make cf-up` ist die Kubeconfig darum ungültig —
`make app-access` schreibt sie neu.

**Getrennt vom Broker.** `osb-instances` gehört dem Broker; eine fremde
Datenbank darin sähe in einer Prüfung wie eine von ihm angelegte aus. Deshalb
ein eigener Namespace, und deshalb verweigert die Role den Zugriff auf den
anderen.

**Der Cluster ist nicht groß.** Neben Cloud Foundry, dem Broker und den
Operatoren ist wenig Luft. Datenbanken hier gehören mit `resources` versehen,
sonst verdrängen sie im Zweifel CF-Komponenten vom Knoten.
