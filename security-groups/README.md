# Application Security Groups

Was hier liegt, öffnet Anwendungen den Weg nach draußen. Cloud Foundry lässt
eine App nur dorthin, wohin eine ASG es erlaubt; die mitgelieferten
`public_networks` und `dns` schließen private Netze aus.

Angewendet wird es mit `make security-groups` — **nicht von Hand**. Eine Regel,
die nur im Cluster steht, ist nach dem nächsten Neuaufbau weg.

## `backing-services.json`

Erlaubt den Weg zu den Diensten des Brokers. **Sie ist nötig und reicht heute
nicht** — die Langfassung steht in [FINDINGS #32](../FINDINGS.md).

Kurz: Cilium wertet `toCIDR` nur für Ziele **außerhalb** des Clusters aus. Ein
Ziel mit Cluster-Identität matcht es nicht, und die ASG-Übersetzung von Cloud
Foundry kennt nur CIDRs. Solange die Datenbank eine ClusterIP ist, kommt keine
App hin, egal welche Regel man schreibt.

Die Regel steht trotzdem hier, und zwar aus zwei Gründen: sie ist der **richtige
Mechanismus**, sobald der Dienst an einer von außen erreichbaren Adresse liegt,
und sie hält den Befund fest, statt ihn zu vergessen.

## Was beim Binden zu beachten ist

**Nur global gebundene Running-Groups werden übersetzt.** Ein
`cf bind-security-group … --space` erzeugte hier keine `CiliumNetworkPolicy`;
erst `cf bind-running-security-group` ohne Space tat es. `make security-groups`
macht deshalb Letzteres.

Eine Änderung wirkt erst nach einem Neustart der Anwendung.
