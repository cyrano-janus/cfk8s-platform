# Geheimnisse: wer hält was, und warum OpenBao

Diese Datei beantwortet eine Frage, die beim Aufbau von CI/CD unweigerlich
kommt: *Wo liegen die Geheimnisse?* Sie beantwortet sie für beide Welten, die
hier nebeneinander laufen — Cloud Foundry und Kubernetes —, und sie sagt am
Ende offen, was der Aufbau auf diesem Laptop **nicht** leistet.

## Drei Arten von Geheimnissen, drei Zuständigkeiten

Die wichtigste Unterscheidung zuerst, denn sie erspart die meiste Arbeit:
**Nicht jedes Geheimnis braucht einen Geheimnisspeicher.**

| Art | Beispiel | Wer hält es heute | Braucht es OpenBao? |
|---|---|---|---|
| **Service-Credentials, Kubernetes** | Postgres-Zugang einer Mandanten-Datenbank | der CNPG-Operator, im Secret `<db>-app` (elf Felder, inklusive `uri`) | **nein** — der Operator erzeugt sie und erneuert sie bei Bedarf selbst |
| **Service-Credentials, Cloud Foundry** | Zugang zu einer über `cf create-service` bestellten Datenbank | **CredHub** | **nein** — siehe unten |
| **App-eigene Geheimnisse** | API-Schlüssel eines Drittdienstes, Modell-Token, Webhook-Signaturschlüssel | bisher: nichts. Ein Kubernetes-Secret, von Hand angelegt | **ja** — das ist die Lücke |

Wer OpenBao vor die ersten beiden Zeilen schaltet, baut eine zweite Stelle für
dieselbe Wahrheit. Beim nächsten Wechsel zieht eine nach und die andere nicht.

## Cloud Foundry: CredHub ist schon da

Der Cloud Controller ist mit CredHub verbunden — aus seiner Konfiguration:

```yaml
credential_references:
  interpolate_service_bindings: true
credhub_api:
  internal_url: https://credhub.cf-system.svc.cluster.local:8844
```

Das bedeutet: Gibt ein Broker statt der Zugangsdaten im Klartext eine
`credhub-ref` zurück, holt Cloud Foundry den Wert beim Start der Anwendung aus
CredHub und setzt ihn in `VCAP_SERVICES` ein. Die Anwendung merkt nichts davon
und braucht keine Zeile Code dafür.

**Für CF-Anwendungen ist die Frage damit beantwortet.** Zwei Einschränkungen,
die man kennen sollte:

- Der Broker aus `../osb-broker-go` nutzt das **nicht** — er liefert die
  Zugangsdaten im Klartext. Das ist sichtbar: In `VCAP_SERVICES` einer
  gebundenen Anwendung steht das Passwort. Ihn auf `credhub-ref` umzustellen,
  wäre ein eigener, lohnender Schritt im Broker-Repo.
- CredHub deckt **Service-Bindings** ab, nicht beliebige App-Geheimnisse. Für
  einen Modell-API-Schlüssel bliebe in CF nur ein user-provided service.

## Kubernetes und GitOps: das Problem entsteht erst richtig

Solange man von Hand ausrollt, ist ein Kubernetes-Secret erträglich. Sobald
GitLab und ArgoCD übernehmen, kippt das: **Was ArgoCD ausrollt, steht in Git**,
und ein Kubernetes-Secret ist base64 kodiert, nicht verschlüsselt. Ein
Geheimnis in Git ist ein veröffentlichtes Geheimnis — es bleibt in der
Historie, auch wenn man die Datei später löscht.

Es gibt drei übliche Antworten, und keine ist falsch:

| Weg | Wie es funktioniert | Was es kostet |
|---|---|---|
| **Sealed Secrets** | Der Wert wird verschlüsselt in Git abgelegt; nur der Controller im Zielcluster kann ihn entschlüsseln | keine Rotation, keine Audit-Spur, der Schlüssel klebt am Cluster — ist er weg, ist alles neu einzugeben |
| **SOPS + age** | Wie oben, aber der Schlüssel liegt bei dir statt im Cluster | dieselben Grenzen, dazu eine Schlüsselverwaltung, die jemand führen muss |
| **External Secrets + Speicher** | In Git steht nur eine **Referenz**; ein Operator holt den Wert aus dem Speicher und legt das Kubernetes-Secret an | ein Dienst mehr, der laufen und entsiegelt sein muss |

Hier ist die dritte Zeile gebaut, mit OpenBao als Speicher. Sie ist die
einzige, die Rotation und ein Protokoll ermöglicht — und die einzige mit
laufendem Betrieb.

## Was es im Betrieb bringt

Aus Sicht dessen, der eine Anwendung betreibt — der Reihe nach, vom
Offensichtlichen zum Wichtigen:

**Kein Geheimnis im Git, auch kein verschlüsseltes.** Im Repository steht ein
`ExternalSecret`: „hol den Wert `api-key` aus `mandanten/anna/dienst-x`". Wer
das Repository liest, erfährt, *dass* es einen Schlüssel gibt, nicht *welchen*.

**Ein Wert lässt sich ändern, ohne auszurollen** — mit einer Bedingung, die
man kennen muss. Der Anbieter hat deinen API-Schlüssel zurückgezogen? Neuen
Wert in den Speicher legen; der Operator zieht innerhalb seines Intervalls
nach, ohne Pipeline, ohne Commit. Dasselbe im Git-Verfahren hieße: neu
verschlüsseln, committen, Pipeline abwarten.

Ob die **laufende Anwendung** es merkt, hängt davon ab, wie sie das Geheimnis
einbindet — hier gemessen, mit drei aufeinanderfolgenden Werten:

| Einbindung | Kubernetes-Secret | laufender Pod |
|---|---|---|
| `envFrom` / `env` | zieht nach | **nie** — Umgebungsvariablen stehen beim Start fest |
| als Datei eingehängt (`volumeMounts`) | zieht nach | zieht nach, hier **nach 75 Sekunden** |

Wer also ohne Neustart auskommen will, hängt das Geheimnis als Datei ein und
liest es bei Bedarf neu. Mit `envFrom` braucht es ein
`kubectl rollout restart` — immer noch besser als eine Pipeline, aber kein
Selbstläufer.

**Ein Geheimnis, mehrere Umgebungen.** Entwicklung, Test und Betrieb zeigen auf
denselben Pfad oder auf drei Pfade derselben Struktur. Kopien, die
auseinanderlaufen, entfallen.

**Ablaufdatum statt Dauerpasswort.** Der Speicher kann Zugänge auf Zeit
ausgeben, die von selbst ungültig werden. Damit endet die Klasse von Problemen,
die mit „das Passwort steht seit zwei Jahren im Repository" beginnt. *(Für
Datenbanken ist das hier noch nicht eingerichtet — siehe „Was fehlt".)*

**Eine Spur.** Wer hat wann welches Geheimnis geholt? Nach einem Vorfall ist
das der Unterschied zwischen „wir müssen alles neu vergeben" und „wir wissen,
was betroffen ist".

**Und ein Nachteil, der dazugehört:** Für den Entwickler ist es zunächst *ein
Schritt mehr*. Statt `kubectl create secret` schreibt er ein Objekt und muss
wissen, wo sein Pfad liegt. Der Gewinn zahlt sich erst aus, wenn es mehr als
eine Umgebung und mehr als eine Person gibt.

## Was es hier nicht bringt

**Auf diesem Laptop ist nichts geschützt.** Die Entsiegelungsschlüssel liegen
in `apps/openbao-init.local.json`, auf demselben Rechner wie der Speicher, den
sie öffnen. Wer den Rechner hat, hat beides. Das ist keine Nachlässigkeit,
sondern unvermeidlich: Irgendwo muss der erste Schlüssel liegen, und ein
Entwicklungssystem hat kein zweites Gerät, das ihn halten könnte.

**Gebaut ist es deshalb zum Üben, nicht zum Schützen.** Erlebbar wird:

- dass ein Speicher **versiegelt** startet und jemand ihn öffnen muss,
- wie eine Anwendung an ein Geheimnis kommt, ohne es zu kennen,
- wie ein Mandant nur seinen eigenen Pfad sieht,
- was passiert, wenn sich ein Wert ändert.

Im Betrieb ändert sich genau ein Ding: Die Entsiegelung kommt von woanders —
von mehreren Personen mit je einem Anteil, aus einem Hardware-Modul oder aus
einem zweiten Speicher in einer anderen Fehlerdomäne. Alles andere, was hier
geübt wird, bleibt gleich.

## Wie es eingerichtet ist

```
make apps-openbao       # OpenBao und External Secrets Operator
make openbao-unseal     # nach jedem Start des Clusters
```

- OpenBao läuft im Cluster `apps`, Namespace `openbao`, **nicht** in `cfk8s`
  (das wird regelmäßig neu gebaut) und nicht in `observability` (der
  beobachtet, er trägt keine Dienste).
- Der Grund für genau diesen Cluster ist technisch: OpenBaos
  Kubernetes-Anmeldung prüft ServiceAccount-Tokens über die TokenReview-API
  **seines eigenen** Clusters. Anderswo bräuchte er einen Zugang über die
  Clustergrenze.
- Jeder Mandant bekommt mit `make apps-mandant NAME=<name>` einen Pfad
  `mandanten/<name>/`, eine Policy, die nur diesen Pfad erlaubt, und einen
  `SecretStore` in seinem Namespace. Er muss nichts einrichten.
- Die Anleitung für Mandanten steht in [BEFEHLE.md](BEFEHLE.md), Abschnitt
  „Geheimnisse".

## Was fehlt

- **Zugänge auf Zeit für Datenbanken.** OpenBao kann kurzlebige
  Postgres-Benutzer erzeugen statt fester Passwörter — die eindrucksvollste
  Vorführung des Verfahrens. Dafür bräuchte OpenBao einen Verwaltungszugang zu
  jeder Mandanten-Datenbank, und die entstehen dynamisch.
- **OpenBao als bestellbarer Dienst** (`cf create-service openbao …`). Der
  Broker rendert ServiceDefinitions zu Kubernetes-Ressourcen und braucht dafür
  eine CRD je Instanz; für OpenBao gibt es keinen offiziellen Operator.
- **Der Broker liefert weiter Klartext** statt einer `credhub-ref`.
