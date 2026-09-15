# Entwicklungsplattform: echtes Cloud Foundry auf kind, plus der eigene
# OSB-Broker und die Operatoren, die er bedient.
#
# WAS HIER LÄUFT UND WAS NICHT
#
# Cloud Foundry selbst rollt `cloudfoundry/kind-deployment` aus — die echten
# Komponenten, cloud_controller_ng (capi), UAA, Diego, gorouter, credhub,
# loggregator. Dieses Repo baut das NICHT nach; es klont den Upstream auf einen
# gepinnten Commit (cf/) und ruft ihn auf.
#
# Was hier gebaut wird, ist alles daneben: die PKI für Broker-TLS, die
# Service-Operatoren, der Broker selbst, seine Registrierung, und die
# Akzeptanzprüfungen, die sagen, ob das Zusammenspiel trägt.
#
# Alle Versionen stehen in versions.env, keine zweite Stelle.

SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

include versions.env
export

CTX     := kind-$(KIND_CLUSTER_NAME)
KUBECTL := kubectl --context $(CTX)
HELM    := helm --kube-context $(CTX)
CF_DIR  := cf/kind-deployment
CM_URL  := https://github.com/cert-manager/cert-manager/releases/download/$(CERT_MANAGER_VERSION)/cert-manager.yaml
CF_API  := https://api.cf.127-0-0-1.nip.io

# BROKER_DEFINITIONS steht in versions.env in Anführungszeichen, damit die
# Shell-Skripte es als eine Variable lesen. Make übernimmt sie wörtlich - ohne
# dieses subst wäre der ganze String EIN Wort.
BROKER_DEFS := $(subst ",,$(BROKER_DEFINITIONS))

## help: diese Übersicht
help:
	@grep -hE '^## ' $(MAKEFILE_LIST) | sed 's/## /  /' | sort

# ---------------------------------------------------------------- Cloud Foundry

## cf-clone: kind-deployment auf den gepinnten Commit klonen
cf-clone:
	@if [ ! -d $(CF_DIR)/.git ]; then \
	   echo ">> klone $(CF_KIND_REPO)"; \
	   git clone -q $(CF_KIND_REPO) $(CF_DIR); \
	 fi
	@cd $(CF_DIR) && git fetch -q origin && git checkout -q $(CF_KIND_COMMIT)
	@echo "   $(CF_DIR) auf $(CF_KIND_COMMIT)"

## cf-tools: Werkzeuge nachlegen, die der Upstream braucht, aber nicht mitbringt
cf-tools: cf-clone
	@# Der Upstream installiert kind, kubectl und crane selbst in sein bin/ -
	@# yq aber nicht, obwohl upload_buildpacks.sh es benutzt. Ohne yq bricht
	@# `make cf-up` mittendrin ab: der Cluster steht dann, die Buildpacks
	@# fehlen, und das faellt erst beim ersten `cf push` auf.
	@if [ ! -x $(CF_DIR)/bin/yq ]; then \
	   echo ">> yq $(YQ_VERSION) nach $(CF_DIR)/bin"; \
	   mkdir -p $(CF_DIR)/bin; \
	   curl -sSL -o $(CF_DIR)/bin/yq \
	     https://github.com/mikefarah/yq/releases/download/$(YQ_VERSION)/yq_linux_amd64; \
	   chmod +x $(CF_DIR)/bin/yq; \
	 else echo "   yq vorhanden"; fi

## cf-up: Cloud Foundry hochziehen (Minuten!) und Buildpacks laden
cf-up: cf-clone cf-tools
	@echo ">> Cloud Foundry auf kind ($(KIND_CLUSTER_NAME))"
	@$(MAKE) -C $(CF_DIR) up
	@$(MAKE) -C $(CF_DIR) bootstrap

## cf-login: bei der CF-API anmelden und Org/Space setzen
cf-login:
	@. $(CF_DIR)/temp/secrets.sh; \
	 cf login -a $(CF_API) -u ccadmin -p "$$CC_ADMIN_PASSWORD" --skip-ssl-validation >/dev/null
	@cf create-org $(CF_ORG) >/dev/null 2>&1 || true
	@cf create-space $(CF_SPACE) -o $(CF_ORG) >/dev/null 2>&1 || true
	@cf target -o $(CF_ORG) -s $(CF_SPACE)

# ---------------------------------------------------------------- Unterbau

## deps: cert-manager (Version aus versions.env)
deps:
	@echo ">> cert-manager $(CERT_MANAGER_VERSION)"
	@$(KUBECTL) apply -f $(CM_URL) >/dev/null
	@$(KUBECTL) -n cert-manager rollout status deploy/cert-manager-webhook --timeout=3m

## pki: Plattform-CA (ClusterIssuer osb-ca-issuer) für Broker-TLS
pki:
	@echo ">> Plattform-CA"
	@$(KUBECTL) apply -f pki/ca.yaml >/dev/null
	@# Der ClusterIssuer wird erst brauchbar, wenn cert-manager das CA-Zertifikat
	@# ausgestellt hat. Ohne dieses Warten scheitert das erste Broker-Zertifikat
	@# mit "secret not found" und das Deployment hängt.
	@$(KUBECTL) -n cert-manager wait --for=condition=Ready certificate/osb-platform-ca --timeout=2m
	@$(KUBECTL) wait --for=condition=Ready clusterissuer/osb-ca-issuer --timeout=2m

## services: alle Backing-Service-Operatoren aus services/*/service.env
services:
	@for f in services/*/service.env; do \
	   [ -f "$$f" ] || continue; \
	   ( set -a; . "$$f"; set +a; \
	     echo ">> $$NAME $$VERSION"; \
	     $(KUBECTL) apply --server-side -f "$$URL" >/dev/null; \
	     $(KUBECTL) -n "$$WAIT_NS" rollout status deploy/"$$WAIT_DEPLOY" --timeout=5m ); \
	 done

# ---------------------------------------------------------------- Broker

## broker: Image bauen, laden, CRDs, Definitions und Rollout in einem
broker: broker-image broker-crds broker-definitions instance-namespace broker-deploy

## broker-image: Image bauen und in den kind-Cluster laden
broker-image:
	@echo ">> baue $(BROKER_IMAGE) aus $(BROKER_SRC)"
	@cd $(BROKER_SRC) && go test ./... >/dev/null && docker build -q -t $(BROKER_IMAGE) . >/dev/null
	@echo ">> lade Image in kind"
	@kind load docker-image $(BROKER_IMAGE) --name $(KIND_CLUSTER_NAME) 2>&1 | grep -v "already present" || true

## broker-crds: State-CRDs des Brokers installieren (clusterweit)
broker-crds:
	@echo ">> State-CRDs"
	@$(KUBECTL) apply -f $(BROKER_SRC)/deploy/crds/ >/dev/null
	@$(KUBECTL) wait --for=condition=Established crd/osbserviceinstances.broker.osb.io crd/osbservicebindings.broker.osb.io --timeout=1m >/dev/null

## broker-definitions: ServiceDefinitions aus dem Broker-Repo als Chart-Werte rendern
broker-definitions:
	@echo ">> rendere Definitions: $(BROKER_DEFS)"
	@{ echo "# GENERIERT von 'make broker-definitions' - nicht bearbeiten."; \
	   echo "definitions:"; echo "  create: true"; echo "  files:"; \
	   for d in $(BROKER_DEFS); do \
	     src=$(BROKER_SRC)/definitions/$$d.yaml; \
	     [ -f "$$src" ] || { echo "FEHLT: $$src" >&2; exit 1; }; \
	     echo "    $$d.yaml: |"; sed 's/^/      /' "$$src"; \
	   done; } > broker/definitions.generated.yaml
	@echo "   $$(wc -l < broker/definitions.generated.yaml) Zeilen gerendert"

## broker-deploy: Helm-Release des Brokers
broker-deploy:
	@test -f broker/values.local.yaml || { \
	  echo "FEHLT: broker/values.local.yaml"; \
	  echo "  cp broker/values.local.yaml.example broker/values.local.yaml"; \
	  echo "  und ein Passwort setzen"; exit 1; }
	@echo ">> Helm-Release $(BROKER_NAME) in $(BROKER_NAMESPACE)"
	@$(HELM) upgrade --install $(BROKER_NAME) $(BROKER_SRC)/deploy/helm/osb-broker-go \
	  --namespace $(BROKER_NAMESPACE) --create-namespace \
	  -f broker/values.cfk8s.yaml \
	  -f broker/definitions.generated.yaml \
	  -f broker/values.local.yaml \
	  --wait --timeout 5m
	@# Pflicht, nicht Vorsicht: der Broker liest die ServiceDefinitions beim
	@# Start (LoadFromDir) und die Chart-Templates tragen keine
	@# checksum-Annotation. Ein Upgrade, das nur die ConfigMap ändert, ließe
	@# das Deployment unberührt - der Broker serviert weiter den alten Katalog.
	@$(KUBECTL) -n $(BROKER_NAMESPACE) rollout restart deployment/$(BROKER_FULLNAME) >/dev/null
	@$(KUBECTL) -n $(BROKER_NAMESPACE) rollout status deployment/$(BROKER_FULLNAME) --timeout=3m

## dev-broker: schneller Dev-Loop (test, build, load, rollout)
dev-broker: broker-image
	@$(KUBECTL) -n $(BROKER_NAMESPACE) rollout restart deployment/$(BROKER_FULLNAME) >/dev/null
	@$(KUBECTL) -n $(BROKER_NAMESPACE) rollout status deployment/$(BROKER_FULLNAME) --timeout=2m

## broker-catalog: OSB-Katalog des Brokers direkt abfragen (ohne CF)
broker-catalog:
	@ops/broker-catalog.sh

## broker-catalog-prune: verwaiste Katalogeinträge melden (APPLY=1 löscht)
broker-catalog-prune:
	@ops/broker-catalog-prune.sh

# ---------------------------------------------------------------- Registrierung

## register: Broker bei CF registrieren und alle Pläne freigeben
register:
	@user=$$($(KUBECTL) -n $(BROKER_NAMESPACE) get secret $(BROKER_FULLNAME)-auth -o jsonpath='{.data.username}' | base64 -d); \
	 pass=$$($(KUBECTL) -n $(BROKER_NAMESPACE) get secret $(BROKER_FULLNAME)-auth -o jsonpath='{.data.password}' | base64 -d); \
	 url=https://$(BROKER_FULLNAME).$(BROKER_NAMESPACE).svc.cluster.local; \
	 if cf service-brokers 2>/dev/null | grep -q '^$(BROKER_NAME) '; then \
	   echo ">> Broker aktualisieren (Katalog neu einlesen)"; \
	   cf update-service-broker $(BROKER_NAME) "$$user" "$$pass" "$$url"; \
	 else \
	   echo ">> Broker registrieren"; \
	   cf create-service-broker $(BROKER_NAME) "$$user" "$$pass" "$$url"; \
	 fi
	@# Anders als Korifi setzt CF Pläne nicht von selbst sichtbar: ein frisch
	@# registrierter Broker taucht im Marketplace GAR NICHT auf, bis der
	@# Zugriff je Angebot freigegeben ist.
	@for d in $(BROKER_DEFS); do cf enable-service-access $$d >/dev/null && echo "   freigegeben: $$d"; done

## unregister: Broker aus CF entfernen (Deployment bleibt)
unregister:
	@cf delete-service-broker $(BROKER_NAME) -f

## instance-namespace: den Namespace anlegen, in dem die Instanzen liegen
instance-namespace:
	@# Der Broker legt ihn nicht selbst an (ADR 0010): er entfernte ihn nie
	@# wieder, weil OSB nur das Loeschen einer INSTANZ kennt und nicht das Ende
	@# eines Mandanten. Also legt ihn der Betreiber an - einmal.
	@$(KUBECTL) create namespace $(INSTANCE_NAMESPACE) --dry-run=client -o yaml | $(KUBECTL) apply -f - >/dev/null
	@echo "   Namespace $(INSTANCE_NAMESPACE) da"

## network: Egress-Regel, die eine ASG hier nicht leisten kann (network/README.md)
network:
	@# Cilium prueft gegen die Endpunkt-Identitaet des Ziel-Pods, nicht gegen
	@# die Service-Adresse. Eine ASG kennt nur CIDRs und kann diesen Weg
	@# deshalb nicht oeffnen - auch nicht ueber einen LoadBalancer. Gemessen
	@# in FINDINGS #32.
	@$(KUBECTL) apply -f network/backing-services-egress.yaml >/dev/null
	@echo "   Egress cf-workloads -> $(INSTANCE_NAMESPACE) erlaubt"

## security-groups: Application Security Groups aus security-groups/ anwenden
security-groups:
	@# Eine ASG, die nur im Cluster steht, ist nach dem naechsten Neuaufbau weg.
	@# Gebunden wird GLOBAL: eine space-gebundene Running-Group wird hier nicht
	@# in eine CiliumNetworkPolicy uebersetzt (siehe security-groups/README.md).
	@for f in security-groups/*.json; do \
	   name=$$(basename "$$f" .json); \
	   if cf security-groups 2>/dev/null | awk '{print $$1}' | grep -qx "$$name"; then \
	     cf update-security-group "$$name" "$$f" >/dev/null; echo "   aktualisiert: $$name"; \
	   else \
	     cf create-security-group "$$name" "$$f" >/dev/null; echo "   angelegt: $$name"; \
	   fi; \
	   cf bind-running-security-group "$$name" >/dev/null; \
	 done
	@echo "   global gebunden. Wirkt fuer laufende Apps erst nach einem Neustart."

# ---------------------------------------------------------------- Prüfen

## verify: alle Akzeptanz-Checks der Reihe nach (read-only, Sekunden)
verify:
	@# 06 bleibt draussen: es prueft den Neustartvertrag und duldet dabei eine
	@# abgelaufene CF-Sitzung. In der taeglichen Pruefung waere diese Nachsicht
	@# falsch.
	@rc=0; for f in verify/0[1-5]*.sh; do bash "$$f" || rc=1; done; exit $$rc

## verify-restart: nach `make start` - ist wirklich alles wiedergekommen?
verify-restart:
	@bash verify/06-restart.sh

## cf-smoke: der Lebenszyklus ueber die echte cf-CLI (Minuten!)
cf-smoke:
	@bash ops/cf-smoke.sh

## conformance: osb-gate direkt gegen den ausgerollten Broker (Minuten!)
conformance:
	@bash ops/conformance.sh

# ---------------------------------------------------------------- Betrieb

## stop: Cluster anhalten, ohne etwas zu löschen (Gegenstück ist make start)
stop:
	@for n in $$(docker ps -q --filter "name=$(KIND_CLUSTER_NAME)-"); do docker stop $$n >/dev/null; done
	@echo "   angehalten. Erhalten bleiben: CF-Objekte, Broker-State, Images."
	@echo "   Wieder hoch mit: make start"

## start: angehaltenen Cluster hochfahren
start:
	@for n in $$(docker ps -aq --filter "name=$(KIND_CLUSTER_NAME)-"); do docker start $$n >/dev/null; done
	@# **Erst auf die API warten, dann auf die Knoten.** Direkt nach dem Start
	@# antwortet der API-Server schon, autorisiert aber noch nicht: der erste
	@# Zugriff kommt als "nodes is forbidden" zurueck, nicht als
	@# "connection refused". Wer darauf abbricht, haelt einen Cluster fuer
	@# kaputt, der zehn Sekunden spaeter laeuft.
	@echo ">> warte auf die API"
	@for i in $$(seq 1 60); do \
	   $(KUBECTL) get nodes >/dev/null 2>&1 && break; \
	   [ $$i = 60 ] && { echo "   API antwortet nicht"; exit 1; }; \
	   sleep 5; \
	 done
	@echo ">> warte auf die Knoten"
	@$(KUBECTL) wait --for=condition=Ready node --all --timeout=5m
	@echo ">> warte auf die CF-Komponenten"
	@$(KUBECTL) -n $(CF_SYSTEM_NAMESPACE) wait --for=condition=Available deploy --all --timeout=10m

## netz-reparieren: nach einem Neustart des Wirts - Cilium und CoreDNS neu registrieren
#
# NICHT nach `make stop`/`make start` noetig, sondern nach einem ungeplanten
# Neustart der Maschine: Docker vergibt den Knoten-Containern dann neue
# Adressen, die CiliumEndpoint- und CiliumNode-Objekte tragen noch die alten,
# und der VXLAN-Tunnel formt sich nie neu. Ergebnis ist ein Cluster, in dem
# kein Pod auf dem Worker das CoreDNS auf der Control-Plane erreicht - jede
# CF-Komponente stirbt an "i/o timeout" bei der Namensaufloesung.
#
# Das Tueckische daran ist, dass es wie Anlaufschwierigkeiten aussieht. Ist es
# aber nicht: der Zustand ist stabil falsch und heilt nicht durch Warten.
# Gemessen in FINDINGS #33 - acht Stunden, ueber 350 Neustarts, unveraendert.
netz-reparieren:
	@$(KUBECTL) -n kube-system rollout restart ds/cilium deploy/cilium-operator deploy/coredns >/dev/null
	@echo ">> warte auf Cilium"
	@$(KUBECTL) -n kube-system rollout status ds/cilium --timeout=5m
	@$(KUBECTL) -n kube-system rollout status deploy/coredns --timeout=2m
	@# Die Gegenprobe gehoert ins Target, nicht in eine Erinnerung: ohne sie
	@# meldet es Erfolg, sobald die Pods laufen - und ob die Aufloesung wieder
	@# geht, hat dann niemand geprueft.
	@echo ">> Gegenprobe: loest ein Pod auf dem Worker wieder auf?"
	@$(KUBECTL) -n $(CF_SYSTEM_NAMESPACE) exec nats-0 -c nats -- \
	   getent hosts postgresql.$(CF_SYSTEM_NAMESPACE).svc.cluster.local >/dev/null \
	   && echo "   DNS antwortet wieder." \
	   || { echo "   DNS antwortet NICHT - der Befund ist ein anderer, siehe FINDINGS #33"; exit 1; }
	@echo "   Die CF-Komponenten brauchen danach einige Minuten; make status zeigt es."

## status: Ist-Zustand auf einen Blick
status:
	@ops/status.sh

## down: Cluster löschen (alles weg)
down: cf-clone
	@$(MAKE) -C $(CF_DIR) down

.PHONY: help cf-clone cf-up cf-login deps pki services broker broker-image broker-crds \
        broker-definitions broker-deploy dev-broker broker-catalog broker-catalog-prune \
        register unregister instance-namespace network security-groups cf-tools verify verify-restart cf-smoke conformance stop start status netz-reparieren down
