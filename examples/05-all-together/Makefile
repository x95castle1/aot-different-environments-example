# Example 05: all four questions at once. Four environments, one image, real Config Server/Vault/Mongo.
#
# Typical demo:  make start  ->  make verify  ->  make aot-check  ->  make startup-compare  ->  make fail-fast-demo
# Self-contained: this folder holds the whole build and everything it runs against (compose.yml: its own Config
# Server, Vault, Mongo). Only the demo's report and `make logs` use the repo's shared demo harness (../../scripts).
# ---------------------------------------------------------------------------------------------------- make basics
SHELL := /bin/bash
export DOCKER_CLI_HINTS := false        # no "What's next: docker scout ..." hints after builds
.DEFAULT_GOAL := help

# Local Maven builds (make test / build) need JDK 25: $JAVA_HOME if it is 25, otherwise sdkman's. Docker targets don't.
JDK25 := $(shell for d in "$$JAVA_HOME" $$HOME/.sdkman/candidates/java/25*; do \
	[ -x "$$d/bin/java" ] && "$$d/bin/java" -version 2>&1 | grep -q 'version "25' && echo "$$d" && break; done)
export JAVA_HOME := $(JDK25)

# Recorded in the image's OCI labels (see Dockerfile).
export REVISION := $(shell git rev-parse --short HEAD 2>/dev/null || echo unknown)

.PHONY: help
help: ## List targets
	@awk 'BEGIN {FS = ":.*## "} /^[a-zA-Z0-9_-]+:.*## / {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

.PHONY: check-jdk
check-jdk:
	@[ -n "$(JDK25)" ] || { echo "JDK 25 not found. Set JAVA_HOME to a JDK 25 (e.g. sdk install java 25.0.4-amzn)."; exit 1; }

.PHONY: test
test: check-jdk ## Unit + architecture tests (local JDK 25)
	./mvnw -B verify

.PHONY: build
build: check-jdk ## Build locally, incl. Spring AOT processing (no services needed)
	./mvnw -B package -DskipTests

# ---------------------------------------------------------------------------------------------------- this example

ROOT := $(abspath ../..)

APPS := app-dev1 app-dev2 app-qa1 app-prod1
ENVS := dev1 dev2 qa1 prod1
ENV ?= dev1

.PHONY: demo
demo: ## Full demo + report: start everything, verify every env, check JDK AOT-cache use, compare startup times
	./scripts/demo.sh

.PHONY: image
image: ## Build the ONE app image (Spring AOT + JDK AOT-cache training, offline)
	docker compose build app-dev1

.PHONY: infra
infra: ## Start this example's Config Server, Vault and MongoDB and wait until healthy
	docker compose up -d --wait --build config-server vault mongo

.PHONY: bootstrap
bootstrap: ## Per-env Mongo users, Vault secrets/policies/tokens (rotates on every run)
	./bootstrap.sh $(ENVS)

.PHONY: apps
apps: ## Start dev1, dev2, qa1, prod1 from the same image
	docker compose up -d --no-deps --force-recreate $(APPS)
	@echo "dev1 http://localhost:8081  dev2 http://localhost:8082  qa1 http://localhost:8083  prod1 http://localhost:8084"

.PHONY: start
start: image infra bootstrap apps ## Everything: build image, start infra, bootstrap, start all four envs

.PHONY: verify
verify: ## Check each env: profiles, config, secrets, Mongo, data isolation, same image
	./scripts/verify.sh

.PHONY: aot-check
aot-check: ## Which envs' JVMs used the JDK AOT cache (prod/dev1/qa1: yes, dev2/ZGC: falls back)
	./scripts/aot-check.sh

.PHONY: startup-compare
startup-compare: ## prod1 startup four ways: Spring AOT and the JDK AOT cache, each on or off
	./scripts/startup-compare.sh

.PHONY: fail-fast-demo
fail-fast-demo: ## Startup refuses to run when Config Server/Vault are unreachable or the token is wrong
	./scripts/fail-fast-demo.sh

.PHONY: report
report: ## Print one env's startup report (ENV=dev1|dev2|qa1|prod1)
	@docker compose logs app-$(ENV) | sed -n '/===== startup report/,/=====================/p'

.PHONY: logs
logs: ## Follow a container's logs (fzf picker; or ENV=dev1|dev2|qa1|prod1 to skip it)
	@$(ROOT)/scripts/logs.sh $(if $(filter command line,$(origin ENV)),aot-05-all-together-app-$(ENV)-1)

.PHONY: status
status: ## Show this example's containers and the image each one runs
	@docker compose ps --format 'table {{.Service}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'

.PHONY: stop
stop: ## Stop the four environments and the infra (Vault is in memory: start bootstraps again)
	docker compose down --remove-orphans

.PHONY: clean
clean: ## Stop everything; remove volumes, secrets, the images and build output
	docker compose down -v --remove-orphans
	rm -rf .secrets
	-docker image rm demo-app:1.0.0 aot-05-config-server:1.0.0
	-./mvnw -B -q clean
