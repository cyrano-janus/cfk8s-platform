# Befunde aus dem Korifi-Durchlauf

Messprotokoll aus Phase 6/7, aufgenommen am 2026-09-01 gegen Korifi v0.18.0 und
`osb-broker-go@afec30e`. Dies ist die Eingabe für die Spec-Arbeit (Phase 9).

Jeder Befund nennt Beobachtung, verifizierte Ursache mit Codestelle und einen
Vorschlag. Reihenfolge nach Schwere.

**Status des Gesamtdurchlaufs:** Der Lifecycle funktioniert Ende-zu-Ende —
`cf marketplace` → `create-service` → `bind-service` → PostgreSQL-Credentials in
`VCAP_SERVICES` → `unbind` → `delete-service` mit korrektem Abräumen des
CNPG-Clusters. Zwei plattformseitige Umgehungen sind dafür nötig (#1, #2).

Zweimal verifiziert: einmal inkrementell während des Aufbaus, einmal vollständig
von null nach `make reset` (Cluster gelöscht und neu erstellt). Der zweite Lauf
lief ohne Eingriff durch und erzeugte ein bit-identisches Builder-Image
(`sha256:67b74403…`) — die Versions-Pins greifen also.

**Die vier wichtigsten Befunde in einem Satz:** Der Broker antwortet synchron,
obwohl er einen Async-Apparat hat (#4); er liest Space/Org aus dem falschen Teil
des OSB-Requests und legt darum alles in `default` ab (#3); die Credentials, die
er weitergibt, enthalten einen aus der App nicht auflösbaren Hostnamen (#5); und
sein Helm-Chart erteilt eine RBAC-Berechtigung, die Kubernetes nie gewährt (#1).

---

> **Plattformwechsel am 2026-09-06.** Die Befunde #1 bis #29 sind auf der
> Vorgängerplattform entstanden (Korifi, ein Nachbau der CF-API). Sie bleiben
> stehen, weil die allermeisten den **Broker** betreffen und nicht die
> Plattform — was am Broker gefunden wurde, gilt weiter. Wo ein Befund
> ausdrücklich Korifi betrifft, steht es dort. Ab #30 ist die Plattform echtes
> Cloud Foundry (`cloud_controller_ng`).


## #1 — Chart-Role autorisiert `create` nie (RBAC-Subtilität)

**Schwere:** blockierend · **Repo:** osb-broker-go · **Gelöst:** ja

**Gelöst in Phase 5:** Der Zustand liegt in eigenen Ressourcenarten, nicht mehr
in einem einzelnen Objekt einer geteilten. Damit gibt es kein `resourceNames`
mehr, an dem `create` scheitern könnte; `broker/rbac-state-workaround.yaml` ist
entfernt.

**Beobachtung:** Jedes Provision scheitert mit HTTP 500:

```
record instance: create state configmap: configmaps is forbidden:
User "system:serviceaccount:osb-broker:osb-broker" cannot create resource
"configmaps" in API group "" in the namespace "osb-broker"
```

**Ursache:** `deploy/helm/osb-broker-go/templates/role-state.yaml` fasst in *einer*
Regel zusammen:

```yaml
verbs: [get, create, update]
resourceNames: [<fullname>-state]
```

Kubernetes-RBAC kann `create` nicht über `resourceNames` einschränken: beim Create
steht der Objektname im Request-*Body*, nicht im Pfad — zum
Autorisierungszeitpunkt existiert also kein Name, gegen den geprüft werden könnte.
Die Regel autorisiert `create` deshalb niemals. Das fällt erst beim allerersten
Provision auf, weil die ConfigMap bis dahin nicht existiert.

**Vorschlag:** zwei Regeln statt einer.

```yaml
rules:
- apiGroups: [""]
  resources: ["configmaps"]
  verbs: ["create"]              # ohne resourceNames
- apiGroups: [""]
  resources: ["configmaps"]
  resourceNames: [<fullname>-state]
  verbs: ["get", "update"]
```

**Umgehung:** `broker/rbac-state-workaround.yaml` liefert die fehlende
create-Regel plattformseitig nach. Nach dem Chart-Fix ersatzlos löschen.

---

## #2 — ConfigMap-Name doppelt definiert, Chart und Code driften auseinander

**Schwere:** blockierend · **Repo:** osb-broker-go · **Gelöst:** ja

**Gelöst in Phase 5:** Es gibt keinen hartcodierten Objektnamen mehr - die
Objektnamen leiten sich aus der jeweiligen OSB-ID ab, und das RBAC gilt für die
Ressourcenart. Der `BROKER_FULLNAME`-Zwang ist damit weg (der feste Name bleibt
nur, weil die Registrierungs-URL darauf zeigt).

**Beobachtung:** Vor der Umgehung von #1 erschien zunächst:

```
load state configmap: configmaps "osb-broker-state" is forbidden ...
```

Auffällig: die Role erlaubte `osb-broker-go-state`, angefragt wurde
`osb-broker-state`.

**Ursache:** Der Name existiert zweimal, unabhängig voneinander:

- `internal/broker/k8sstate.go:25` — `stateConfigMapName = "osb-broker-state"` (hartcodiert)
- `templates/role-state.yaml` — `resourceNames: [{{ fullname }}-state]`

Beide stimmen nur überein, wenn der Helm-Fullname exakt `osb-broker` ist. Beim
naheliegenden Release-Namen `osb-broker-go` erlaubt die Role eine ConfigMap, die
der Code nie anfragt.

**Vorschlag:** Namen konfigurierbar machen (`STATE_CONFIGMAP_NAME`, Default
`osb-broker-state`), im Chart als Env setzen und die Role daraus ableiten — eine
Quelle, kein Drift.

**Umgehung:** `fullnameOverride: osb-broker` in `broker/values.korifi.yaml`.

---

## #3 — Space- und Org-GUID kommen nie an: alle Instanzen landen in `default`

**Schwere:** architektonisch, hoch · **Repo:** osb-broker-go · **Gelöst:** ja

**Gelöst:** `ProvisionRequest` hat jetzt die Top-Level-Felder, und
`ResolvedContext()` führt beide erlaubten Quellen zusammen — `context` hat
Vorrang, Top-Level ergänzt fehlende Felder. Am laufenden Cluster nachgewiesen:
`cf create-service cnpg-postgresql` legt den Cluster im Space-Namespace an.

**Beobachtung:** Die `CFServiceInstance` liegt im Space-Namespace
(`55c8141c-…`), der CNPG-`Cluster` dagegen in **`default`** — nicht im
Space-Namespace und auch nicht im Broker-Namespace.

**Ursache — und hier liegt die Überraschung: der Broker macht es fast richtig.**
`internal/handlers/definition_instances.go:105`:

```go
func targetNamespace(ctx broker.Context) string {
	if ctx.SpaceGUID != "" { return ctx.SpaceGUID }
	return "default"
}
```

Die Space→Namespace-Abbildung ist also bereits implementiert. Sie greift nur
nicht, weil `ctx.SpaceGUID` leer ankommt:

- **Broker** (`internal/broker/types.go:19`) liest Space/Org **ausschließlich** aus
  dem verschachtelten `context`-Objekt. `ProvisionRequest` hat keine Top-Level-Felder.
- **Korifi** (`controllers/controllers/services/osbapi/types.go:73`) sendet
  `space_guid` und `organization_guid` **ausschließlich** als Top-Level-Felder und
  schickt überhaupt kein `context`-Objekt.

Beides ist OSB-konform — die Spezifikation kennt beide Varianten (Top-Level gilt
als veraltet, wird von CF aber weiter gesendet). Die zwei Implementierungen haben
sich für verschiedene Hälften entschieden.

**Folge:** Kein Mandantentrennung bei den Backing-Ressourcen. Alle Spaces teilen
`default`; Quotas, NetworkPolicies und `kubectl`-Sichtbarkeit sind nicht getrennt.
Zusätzlich braucht der Broker dadurch clusterweite Rechte, die bei
Space-Namespaces feiner geschnitten sein könnten.

**Vorschlag:** `ProvisionRequest` um Top-Level-Felder erweitern und beide Quellen
auswerten — `context` bevorzugt, Top-Level als Fallback:

```go
type ProvisionRequest struct {
    ...
    OrganizationGUID string `json:"organization_guid,omitempty"` // OSB <=2.12 / CF
    SpaceGUID        string `json:"space_guid,omitempty"`
}
```

Das ist eine kleine Änderung mit großer Wirkung: sie behebt #3 **und** #5.

---

## #4 — Provision antwortet synchron (201), der Async-Apparat läuft nie

**Schwere:** hoch, verletzt stillschweigend den Vertrag · **Repo:** osb-broker-go

**Beobachtung:** `cf create-service cnpg-postgresql small` meldet nach **16 Sekunden**
`Ready=True`. Zum selben Zeitpunkt:

```
CNPG-Cluster phase: Setting up primary
  Ready   status=False   reason=ClusterIsNotReady
initdb-Pod: PodInitializing
```

Direkte Messung des Provision-Requests mit `accepts_incomplete=true`:

```
PROVISION-HTTP=201
BODY={"dashboard_url":"https://dashboard.example.com/instances/timing-test"}
```

Request-Zählung im Broker-Log über den ganzen Lifecycle:

```
  3x  GET  catalog                              -> 200
  1x  PUT  service_instances/<guid>             -> 201
  1x  PUT  service_instances/<guid>/service_... -> 201
  0x  GET  .../last_operation
```

**Ursache:** Der Broker antwortet `201 Created` statt `202 Accepted` und liefert
kein `operation`-Feld — obwohl der Client `accepts_incomplete=true` gesendet hat.
Nach OSB-Spezifikation bedeutet 201 „Provisionierung abgeschlossen". Korifi
glaubt das korrekt, markiert die Instanz sofort als ready und fragt
`last_operation` folgerichtig **nie** ab.

**Folge:** Der `readiness`-Block der ServiceDefinition ist in diesem Pfad toter
Code — inklusive `timeoutSeconds: 600`. `EvaluateReadiness` ist selbst korrekt
implementiert (`internal/definition/readiness.go`, fehlende Condition = nicht
ready), wird aber nicht aufgerufen. Praktische Auswirkung: eine App, die
unmittelbar nach `cf create-service` gebunden und gestartet wird, trifft auf eine
Datenbank, die noch initialisiert. Bei `plan large` (3 Instanzen, 10Gi) ist das
Fenster deutlich größer als hier.

**Vorschlag:** Bei `accepts_incomplete=true` mit `202 Accepted` und einem
`operation`-Key antworten, und `last_operation` aus `EvaluateReadiness` speisen —
die Bausteine existieren alle schon. Bei `accepts_incomplete=false` schreibt die
Spezifikation `422 UnprocessableEntity` vor, wenn der Service nicht synchron
provisionieren kann. Gleiches gilt für `bind`.

---

## #5 — Der `host` in den Credentials ist aus der App nicht auflösbar

**Schwere:** hoch (Apps können sich nicht verbinden) · **Repo:** osb-broker-go

**Beobachtung:** `VCAP_SERVICES` enthält korrekte Credentials, aber:

```
Test 1 (host aus credentials, kurzer Name):
  psql: could not translate host name
        "osb-8d06e8a5-...-rw" to address: Try again
Test 2 (fqdn-uri):
  app|app            <- funktioniert
```

Getestet aus dem Space-Namespace, in dem die App läuft.

**Ursache:** Der Broker gibt die Keys des CNPG-Secrets unverändert durch. CNPG
schreibt namespace-relative Service-Namen, weil es Konsum im *selben* Namespace
annimmt. Da die Instanz in `default` liegt und die App im Space-Namespace, ist der
kurze Name dort nicht auflösbar. CNPG liefert zusätzlich `fqdn-uri` und
`fqdn-jdbc-uri`, die funktionieren — aber eine App, die nach Konvention `host`
und `port` liest, scheitert.

**Vorschlag:** Zwei Wege, der erste ist der bessere:

1. #3 beheben — dann liegt die Instanz im Space-Namespace und der kurze Name löst auf.
2. Ergänzend in der `bind`-Konfiguration ein Key-Mapping erlauben, das `host` auf
   den FQDN umschreibt. Nützlich unabhängig von #3, wenn Instanzen bewusst
   zentral liegen sollen.

**Nachtrag 2026-09-02:** Dieser Befund ist **CNPG-spezifisch, nicht generisch**.
Der RabbitMQ-Operator schreibt in dasselbe Feld einen namespace-qualifizierten
Namen (`osb-<id>.<namespace>.svc`), der auch aus einem anderen Namespace auflöst.
Die Ursache liegt also nicht im Durchgeben der Operator-Keys, sondern in CNPGs
Annahme, konsumiert werde im selben Namespace. Ein Key-Mapping bleibt sinnvoll,
ist aber kein Muss für die Engine.

---

## #6 — Fehlgeschlagenes Provision hinterlässt unsichtbare Leichen

**Schwere:** mittel · **Repo:** osb-broker-go

**Beobachtung:** Nach drei fehlgeschlagenen Provisions (HTTP 500) existierten drei
CNPG-Cluster in `default`, während die State-ConfigMap
`{"instances":{},"bindings":{}}` enthielt — also leer war. Die Cluster waren für
den Broker unsichtbar und mussten per `kubectl` entfernt werden.

**Ursache:** Die Reihenfolge im Fehlertext verrät es: `record instance: create
state configmap: ...`. Die CR wird **zuerst** erzeugt, **danach** der State
geschrieben. Scheitert der zweite Schritt, gibt es kein Rollback der CR und keinen
State-Eintrag — die Ressource ist verwaist und für den Broker nicht mehr
auffindbar. Bei echten Backing-Services heißt das: laufende Datenbanken, die
niemand mehr abräumt.

**Vorschlag:** State-Eintrag zuerst schreiben (Status `provisioning`), dann die CR
erzeugen, dann Status aktualisieren. Alternativ die CR bei Fehlern im zweiten
Schritt kompensierend löschen. Ein Reconcile-Lauf, der CRs mit
`osb.io/instance-id`-Label ohne State-Eintrag findet, wäre die robustere Lösung.

---

## #7 — `targetNamespaceFromQuery` ignoriert den Namespace (latent)

**Schwere:** latent, wird durch den Fix von #3 aktiviert · **Repo:** osb-broker-go · **Gelöst:** ja

**Gelöst:** Die Funktion ist ersatzlos entfernt; der Namespace kommt aus dem
gespeicherten Datensatz. Nachgewiesen: `cf delete-service` entfernt den
CNPG-Cluster im Space-Namespace wirklich, statt in `default` ins Leere zu
löschen und Erfolg zu melden.

**Beobachtung:** Aktuell unauffällig, weil provision und deprovision beide in
`default` landen.

**Ursache:** `internal/handlers/definition_instances.go:113`:

```go
func targetNamespaceFromQuery(c *gin.Context) string {
	return "default"          // immer, ohne Auswertung
}
```

Deprovision ermittelt den Namespace also gar nicht. Sobald #3 behoben ist und
Provision in den Space-Namespace schreibt, löscht Deprovision im falschen
Namespace. Da `OperatorClient.Delete` `IsNotFound` ignoriert
(`internal/definition/operator.go:83`), meldet der Broker **Erfolg** — und die
Datenbank läuft weiter.

**Vorschlag:** Aus dem State Store lesen statt neu ableiten — und das ist
einfacher als gedacht, denn **die Information liegt bereits dort**. Ein
State-Eintrag aus dem Durchlauf:

```json
"AppliedRefs": [{
  "APIVersion": "postgresql.cnpg.io/v1",
  "Kind": "Cluster",
  "Namespace": "default",          <-- schon gespeichert
  "Name": "osb-timing-test"
}]
```

`targetNamespaceFromQuery` durch einen Lookup in `AppliedRefs` zu ersetzen behebt
den Befund vollständig, ohne neue Datenhaltung. Das ist auch der einzig korrekte
Weg, weil der OSB-Deprovision-Request weder `context` noch `space_guid` enthält —
der Namespace ist zu diesem Zeitpunkt aus dem Request grundsätzlich nicht
herleitbar.

---

## #8 — Korifi erwartet Broker-Credentials als JSON in EINEM Secret-Key

**Schwere:** Dokumentationsfalle · **Repo:** korifi-platform · **Gelöst:** ja

**Beobachtung:** Ein Secret mit getrennten Keys `username`/`password` ergibt:

```
OSBAPIClientCreationFailed: failed to unmarshal broker credentials secret:
unexpected end of JSON input
```

**Ursache:** `controllers/controllers/services/osbapi/clientfactory.go` liest
`secret.Data["credentials"]` und `json.Unmarshal`t den Inhalt. Erwartet wird:

```yaml
data:
  credentials: <base64 von {"username":"...","password":"..."}>
```

Die Konstanten `UsernameCredentialsKey`/`PasswordCredentialsKey` in
`controllers/api/v1alpha1/cfservicebroker_types.go` bezeichnen die Keys
*innerhalb* dieses JSON — nicht die Secret-Keys. Genau das legt die
Fehlinterpretation nahe.

**Gelöst in:** `make register-credentials`.

---

## #9 — Zwei Demo-Offerings im Marketplace

**Schwere:** kosmetisch · **Repo:** osb-broker-go

**Beobachtung:** `cf marketplace` zeigt neben `cnpg-postgresql` auch
`example-service` und `database-service`.

**Ursache:** `main.go` initialisiert `store.NewInMemoryStore()` mit zwei
hartcodierten Beispiel-Offerings, unabhängig von `DEFINITIONS_DIR`.

**Vorschlag:** hinter ein Flag legen (`INCLUDE_EXAMPLE_SERVICES`, Default aus)
oder in die Tests verschieben.

---

## #10 — Korifi füllt `plan` und `tags` in VCAP_SERVICES nicht

**Schwere:** gering · **Repo:** korifi (upstream)

**Beobachtung:** In `VCAP_SERVICES` steht `"plan": null` und `"tags": []`, obwohl
der Katalog den Plan `small` und die Tags `postgresql, database, cnpg` liefert.

**Umgang:** Apps, die auf `plan` oder `tags` reagieren, funktionieren auf Korifi
nicht wie auf CF-for-VMs. Kein Handlungsbedarf im Broker; ggf. Upstream-Issue.

---

## #11 — `cf service <name>` bricht ab

**Schwere:** gering · **Repo:** korifi (upstream)

**Beobachtung:**

```
API endpoint not found at 'https://localhost/v3/feature_flags/service_instance_sharing'
```

**Ursache:** cf CLI 8.19 fragt beim Anzeigen einer Instanz das Feature-Flag
`service_instance_sharing` ab; Korifi v0.18.0 implementiert `/v3/feature_flags`
nicht. `cf services` (Plural) funktioniert.

**Umgang:** `cf services` oder die CFServiceInstance-CR nutzen.

---

# Befunde aus dem Betrieb

Aufgenommen am 2026-09-02 beim Aufbau der Neustart-Festigkeit. Andere Quelle als
die Befunde #1–#11: die stammen aus dem Lifecycle-Durchlauf, dieser hier aus
einem Stop/Start des Node-Containers.

## #12 — `unbind` lässt den Volume-Verweis in der AppWorkload stehen

**Schwere:** hoch (App startet nach dem nächsten Pod-Neubau nie wieder) ·
**Repo:** korifi (upstream) · **Umgangen:** nein

**Beobachtung:** Nach einem Neustart des Node-Containers antwortet die App-Route
mit `503`, obwohl `make status` alle Komponenten grün zeigt:

```
curl https://go-hello.apps-127-0-0-1.nip.io/   -> HTTP 503
Pod  …-3fb-ec92c5b648-0   READY 0/1   STATUS Unknown
Event: MountVolume.SetUp failed for volume "0c959455-…-sbio"
       : secret "0c959455-…-sbio" not found
```

Der Container war beim harten Stop mit `exitCode 255`, `reason: Unknown`
beendet worden — wie jeder andere Container auch. Nur dieser kam nicht zurück.

**Ursache:** Das `unbind`/`delete-service` aus dem Lifecycle-Durchlauf hat die
`CFServiceBinding` entfernt (`kubectl get cfservicebinding -A` → keine) und das
zugehörige servicebinding.io-Secret gelöscht. Der *Verweis* darauf ist aber an
zwei Stellen stehen geblieben:

```
AppWorkload  .spec.services:
  [{"guid":"0c959455-…","name":"0c959455-…-sbio","secret":"0c959455-…-sbio"}]

StatefulSet  .spec.template.spec.volumes:
  vol=0c959455-…-sbio  secret=0c959455-…-sbio     # existiert nicht
```

**Warum es im Durchlauf nicht auffiel:** Der Pod lief zu diesem Zeitpunkt schon.
Ein bestehender Mount wird vom kubelet nicht erneut aufgelöst, also blieb die App
gesund und `unbind` sah erfolgreich aus. Erst der Pod-Neubau — nach Node-Neustart,
Reschedule, Scale oder Rolling Update — versucht den Mount neu und scheitert
dauerhaft. Zwischen Ursache und Symptom liegen damit Stunden oder ein Reboot.

**Folge:** Jede App, die einmal gebunden und wieder entbunden wurde, ist eine
Zeitbombe. `cf unbind-service` meldet Erfolg, hinterlässt die App aber in einem
Zustand, aus dem sie sich nicht mehr starten kann.

**Vorschlag:** Plattformseitig ist nichts zu beheben — Korifi müsste die
AppWorkload beim Löschen einer CFServiceBinding neu abgleichen. Kandidat für ein
Upstream-Issue, zusammen mit #10 und #11.

**Umgang:**
- Reparatur einer betroffenen App, am 2026-09-02 an `go-hello` verifiziert:
  ```
  kubectl -n <space-ns> delete appworkload <name>
  ```
  Korifi erzeugt die AppWorkload sofort neu, diesmal mit `spec.services` leer,
  und das StatefulSet kommt ohne das Volume zurück — die App antwortet danach
  wieder mit 200. `cf restart <app>` tut dasselbe über die API und ist der
  dokumentierte Weg; die CR-Variante braucht kein eingerichtetes cf CLI.
- Erkennung: `make doctor`, Check 3 („Volume-Verweise auf nicht existierende
  Secrets/ConfigMaps") nennt Pod, StatefulSet, Volume und Secret in vier Zeilen.
- `make verify-restart` trennt Ingress-Kette und App-Gesundheit in zwei Checks,
  damit dieser Fall nicht als Netzwerkproblem missgedeutet wird.

---

# Architekturbefunde am Broker

Aufgenommen am 2026-09-02 aus einer systematischen Lesung von
`osb-broker-go@afec30e`. Andere Quelle als #1–#11 (Lifecycle-Durchlauf) und #12
(Betrieb): hier wurde kein Verhalten gemessen, sondern Code gelesen. Zwei
Befunde korrigieren dabei frühere Einschätzungen aus diesem Dokument — #15
nennt die tiefere Ursache von #4, #16 zeigt, dass #3 größer ist als dort
beschrieben.

**Wo die Grenze verläuft.** Von 3.859 Zeilen Produktivcode sind ~1.700 tragfähig
und ~1.900 zu ersetzen, und die Grenze läuft zwischen den Schichten, nicht quer
durch sie. Tragfähig ist die Engine `internal/definition/` (887 Zeilen:
Multi-Doc-Apply mit `ObjectRef`-Buchführung, No-Op-Erkennung inklusive
JSON-Zahlnormalisierung `update.go:106`, `SanitizeInstanceName` `render.go:17`,
gjson-Readiness `readiness.go:20`), dazu Metrics und Logging als entkoppelte
Querschnitte und `cmd/osb-checker` (507 Zeilen). Zu ersetzen ist die HTTP-Schicht
(~880 Zeilen), `broker.go` (394), `k8sstate.go` (215) und `store.go` (131).

**Empfehlung:** HTTP- und State-Schicht ersetzen, Engine behalten. Kein
Neuschreiben des Repos — die Engine ist der teure Teil und trägt. Der Grund, warum
sich der Umbau rechnet, ist gerade, dass #3 und #4 *innerhalb* der
Doppelpfad-Struktur ohnehin ein Durchstich durch sechs Dateien sind: man zahlte
fast den Preis des Umbaus und behielte die Struktur, die das Problem erzeugt.

## #13 — Zwei vollständige Broker-Implementierungen nebeneinander

**Schwere:** strukturell, Ursache mehrerer Einzelbefunde · **Repo:** osb-broker-go

Jeder Handler verzweigt zwischen Legacy- und Definitions-Weg:
`service_instances.go:47,75,111,160`, `service_bindings.go:43,78`. Daneben lebt in
`broker.go` ein zweiter, vollständiger Broker mit eigenen `instances`/`bindings`-Maps
(`:16-18`), eigenem `generateCredentials` (`:366`) und einem Fake-Katalog aus
`internal/store/store.go`, dessen zwei Demo-Offerings im Produktivkatalog
erscheinen (`catalog.go:49-67`). #9 ist nicht ein vergessenes Literal, sondern die
Sichtbarwerdung dieser Dopplung.

## #14 — Der ConfigMap-Store verliert Schreibvorgänge

**Schwere:** hoch (stiller Datenverlust) · **Repo:** osb-broker-go · **Gelöst:** ja

`K8sStateStore` hat keinen Mutex (`k8sstate.go:34-37`, im Gegensatz zu
`memoryStateStore`), und `save` liest die `resourceVersion` frisch statt sie aus
`load` mitzunehmen (`:130`). Das Read-Modify-Write-Fenster zwischen `load` (`:139`)
und `save` (`:145`) ist damit unbewacht: zwei überlappende Provisions lesen beide
den alten Stand, der zweite überschreibt den ersten konfliktfrei. Kein 409, kein
Retry. Der Definitions-Pfad läuft zusätzlich ganz ohne `Broker.mu`.

**Warum es nicht auffiel:** Im Handdurchlauf lief nie mehr als ein Request
gleichzeitig. Und in CI wird der ConfigMap-Store nie ausgeführt — `ci.yml:111`
ersetzt `STORE_BACKEND=k8s` durch `memory`. Dasselbe blinde Feld erklärt, warum
#1 und #2 erst auf der Plattform auftraten.


**Gelöst in Phase 5:** Ein Objekt je Datensatz, Schreibzugriffe in
`RetryOnConflict`. Ein Konflikt betrifft jetzt nur den einen Datensatz, an dem
wirklich zwei Schreiber arbeiten, statt das gesamte Dokument.

## #15 — `accepts_incomplete` wird an der falschen Stelle gelesen

**Schwere:** hoch, tiefere Ursache von #4 · **Repo:** osb-broker-go

`types.go:24` modelliert `AcceptsIncomplete` als **Body**-Feld. OSB überträgt den
Wert als **Query-Parameter**. `ShouldBindJSON` (`service_instances.go:16`) füllt
das Feld deshalb nie, und der Zweig in `service_instances.go:42-44` ist
unerreichbarer Code — er kann nie gelaufen sein. Ein `c.Query("accepts_incomplete")`
existiert nirgends, `StatusAccepted` kommt im ganzen Repo null Mal vor, und
`GetLastOperation` (`broker.go:324`) gibt hart `succeeded` zurück, auch für eine
unbekannte Instanz-ID.

Damit ist #4 nicht „antwortet 201 statt 202", sondern: der Async-Pfad ist nie
angebunden worden.

## #16 — Drei Codepfade setzen den Namespace hart auf `default`

**Schwere:** hoch, vergrößert #3 · **Repo:** osb-broker-go · **Gelöst:** ja

**Gelöst:** `instanceNamespace()` ersetzt alle hartkodierten Stellen (Update,
last_operation, Deprovision, Bind, Unbind). Der `InstanceRecord` hat jetzt ein
eigenes Namespace-Feld; der hier vorgeschlagene Weg über `AppliedRefs` ist die
zweite Stufe für Datensätze von vorher, dann `default`.

Der Struct-Teil von #3 sind sechs Zeilen. Der Aufwand liegt woanders:
`service_instances.go:112` (Update), `:161` (LastOperation) und
`definition_instances.go:112` (`targetNamespaceFromQuery` — nimmt einen
`*gin.Context` an, verwendet ihn nicht und gibt `"default"` zurück) ignorieren
`targetNamespace` vollständig.

DELETE- und `last_operation`-Requests haben kein `context` im Payload, die
Zuordnung müsste also aus dem `InstanceRecord` kommen — dem fehlt ein
Namespace-Feld (`engine.go:33-46`).

**Nachtrag 2026-09-02, am RabbitMQ-Durchlauf gemessen:** Die hier zunächst
vermutete Folge — Deprovision findet das CR nicht — tritt **nicht** ein.
`DeprovisionInstance` (`engine.go:168-194`) hat einen Drei-Wege-Fallback, und der
erste Weg geht über `AppliedRefs`; ein `ObjectRef` trägt den Namespace mit
(`operator.go:170-175`). Ein im Space-Namespace angelegtes CR wurde korrekt
gelöscht. Das hartkodierte `"default"` greift also nur, wo es keine Refs gibt.

Gemessen bleibt als Wirkung: `last_operation` sucht in `default`, findet die
Instanz nicht und fällt auf den Legacy-Pfad zurück, der hart `succeeded` mit der
Beschreibung „Operation completed successfully" zurückgibt (`broker.go:324-335`)
— nachweisbar an der Beschreibung, denn der Definitions-Pfad würde
„Readiness evaluated from operator CR status" senden. Der Broker meldet damit
Erfolg für eine Instanz, die er nicht findet. Derselbe Weg gilt für
`UpdateInstance` (`service_instances.go:112`) und für Instanzen, deren
`AppliedRefs` fehlen.

## #17 — Benutzerparameter erreichen das Template nicht

**Schwere:** mittel (fehlende Kernfähigkeit) · **Repo:** osb-broker-go · **Gelöst:** ja

`TemplateData.Parameters` (`render.go:65`) und der Template-Alias `"parameters"`
(`:81`) existierten, wurden aber von keinem Aufrufer gefüllt: `RenderProvision`
(`:89-98`) setzte nur `InstanceID`, `SafeName` und `Plan`.
`Engine.ProvisionInstance` (`engine.go:124`) nahm `parameters` an und verwendete
sie nicht. Plan-Parameter funktionierten, `cf create-service -c '{...}'` nicht.

Behoben in `osb-broker-go` `0f107a2`: ein geprüfter Benutzerparameter überlagert
unter `.plan` den gleichnamigen Planwert, `.parameters` bleibt daneben als reine
Benutzersicht. Dabei fielen zwei weitere Befunde mit — `plan_id` ist im `PATCH`
optional (ein reines Parameter-Update lief vorher in `ErrPlanUnknown`), und die
Parameter werden je Instanz gespeichert, womit `GET /v2/service_instances` sie
meldet und ein wiederholtes `PUT` mit abweichenden Parametern `409` ist. Die
Festlegungen stehen in ADR 0007 des Broker-Repos.

Am laufenden Cluster nachgewiesen: `-c '{"storageSize":"2Gi"}'` legt einen
CNPG-Cluster mit 2Gi an, `-c '{"instances":3}'` ist 400. **Dabei aufgefallen:**
Korifi reicht ein `cf update-service -c` gar nicht an den Broker weiter — es
meldet Erfolg, ohne einen `PATCH` zu schicken. Der Broker-Pfad ist direkt über
`kubectl port-forward` geprüft.

## #18 — HTTP-Status aus Fehlertexten geraten

**Schwere:** mittel · **Repo:** osb-broker-go

`osbErrorStatus` (`errors.go:20-34`) klassifiziert über `strings.Contains` auf
Fehlermeldungen. `respondOSBError` (`:39-49`) macht aus jedem DELETE-Fehler mit
„not found" im Text ein `410` — auch aus „service not found" und „plan not found".
`errors.go:26` verwendet zudem den Fehlernamen
`"RequiresAppInstanceAlreadyExists"`, den die OSB-Fehlerliste nicht kennt.

## #19 — Credentials im Klartext in der State-ConfigMap

**Schwere:** mittel · **Repo:** osb-broker-go · **Gelöst:** ja

`Binding.Credentials` (`broker.go:68`) wird über `PutBinding` in die ConfigMap
geschrieben (`k8sstate.go:117`) — Zugangsdaten in einem Objekt, das kein Secret
ist. Betrifft den Legacy-Pfad; der Definitions-Pfad persistiert keine Credentials
(`registry_adapter.go:17-26`), verliert dafür `Context`, `Parameters` und
`DashboardURL`, sodass `GET /v2/service_instances/{id}` leere Parameter liefert.


**Gelöst in Phase 5:** Die Credentials liegen in einem eigenen Secret, auf das
`spec.credentialsSecret` des Bindings verweist - getrennt per RBAC schützbar
und at rest verschlüsselbar. Das Secret trägt eine OwnerReference auf das
Binding und wird beim Löschen zusätzlich explizit entfernt.

## #20 — Die eigene Konformitätssuite widerspricht dem Code

**Schwere:** mittel (falsches Sicherheitsgefühl) · **Repo:** osb-broker-go

`cmd/osb-checker/checks/checks.go:290-298` verlangt beim wiederholten Provision
mit identischen Parametern `200`. Wird cnpg gewählt — der Regelfall in CI, weil
`ci.yml:104-106` alle Definitionen einspielt — läuft das Provision über
`definition_instances.go:48` und sendet **unbedingt 201**. Der Check
`lifecycle-provision-idempotent` muss also fehlschlagen. Zusätzlich prüft
`broker.Provision` (`broker.go:113-122`) Idempotenz nur über `ServiceID`/`PlanID`,
nicht über `Parameters` — abweichende Parameter ergeben `200` statt `409`.

## #21 — Veraltete und doppelte Angaben in den Definitions und Values

**Schwere:** gering · **Repo:** osb-broker-go

- `redpanda-cluster.yaml:6` trägt `broker.osb.io/status: blocked-on-multi-doc-templates`.
  Multi-Doc ist implementiert (`operator.go:218`, `render.go:104`), und das
  Template selbst ist Single-Doc. Die Annotationen liest der Code ohnehin nicht
  (`definition.go:26-28` kennt nur `Name`), beide markierten Services landen im
  Katalog.
- `deploy/helm/osb-broker-go/values-kind.yaml` (615 Zeilen) dupliziert
  `definitions/` (434 Zeilen) als YAML-Strings und hat doppelte Keys:
  `cnpg-postgresql.yaml` in Zeile 15 **und** 448, `minio-objectstorage.yaml` in 67
  und 500, `redis-standalone.yaml` in 125 und 558 — 10 Einträge für 7 Definitionen,
  die letzten gewinnen.
- Vier der sieben Definitions können nicht binden, weil der Operator kein
  Credential-Secret erzeugt und ein Admin es vorab anlegen müsste
  (`redis-standalone.yaml:53`, `valkey-cluster.yaml:55`, `redpanda-cluster.yaml:80`,
  `seaweedfs-s3.yaml:68`); ein Bind endet dort in `404`
  (`definition_bindings.go:24-31`). `minio-objectstorage.yaml` ist im Broker-README
  als DEPRECATED geführt. Belastbar sind damit CNPG und RabbitMQ.

---

# Befunde aus dem RabbitMQ-Durchlauf

Aufgenommen am 2026-09-02. Zweiter Backing-Service neben CNPG, installiert über
`services/rabbitmq/service.env` (RabbitMQ Cluster Operator v2.22.5). Der
Lifecycle wurde direkt über die OSB-API gefahren (Port-Forward auf den Broker),
nicht über `cf` — dadurch ließ sich `context.space_guid` gezielt setzen und das
Verhalten aus #3 und #16 isoliert beobachten.

**Der Zweck dieses Durchlaufs war die Frage, ob die Engine generisch ist. Sie
ist es.** Ein Operator mit anderer CRD-Gruppe, anderen Condition-Typen und
anderem Credential-Layout brauchte **keine einzige Änderung** an
`internal/definition/`:

- `SanitizeInstanceName` trug (`rabbit-messung-01` → `osb-rabbit-messung-01`).
- Das Template wurde gerendert und das CR im richtigen Namespace angelegt,
  sobald `context.space_guid` mitkam.
- `ExtractCredentials` las das Operator-Secret ohne Anpassung.
- `DeprovisionInstance` räumte CR und State restlos ab.

Das einzige Problem lag in der ServiceDefinition selbst (#22), nicht in der
Engine. Das stützt die Empfehlung aus dem Abschnitt Architekturbefunde: Engine
behalten, HTTP- und State-Schicht ersetzen.

## #22 — Die RabbitMQ-Definition prüft eine Condition, die es nicht gibt

**Schwere:** latent (wird durch den Fix von #4/#15 aktiviert) · **Repo:** osb-broker-go

`definitions/rabbitmq-cluster.yaml` erwartet:

```yaml
readiness:
  statusJSONPath: 'status.conditions.#(type=="Ready").status'
  expectedValue: "True"
```

Der Cluster-Operator setzt aber keine Condition dieses Typs. Gemessen an einem
fertig hochgefahrenen Einzelknoten-Cluster:

```
AllReplicasReady=True
ClusterAvailable=True
NoWarnings=False
ReconcileSuccess=Unknown
```

Nach `readiness.go:28` ist ein fehlender Pfad „nicht bereit", ohne Fehler. Die
Instanz wäre damit **dauerhaft** nicht bereit — sobald Readiness überhaupt
ausgewertet wird. Heute fällt das nicht auf, weil #4/#15 den Async-Pfad nie
erreichen. Wer #4 behebt, bricht damit RabbitMQ, wenn #22 nicht mit behoben ist.

**Vorschlag:** `statusJSONPath` auf `AllReplicasReady` umstellen. `ClusterAvailable`
ist der schwächere Zustand (Service erreichbar, nicht alle Replicas bereit) und
für einen `prod`-Plan mit 3 Knoten das falsche Kriterium. `NoWarnings=False` und
`ReconcileSuccess=Unknown` zeigen zugleich, dass ein naives „alle Conditions
müssen True sein" nicht funktionieren würde.

## #23 — Bind gibt alle Secret-Keys unfiltert durch, auch eine Konfigurationsdatei

**Schwere:** gering · **Repo:** osb-broker-go · **Gelöst:** ja (für Definitionen mit mapping)

**Gelöst in Phase 6:** `spec.bind.mapping` gibt die Zielform vor; ist es
gesetzt, besteht das Binding genau aus den genannten Keys. Die
rabbitmq-cluster-Definition nutzt das und liefert seither weder
`default_user.conf` noch `connection_string`. Definitionen ohne `mapping`
verhalten sich unverändert — das ist die Rückwärtskompatibilität aus 6.3,
nicht ein übersehener Rest.

Der Bind liefert acht Keys, so wie der Operator sie schreibt:

```
connection_string, default_user.conf, host, password, port, provider, type, username
```

`default_user.conf` ist keine Zugangsdaten-Angabe, sondern eine vollständige
RabbitMQ-Konfigurationsdatei (`default_user = …\ndefault_pass = …\n…`). Sie landet
unverändert in `VCAP_SERVICES`.

Das Schema kennt für genau diesen Fall ein Feld — `credentialKeys` in
`schemas/service-definition.schema.json` —, das aber in keiner der sieben
Definitions gesetzt ist (siehe #21) und den Filter in `ExtractCredentials`
(`readiness.go:41`) damit nie aktiviert.

**Vorschlag:** In `rabbitmq-cluster.yaml` `credentialKeys` auf
`[host, port, username, password, connection_string]` setzen. Das ist keine
Engine-Änderung — der Filter existiert und funktioniert, er wird nur nicht genutzt.

## #24 — Ein Definitions-Wechsel wirkt erst nach einem Broker-Neustart

**Schwere:** gering, betrifft die Plattform · **Repo:** korifi-platform · **Gelöst:** ja

Nach `helm upgrade` mit einer geänderten Definitions-ConfigMap servierte der
Broker weiter den alten Katalog: `rabbitmq-cluster` fehlte, obwohl die ConfigMap
korrekt war. Der Broker liest die Definitions beim Start (`LoadFromDir`), und die
Chart-Templates tragen keine `checksum`-Annotation auf dem Pod-Template — ein
Upgrade, das nur die ConfigMap ändert, lässt das Deployment also unberührt.

**Gelöst in:** `make broker-deploy` startet den Broker jetzt explizit neu. Die
saubere Lösung gehört ins Chart (`checksum/definitions`-Annotation) und damit in
die Broker-Arbeit.

## #25 — Korifi kennt keinen Wert für eine broker-eigene CA

**Schwere:** mittel, betrifft die Plattform · **Repo:** korifi-platform · **Gelöst:** ja

Mit der TLS-Terminierung im Broker (`osb-broker-go` Phase 4.5) wurde
`experimental.managedServices.trustInsecureBrokers: false` möglich — Korifi
prüft das Broker-Zertifikat dann wirklich. Der Weg dahin ist aber unbequemer als
erwartet: Korifi bietet **keinen** Helm-Wert, um eine broker-spezifische CA zu
hinterlegen. Für den Container-Registry-Pfad gibt es `containerRegistryCACertSecret`,
für Broker nichts Vergleichbares; das Chart hat auch keine `extraVolumes`.

Damit bleibt nur der Eingriff ins Deployment. Für Namen wie
`osb-broker.osb-broker.svc.cluster.local` kann keine öffentliche CA ausstellen,
also braucht die Plattform eine eigene, und deren Root muss in den Trust-Store
der Korifi-Pods.

**Gelöst in:** `platform/15-pki/` — cert-manager erzeugt die Plattform-CA
(`ca.yaml`, `ClusterIssuer osb-ca-issuer`), zwei Strategic-Merge-Patches legen
sie per `SSL_CERT_DIR` in die Trust-Stores von `korifi-api` und
`korifi-controllers`. `make korifi-trust` wendet sie an und hängt am
`korifi`-Target, damit ein Korifi-Upgrade den Zustand nicht still verliert.
Begründung im Detail: `platform/15-pki/README.md`.

**Zwei Details, die Zeit gekostet haben:**

- `SSL_CERT_DIR` statt eines Mounts nach `/etc/ssl/certs`: ein Verzeichnis-Mount
  dorthin verdeckt die öffentlichen Roots. Go liest die Bundle-Datei **und**
  zusätzlich jedes Verzeichnis aus `SSL_CERT_DIR` und hängt dessen Inhalt an.
- Zwei Patch-Dateien statt einer: ein Strategic-Merge-Patch indiziert Container
  über den Namen, und die beiden Deployments haben unterschiedlich heißende
  Container (`korifi-api` bzw. `manager`). Eine Datei mit beiden Einträgen
  hinge jedem Deployment einen zweiten, leeren Container an.

**Offen:** Ein `extraVolumes`/`caCertSecret` für Broker wäre der richtige Ort
upstream. Solange es fehlt, ist der Patch die einzige deklarative Möglichkeit.

## #26 — Chart mountete das TLS-Secret für den nonroot-Container unlesbar

**Schwere:** blockierend, beim Bauen gefunden · **Repo:** osb-broker-go · **Gelöst:** ja

Beim ersten TLS-Deploy lief der Broker in `CrashLoopBackOff` mit
`tls: read certificate: open /etc/osb/tls/tls.crt: permission denied`. Das
Chart mountete das Zertifikats-Secret mit `defaultMode: 0400`; Secret-Dateien
gehören root, das Image (distroless) läuft aber als `nonroot` (65532).

**Gelöst in:** `deploy/helm/osb-broker-go` — `podSecurityContext` mit
`fsGroup: 65532` und Mode `0440`, statt den privaten Schlüssel im Pod
weltlesbar zu machen. Gefunden nur, weil das neue CI-Gate den Chart-Pfad
tatsächlich im Cluster fährt: `helm template` allein hätte das nie gezeigt.

## #27 — Korifis Workload-Zertifikat matcht keinen Hostnamen

**Schwere:** mittel, betrifft die Plattform · **Repo:** korifi (upstream) · **Umgangen:** ja

App-Routen werden über TLS ausgeliefert, die Verschlüsselung war aber
Dekoration: `curl https://go-hello.apps-127-0-0-1.nip.io/` scheitert (Exit 000),
nur mit `-k` kommt eine 200. Zwei Gründe zugleich:

1. Das Zertifikat ist selbstsigniert (Korifis `selfsigned-issuer` im Namespace
   `korifi`) — keine Kette, der jemand vertrauen könnte.
2. Der Wildcard steht **escaped** im Zertifikat: `CN = \*.apps-127-0-0-1.nip.io`,
   inklusive Backslash, ebenso in `dnsNames`. Damit matcht der Name keinen
   realen Hostnamen, selbst wenn man der CA vertraut.

Punkt 2 ist ein Escaping-Fehler in Korifis Chart-Template — der Wert wird
irgendwo als Shell- oder YAML-String maskiert und landet so im CR.

**Umgangen in:** `make korifi-trust` patcht `korifi-workloads-ingress-cert` auf
den `ClusterIssuer osb-ca-issuer` und setzt `commonName`/`dnsNames` unescaped.
Danach validiert `curl --cacert <plattform-ca>` ohne `-k` (Check in
`verify/06-restart.sh`). Der Patch wird aus `APP_DOMAIN` generiert, damit die
Domain nur in `versions.env` steht.

**Achtung bei Korifi-Upgrades:** anders als der Trust-Patch (der nur Einträge
zu Listen hinzufügt und Helms Three-Way-Merge überlebt) überschreibt ein
`helm upgrade` hier ein Skalar-Feld. Der Patch ist danach weg — deshalb hängt
`korifi-trust` am `korifi`-Target.

**Offen:** upstream gehört das Escaping repariert und ein Wert ergänzt, mit dem
sich der Issuer für die Workload-Zertifikate setzen lässt.

## #28 — Definition-Bindings werden nicht persistiert, `GET binding` liefert 404

**Schwere:** mittel (Verletzung der OSB-Spezifikation) · **Repo:** osb-broker-go · **Umgangen:** nein

Beim Umstieg auf den CRD-Store aufgefallen: nach `cf create-service-key` gegen
`cnpg-postgresql` liefert `cf` korrekt Credentials, aber es entsteht **kein**
`OSBServiceBinding`. Der direkte OSB-Aufruf bestätigt die Ursache:

```
GET /v2/service_instances/<id>/service_bindings/<binding-id>
{"description":"binding not found","error":"NotFound"}   HTTP 404
```

`internal/handlers/definition_bindings.go` liest beim Bind das
Operator-Secret live und gibt es zurück, ruft aber nie `PutBinding`. `GetBinding`
fragt ausschließlich den State Store - für Definition-Services findet er dort
nichts. Die Plattform hält das Binding für vorhanden, der Broker weiß nichts
davon.

Das ist **kein** Effekt von Phase 5; der ConfigMap-Store hatte dieselbe Lücke.
Sie fällt jetzt nur auf, weil sich der Zustand mit `kubectl` ansehen lässt.

Zwei Folgen: `GET binding` verletzt die Spezifikation, und die
Deprovision-Sperre („Instanz hat noch Bindings") greift für Definition-Services
nicht, weil die Liste immer leer ist.

Die eigene Konformitätssuite fängt das nicht, weil ihr Lifecycle-Audit auf den
Legacy-Fake-Service fällt, sobald CNPG nicht im Katalog steht - und der
persistiert seine Bindings sehr wohl. Hängt damit an #20.

## #29 — Korifi entfernt keine Katalogeinträge, die aus dem Katalog verschwinden

`cf marketplace` zeigte fünf Angebote, der Broker stellte drei aus:
`database-service` und `example-service` standen weiter im Marketplace, obwohl
sie im OSB-Katalog seit Längerem fehlen.

Korifis Broker-Reconciler legt aus dem Katalog `CFServiceOffering`- und
`CFServicePlan`-Objekte an und aktualisiert sie bei jedem Abgleich. Was aus dem
Katalog **verschwindet**, entfernt er nicht. An den Labels ist es ablesbar:
`cnpg-postgresql` trägt ein `updated_at` vom letzten Abgleich, `database-service`
keines — der Reconciler hat es nicht mehr angefasst und trotzdem stehen lassen.

Die Objekte tragen **keine** `ownerReferences`, eine Garbage Collection über den
`CFServiceBroker` greift also auch nicht.

**Kein Korifi-Sonderfall.** Dieselbe Lücke hat das echte Cloud Foundry
(`cloud_controller_ng` #1911, „Missing service offerings are not removed upon
`cf update-service-broker`"). Sie geht nicht von selbst weg, und sie trifft
Zielplattformen genauso.

**Folge für einen Entwickler:** er bestellt einen Dienst, den es nicht gibt.
Der Broker antwortet auf `create-service` mit einem unbekannten Service — ein
Fehler, dessen Ursache im Marketplace steht, nicht im Broker.

**Behandlung:** `make broker-catalog-prune` hält Korifis Katalogkopie gegen den
live abgefragten Katalog des Brokers und meldet Verwaistes; `APPLY=1` entfernt
es. Zwei Sicherungen: ein leerer oder unlesbarer Katalog löscht nichts (er sähe
aus wie „der Broker stellt nichts mehr aus"), und ein verwaister Plan, an dem
noch eine Instanz hängt, wird nicht entfernt, sondern gemeldet — das ist ein
Befund, kein Aufräumfall.

`verify/05-broker.sh` prüft jetzt **beide** Richtungen: jede ausgerollte
Definition steht im Korifi-Katalog, und jedes Angebot im Korifi-Katalog ist
ausgerollt. Die zweite Richtung fehlte, und ohne sie fällt der Rückstand nie auf.

## #30 — Der Ziel-Namespace kommt aus der Space-GUID, die es auf echtem CF nicht gibt

Erstes `cf create-service` gegen echtes Cloud Foundry, und es scheitert sofort:

```
Job failed: provision could not be completed: Service broker error:
apply Cluster "osb-a6eea3c6-...": create Cluster "osb-a6eea3c6-...":
namespaces "20eca9c4-3dcd-45ab-a076-ffe900f0a82b" not found
```

Der Broker leitet den Namespace der Operator-Ressourcen aus der Space-GUID ab
(FINDINGS #3/#7/#16). Auf Korifi ging das auf, **weil Korifi je Space einen
Kubernetes-Namespace anlegt**. Echtes Cloud Foundry kennt keine Namespaces —
Spaces sind Datensätze im Cloud Controller, sonst nichts. Auf einem Zielsystem
existiert der Namespace also nie, und jedes Provision scheitert.

**Das ist eine Architekturfrage, kein Bug.** Der Broker braucht eine
Namespace-Strategie, die nicht voraussetzt, dass die Plattform Namespaces
erzeugt. Denkbare Richtungen, alle mit Folgen für die Mandantentrennung:

- ein fester Namespace für alle Instanzen (einfach, hebt die Trennung auf),
- ein Namespace je Org oder Space, **vom Broker selbst angelegt** (braucht das
  Recht, Namespaces zu erzeugen),
- eine Zuordnung, die der Betreiber pflegt (kein Automatismus, aber explizit).

**Erledigt am 2026-09-06.** [ADR 0010](../osb-broker-go/docs/de/adr/0010-instance-namespace.md)
entscheidet es: der Betreiber konfiguriert die Abbildung über ein Template auf
den Provision-Kontext, Vorgabe ist der feste Namespace `osb-instances`, und der
Broker legt keinen an. `make instance-namespace` legt ihn an, die Krücke
`make space-namespace` ist entfallen. Live belegt: `cf create-service` legt den
Cluster in `osb-instances` an, ohne dass jemand vorher einen Space-Namespace
erzeugt hätte.

**Der Live-Lauf zeigte dabei einen Fehler, den kein Test hatte:** das Leserecht
auf Namespaces hing am selben Schalter wie das Anlegen, der Broker konnte in
der Vorgabe nicht einmal prüfen und scheiterte mit `Forbidden`. `get` gilt
jetzt immer, und ein verweigertes Lesen lässt die Prüfung aus statt
abzulehnen — es ist kein Beweis, dass etwas fehlt.

Der Befund ist der erste Ertrag des Plattformwechsels: auf Korifi war er
unsichtbar, weil Korifi genau die Voraussetzung schuf, die ein Zielsystem nicht
schafft.

## #31 — Der Vertrauensanker ist hier nicht prüfbar: der Cloud Controller prüft das Broker-Zertifikat nicht

Die Registrierung des Brokers über `https://` mit einem Zertifikat der
plattformeigenen CA geht durch. Das sieht nach einer Antwort auf die offene
Vertrauensanker-Frage aus und ist keine.

`cloud-controller-config` trägt:

```yaml
skip_cert_verify: true
```

Der Cloud Controller prüft das Zertifikat also gar nicht. Die Registrierung
gelingt mit **jedem** Zertifikat, auch einem, das ein Zielsystem ablehnen
würde. Wer daraus „TLS funktioniert" liest, hat nichts gemessen.

**Was daraus folgt.** Erstens: der Vertrauensanker bleibt offen und gehört
weiter auf die Liste vor der 1.0. Zweitens: diese Plattform *könnte* ihn
beantworten — `skip_cert_verify: false` setzen und die Plattform-CA in den
Trust-Store der Cloud-Controller-Pods legen. Dann prüft echter CC-Code ein
echtes Zertifikat, und das wäre eine belastbare Aussage. Das ist ein möglicher
nächster Ausbau dieser Plattform, kein Mangel des Brokers.

## #32 — Eine CF-App erreicht die Dienste des Brokers nicht

Der erste echte Konsument — das Lernspiel — bindet eine `cnpg-postgresql`-Instanz
und kommt nicht an sie heran:

```
Speicherbank antwortet nicht: dial tcp 10.96.234.25:5432: i/o timeout
```

Die Adresse stimmt: `10.96.234.25` ist die ClusterIP des CNPG-Service. Der Name
löst also auf, und die Zugangsdaten sind richtig. **Die Verbindung wird
blockiert.**

Cloud Foundry schottet Anwendungs-Workloads vom Service-Netz des Clusters ab.
Ein Pod im Namespace `cf-workloads` erreicht nicht einmal `kube-dns`:

```
$ kubectl -n cf-workloads run … -- nslookup kubernetes.default.svc.cluster.local
;; connection timed out; no servers could be reached
```

**Das ist korrektes Verhalten der Plattform, kein Defekt.** Eine CF-App soll
nicht im Cluster herumgreifen können. Der Befund liegt bei uns.

### Was daran der Befund ist

**Der Broker gibt Zugangsdaten heraus, die nur innerhalb des Clusters gelten.**
Der Host im Binding ist der blanke Servicename des Operators:

```
host: osb-f7d5a9f7-a53b-4308-8218-d2d6806e01f6-rw
port: 5432
```

Kein Namespace, kein FQDN, keine von außen erreichbare Adresse. Das kommt so aus
dem Secret von CloudNativePG, und die Definition reicht es unverändert durch.

**Auf Korifi fiel das nicht auf**, weil dort Anwendungen als Pods im selben
Cluster liefen und die Abschottung fehlte. Auf einem Zielsystem ist es schlimmer,
nicht besser: bei Tanzu TAS läuft die Anwendung auf einer BOSH-VM, und der
Kubernetes-Cluster steht daneben — dort gibt es überhaupt keinen Weg zu einer
ClusterIP.

### Was es kostet

**Der Broker provisioniert Datenbanken, die eine Cloud-Foundry-Anwendung nicht
benutzen kann.** Der ganze Lebenszyklus ist grün — `create-service`,
`bind-service`, Credentials im `VCAP_SERVICES` — und der eigentliche Zweck des
Bindings wird verfehlt.

Das ist damit gewichtiger als jeder bisher offene Punkt, und es war unsichtbar,
solange niemand die Zugangsdaten wirklich benutzt hat. Genau dafür war das
Dogfooding da.

### Was der Weg dorthin verlangt

Drei Ebenen, und keine davon ist allein Broker-Arbeit:

1. **Der Dienst muss außerhalb des Clusters erreichbar sein** — LoadBalancer,
   NodePort oder ein Gateway mit TCP-Unterstützung. Das entscheidet der
   Betreiber, nicht der Broker.
2. **Das Binding muss diese Adresse ausliefern**, nicht die clusterinterne. Das
   ist Definitionsarbeit (`bind.mapping` schreibt `host` und `uri` um) — und
   der Broker müsste erfahren, welche Adresse gilt.
3. **Die Plattform muss den Weg erlauben.** Bei CF ist das eine Frage der
   Egress-Regeln (`cf security-groups`).

Punkt 3 ist der, den die Entwicklungsplattform hier zusätzlich stellt: selbst
eine erreichbare Adresse hilft nicht, wenn die Security Group der Anwendung sie
nicht freigibt.

### Nebenbefund am Konsumenten, nicht an der Plattform

`database/sql` reicht den Kontext beim **ersten** Verbindungsaufbau nicht an
einen Treiber durch, der nur die alte `Open`-Schnittstelle hat. Ein
`PingContext` mit Deadline blockiert deshalb, bis das Betriebssystem aufgibt;
die Frist gehört als `connect_timeout` in die Verbindungs-URI. Auf einer
abgeschotteten Plattform heißt der Unterschied: Startabbruch statt Fehlermeldung.

### Nachtrag: die Security Group ist nötig und reicht nicht

Der naheliegende und auf produktivem CF **richtige** Weg ist eine Application
Security Group. Durchgespielt:

```
cf create-security-group backing-services rules.json   # 10.96.0.0/16 tcp/5432
cf bind-running-security-group backing-services        # global
cf restart letzter-eintrag
```

**Zwei Zwischenbefunde dabei:**

- **Nur global gebundene Running-Groups werden übersetzt.** Ein
  `cf bind-security-group … --space spike` erzeugte keine Cilium-Regel; erst
  `cf bind-running-security-group` ohne Space tat es.
- Die Regel entsteht dann wirklich: eine `CiliumNetworkPolicy` mit dem Label
  `rule-name: backing-services`, die Egress auf `10.96.0.0/16` und (nach einem
  Nachtrag) `10.244.0.0/16` für Port 5432 erlaubt.

**Und die App kommt trotzdem nicht durch.** Nach mehreren Neustarts mit
nachweislich vorhandener Regel bleibt es bei `i/o timeout`.

Die Erklärung liegt in Ciliums Semantik: **`toCIDR` greift für Ziele
*außerhalb* des Clusters.** Ein Pod oder eine ClusterIP im selben Cluster trägt
eine Cluster-Identität, und CIDR-Regeln matchen sie nicht — dafür bräuchte es
`toEndpoints`. Die ASG-Übersetzung von Cloud Foundry kennt aber nur CIDRs.

**Daraus folgt etwas Grundsätzliches:** auf dieser Plattform kann *keine* ASG
einen clusterinternen Dienst erreichbar machen. Das ist kein Konfigurationsfehler
und keine fehlende Zeile — es ist die Bauform.

### Was der Weg wirklich ist

Damit fällt die Antwort mit der zusammen, die auf Tanzu TAS ohnehin gilt:

> **Der Dienst muss an einer Adresse liegen, die für die Anwendung „außen" ist,
> und das Binding muss genau diese Adresse ausliefern.**

Drei Schritte, und sie verteilen sich sauber entlang des Trennstrichs
([ADR 0011](../osb-broker-go/docs/de/adr/0011-broker-operator-boundary.md)):

| Schritt | Wessen Arbeit |
|---|---|
| Den Dienst je Instanz nach außen legen — `Service` vom Typ `LoadBalancer` neben dem `Cluster`, als zweites Dokument im Provision-Template | **Definition**; die Fähigkeit für mehrteilige Manifeste ist gebaut und hat mit `cnpg-pgvector` einen Nutzer |
| Die vergebene Adresse ins Binding schreiben statt der ClusterIP | **Broker** — und das ist eine echte Lücke: `bind` liest heute nur ein Secret, nicht das `status` eines anderen Objekts |
| Diese Adresse per ASG freigeben | **Betreiber**, und dort greift die ASG dann auch, weil die Adresse „außen" ist |

Auf kind fehlt für Schritt 1 eine LoadBalancer-Umsetzung (MetalLB oder
`cloud-provider-kind`) — Plattformarbeit, kein Broker-Thema.

**Die Lücke im Broker ist Schritt 2** und die einzige, die niemand anders
schließen kann: eine Definition muss sagen können, dass `host` und `uri` aus dem
Status eines Objekts kommen und nicht aus dem Secret des Operators.

### Nachtrag: der vorgeschlagene Schritt 1 trägt nicht — gemessen

Die Tabelle oben behauptet, eine LoadBalancer-Adresse sei für die Anwendung
„außen", und die ASG greife dann. **Das stimmt nicht.** Nachgemessen mit
Ciliums Drop-Monitor, während die App beide Adressen anspricht:

```
drop (Policy denied) flow 0x545495c5 ... file bpf_lxc.c:1370,
  identity 59404->1446: 10.244.2.207:47578 -> 10.244.1.62:5432 tcp SYN
```

Für die ClusterIP **und** für die LoadBalancer-IP `172.18.255.200` entsteht
dieselbe Zeile. Cilium löst den Service auf die Backend-Pod-IP auf, **bevor**
es die Regel auswertet, und prüft dann gegen die *Endpunkt-Identität* des
Ziel-Pods (`1446`). Eine CIDR-Regel kann eine Endpunkt-Identität nie treffen.

Der `ipcache` zeigt, warum der Umweg über eine andere Adresse nichts hilft:

| Adresse | Identität | Bedeutung |
|---|---|---|
| `10.96.234.25` (ClusterIP) | `16777235` | CIDR-Identität — aber vor der Prüfung wegübersetzt |
| `172.18.255.200` (LoadBalancer) | `16777265` | dasselbe |
| `10.244.1.62` (Backend-Pod) | `1446` | Endpunkt-Identität — **das ist, wogegen geprüft wird** |
| `172.18.0.4` (Knoten) | `6` | `reserved:remote-node`, nie von einer CIDR-Regel getroffen |
| `1.1.1.1` | `16777223` | echtes „außen" — dorthin kommt die App durch |

Belegt ist damit auch die Gegenrichtung: die App erreicht `1.1.1.1:443`. Die
CIDR-Maschinerie funktioniert also; sie kann nur kein Ziel im selben Cluster
adressieren.

**Daraus folgt:** LB-IPAM auf kind zu installieren wäre vergebliche Arbeit
gewesen. Cilium bringt es ohnehin mit (`enable-lb-ipam=true`, Pool angelegt,
Adresse vergeben) — es ändert am Ergebnis nichts.

### Was stattdessen gebaut wurde

`network/backing-services-egress.yaml`: eine `CiliumClusterwideNetworkPolicy`,
die den Weg über **Identitäten** statt über Adressen erlaubt — CF-Anwendungen
(`workload-type: app` in `cf-workloads`) dürfen Endpunkte in `osb-instances`
auf 5432/5672/15672 erreichen. Anzuwenden mit `make network`.

Gegenprobe gelaufen: ohne die Regel meldet das Spiel nach 30 s
`GEDÄCHTNIS FLÜCHTIG`, mit ihr `GEDÄCHTNIS DAUERHAFT`. Rätsel 1 ist damit auf
der Plattform lösbar; der Rechner nennt seinen Namen und das Archiv öffnet.

**Der Befund bleibt trotzdem offen.** Die Regel behebt nichts, sie macht den
Defekt hier nur unsichtbar: der Broker liefert weiterhin eine clusterinterne
Adresse aus, und auf Tanzu TAS — Anwendung auf einer BOSH-VM, Cluster daneben —
führt dorthin kein Weg. Offen ist damit die Frage, die vorher hinter Schritt 1
verborgen lag:

> **Soll der Dienst wirklich außerhalb des Clusters liegen?** Das verlangt einen
> Weiterleiter *außerhalb* von Kubernetes (ein Prozess oder Container am
> kind-Docker-Netz, der auf den NodePort zeigt) — erst dann ist die Adresse für
> Cilium „außen", und erst dann greift die ASG. Das ist eine Entscheidung über
> die Bauform der Entwicklungsplattform, keine Zeile Konfiguration.
