# Demo entry point. `make` or `make help` lists everything.
#
# Typical demo:  make start  ->  make verify  ->  make aot-check  ->  make startup-compare  ->  make fail-fast-demo

.DEFAULT_GOAL := help
SHELL := /bin/bash

APPS := app-dev1 app-dev2 app-qa1 app-prod1
ENV ?= dev1

# Local Maven builds need JDK 25. Use $JAVA_HOME if it already is 25, otherwise look in sdkman.
# (Docker targets don't need a local JDK.)
JDK25 := $(shell for d in "$$JAVA_HOME" $$HOME/.sdkman/candidates/java/25*; do \
	[ -x "$$d/bin/java" ] && "$$d/bin/java" -version 2>&1 | grep -q 'version "25' && echo "$$d" && break; done)
export JAVA_HOME := $(JDK25)

.PHONY: help
help: ## List targets
	@awk 'BEGIN {FS = ":.*## "} /^[a-zA-Z_-]+:.*## / {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

.PHONY: check-jdk
check-jdk:
	@[ -n "$(JDK25)" ] || { echo "JDK 25 not found. Set JAVA_HOME to a JDK 25 (e.g. sdk install java 25.0.4-amzn)."; exit 1; }

## ---------- build & test (local JDK 25)

.PHONY: test
test: check-jdk ## Run unit + architecture tests (mvn verify)
	./mvnw -B verify

.PHONY: build
build: check-jdk ## Build the jars, incl. Spring AOT processing (no services needed)
	./mvnw -B package -DskipTests

## ---------- docker demo

.PHONY: image
image: ## Build the ONE app image (trains the AOT cache offline) + the Config Server image
	docker compose build

.PHONY: infra
infra: ## Start Config Server, Vault and MongoDB and wait until healthy
	docker compose up -d --wait config-server vault mongo

.PHONY: bootstrap
bootstrap: ## Per-env Mongo users, Vault secrets/policies/tokens (rotates on every run)
	./scripts/bootstrap.sh

.PHONY: apps
apps: ## Start dev1, dev2, qa1, prod1 from the same image
	docker compose up -d --force-recreate $(APPS)
	@echo "dev1 http://localhost:8081  dev2 http://localhost:8082  qa1 http://localhost:8083  prod1 http://localhost:8084"
	@echo "Try: curl -s localhost:8084/info/runtime | jq    or    make verify"

.PHONY: start
start: image infra bootstrap apps ## Everything: build image, start infra, bootstrap, start all four envs

.PHONY: verify
verify: ## Check each env: profiles, config, secrets, Mongo, data isolation, same image
	./scripts/verify.sh

.PHONY: aot-check
aot-check: ## Show which envs' JVMs used the AOT cache (prod: yes, dev2/ZGC: falls back)
	./scripts/aot-check.sh

.PHONY: startup-compare
startup-compare: ## Startup time: AOT cache + Spring AOT vs Spring AOT only vs neither
	./scripts/startup-compare.sh

.PHONY: fail-fast-demo
fail-fast-demo: ## Show startup failing when Config Server/Vault are unreachable or the token is wrong
	./scripts/fail-fast-demo.sh

.PHONY: report
report: ## Print one env's startup report (ENV=dev1|dev2|qa1|prod1)
	@docker compose logs app-$(ENV) | sed -n '/===== startup report/,/=====================/p'

.PHONY: logs
logs: ## Follow a container's logs (fzf picker; or ENV=dev1|dev2|qa1|prod1 to skip it)
	@./scripts/logs.sh $(if $(filter command line,$(origin ENV)),app-$(ENV))

.PHONY: status
status: ## Show containers and the image each one runs
	docker compose ps --format 'table {{.Service}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'

.PHONY: stop
stop: ## Stop everything (Vault dev mode is in-memory: run `make bootstrap` after the next `make infra`)
	docker compose down

.PHONY: clean
clean: ## Stop everything and delete volumes, .secrets/ and build output
	docker compose down -v --remove-orphans
	rm -rf .secrets
	-./mvnw -B -q clean
