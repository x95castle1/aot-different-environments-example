# Example 03: Config Server, Vault and MongoDB contacted at startup, never at build time.
# Self-contained: this folder holds the whole build and everything it runs against (compose.yml: its own Config
# Server, Vault, Mongo). Only demo.sh's report uses the repo's shared demo harness (../../scripts).
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

IMAGE := connections-app:1.0.0

.PHONY: demo
demo: ## Offline build, start dev1, rotate its secret, then break each dependency
	./demo.sh

.PHONY: image
image: ## Build the image (no network for Spring AOT or JDK AOT-cache training)
	docker build --build-arg REVISION=$(REVISION) -t $(IMAGE) .

.PHONY: infra
infra: ## Start this example's Config Server, Vault and MongoDB and wait until healthy
	docker compose up -d --wait --build config-server vault mongo

.PHONY: start
start: image infra ## Infra + dev1's credentials + dev1 on :8301, without the rest of the demo
	./bootstrap.sh dev1
	docker compose up -d --no-deps --force-recreate app-dev1
	@echo "http://localhost:8301/info/connections"

.PHONY: logs
logs: ## Follow dev1's logs
	docker compose logs -f app-dev1

.PHONY: stop
stop: ## Stop dev1 and the infra (Vault is in memory: start bootstraps again)
	docker compose down --remove-orphans

.PHONY: clean
clean: ## Stop everything; remove volumes, secrets, the images and build output
	docker compose down -v --remove-orphans
	rm -rf .secrets
	-docker image rm $(IMAGE) aot-03-config-server:1.0.0
	-./mvnw -B -q clean
