# Arbeitsanweisung für dieses Repo

Entwicklungsplattform für den OSB-Broker aus `../osb-broker-go`: **echtes**
Cloud Foundry auf kind, plus die Operatoren, die der Broker bedient.

**Der Unterschied zum Vorgänger ist der ganze Punkt.** Die frühere Plattform
fuhr Korifi — einen Nachbau der CF-API auf Kubernetes. Hier läuft
`cloud_controller_ng` selbst, dieselbe Software, die ein Zielsystem fährt. Ein
Befund hier ist deshalb eine Aussage über das Zielsystem, kein Hinweis.

## Harte Regeln

1. **Nie ohne Kontext.** Jeder Cluster-Zugriff trägt `--context kind-cfk8s`
   (`kubectl`) bzw. `--kube-context kind-cfk8s` (`helm`). Es existiert ein
   zweiter kind-Cluster `prometheus` mit dem Monitoring des Nutzers. Ein
   falscher `current-context` trifft sonst diesen. Das Makefile macht es über
   `$(KUBECTL)` und `$(HELM)` durchgängig — neue Aufrufe genauso.
2. **`prometheus` nie löschen oder neu aufsetzen.** Er ist als Metrikziel für
   diese Plattform und den Broker vorgesehen; wie, ist noch zu spezifizieren.
3. **`versions.env` ist die einzige Quelle für Versionen.** Keine Version darf
   irgendwo sonst stehen. Das gilt auch für den Upstream: `CF_KIND_COMMIT`
   pinnt `cloudfoundry/kind-deployment` auf einen Commit, nicht auf einen
   Branch — ein Repo, das seine BOSH-Release-Versionen laufend nachzieht,
   änderte sonst unter uns die Plattform, gegen die wir Befunde protokollieren.
4. **Cloud Foundry wird nicht nachgebaut.** Alles, was CF selbst betrifft,
   gehört in den Upstream und wird von hier nur aufgerufen (`cf-up`, `down`).
   Was hier gebaut wird, ist alles daneben: PKI, Operatoren, Broker,
   Registrierung, Prüfungen.
5. **Kein Ad-hoc-`kubectl apply`/`patch` als Lösung.** Jede Änderung am Cluster
   gehört als YAML oder Helm-Value ins Repo und hinter ein Makefile-Target.
   Ad-hoc-Kommandos sind zum Diagnostizieren erlaubt, nicht zum Herstellen von
   Zuständen.
6. **Jedes Target ist idempotent und einzeln aufrufbar.**
7. **Zwischenstände committen.** Ein Arbeitsschritt endet mit sauberem
   Working Tree.
8. **Begründungen gehören in die Datei, nicht in den Chat.** Jede nicht
   offensichtliche Zeile trägt einen Kommentar, der sagt *warum*, nicht *was*.

## Was diese Plattform belegt — und was nicht

Das ist die wichtigste Unterscheidung im Repo, und sie wird leicht überdehnt.

**Belegt: der Protokollvertrag.** Katalogauswertung, `plan_updateable` je Plan,
der `maintenance_info`-Vergleich, `ServicePlanNotUpdateable`, die
PATCH-Weitergabe, asynchrone Vorgänge — das ist derselbe Ruby-Code, den ein
Zielsystem fährt. Grün hier heißt grün dort.

**Nicht belegt: der Betrieb.** TAS läuft auf BOSH-VMs, nicht auf Kubernetes.
Hier liegt der Broker *zufällig* im selben Cluster wie CF; auf einem Zielsystem
läuft er in einem getrennten Cluster der Operatoren
([ADR 0009](../osb-broker-go/docs/de/adr/0009-deployment-model.md)). Daraus
folgen drei Dinge, die hier nicht geprüft werden können und in
[FINDINGS.md](FINDINGS.md) stehen: der Ziel-Namespace (#30), der
Vertrauensanker (#31) und der Netzweg.

Wer einen Befund von hier auf ein Zielsystem überträgt, muss sagen, in welche
der beiden Hälften er fällt.

## Reihenfolge beim Aufbau

```
make cf-up        # Cloud Foundry (Minuten)
make cf-login
make deps pki     # cert-manager, Plattform-CA
make services     # CNPG, RabbitMQ Cluster Operator
cp broker/values.local.yaml.example broker/values.local.yaml   # Passwort setzen
make broker       # bauen, laden, CRDs, Definitions, Rollout
make register     # bei CF registrieren, Pläne freigeben
make verify       # read-only, Sekunden
make conformance  # legt eine echte Instanz an, Minuten
```

## Prüfen

`make verify` ist read-only und läuft in Sekunden — es gehört nach jeder
Änderung gefahren. Zwei Läufe kosten Minuten und bleiben deshalb getrennt, und
sie beantworten **verschiedene** Fragen:

- **`make conformance`** prüft den BROKER. Es spricht direkt mit ihm und sagt,
  ob er OSB 2.17 einhält — unabhängig von jeder Plattform.
- **`make cf-smoke`** prüft das ZUSAMMENSPIEL. Es fährt den Lebenszyklus über
  die echte `cf`-CLI und sagt, ob Cloud Foundry die Zusagen des Brokers so
  liest, wie er sie meint: erreicht ein `cf update-service -c` den Broker,
  lehnt der Cloud Controller einen nicht zugesagten Planwechsel selbst ab,
  wird aus `maintenanceInfo` ein `upgrade available`.

Keiner der beiden beantwortet die Frage des anderen. Wer nur `conformance`
fährt, weiß nicht, ob die Plattform mitspielt; wer nur `cf-smoke` fährt, weiß
bei Rot nicht, ob der Broker oder die Plattform schuld ist.

Beide Richtungen des Katalogs werden geprüft: was ausgerollt ist, muss CF
kennen, **und** was CF kennt, muss ausgerollt sein. Die zweite Richtung fängt
eine bekannte Lücke des Cloud Controllers ab (#1911): er entfernt keine
Angebote, die aus dem Katalog verschwinden. Aufräumen mit
`make broker-catalog-prune APPLY=1`.
