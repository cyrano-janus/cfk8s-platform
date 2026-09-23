# Application Security Groups

Was hier liegt, öffnet Anwendungen den Weg nach draußen. Cloud Foundry lässt
eine App nur dorthin, wohin eine ASG es erlaubt; die mitgelieferten
`public_networks` und `dns` schließen private Netze aus.

Angewendet wird es mit `make security-groups` — **nicht von Hand**. Eine Regel,
die nur im Cluster steht, ist nach dem nächsten Neuaufbau weg.

## `backing-services.json`

Erlaubt den Weg zu den Diensten des Brokers. **Unter Calico — der CNI dieser
Plattform — reicht sie.** Gemessen: mit ihr erreicht eine Anwendung ihre
Datenbank in 3 ms, ohne sie läuft derselbe Versuch nach fünf Sekunden in einen
`i/o timeout` (FINDINGS #32, `samples/db-probe`).

Der `policy-agent` übersetzt sie in eine `NetworkPolicy` (projectcalico.org) im
Namespace `cf-workloads`, benannt nach der ASG-GUID, und behält dabei die
Adressen bei, die hier stehen.

**Unter Cilium reicht sie nicht.** Dort wird `toCIDR` nur für Ziele *außerhalb*
des Clusters ausgewertet; ein Ziel mit Cluster-Identität matcht es nie, und die
ASG-Übersetzung von Cloud Foundry kennt nur CIDRs. Für diesen Fall liegt in
`network/` eine Umgehung über Identitäten.

## Was beim Binden zu beachten ist

**Nur global gebundene Running-Groups werden übersetzt.** Ein
`cf bind-security-group … --space` erzeugte hier keine Netzregel; erst
`cf bind-running-security-group` ohne Space tat es. `make security-groups`
macht deshalb Letzteres.

**Erteilen und Entziehen wirken nicht gleich schnell.** Gemessen am
2026-09-23: Das Löschen einer Gruppe schlug ohne Zutun durch — der
`policy-agent` nahm die Regel weg, und der nächste Verbindungsversuch derselben
laufenden Anwendung lief in den Timeout. Das Anlegen wirkte erst nach
`cf restart`; vorher liefert der Cloud Controller dem Agenten die neue Gruppe
nicht aus. Für den Betrieb ist das die unbedenkliche Richtung — eine
zurückgenommene Erlaubnis gilt sofort, eine neue erst, wenn die Anwendung sie
abholt.
