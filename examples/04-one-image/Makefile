# Example 04: build once, promote the same image by digest through dev1 -> qa1 -> prod1.
# Needs only a local registry (started automatically); no Config Server, Vault or Mongo.
# Self-contained: this folder holds the whole build and everything it runs against. Only demo.sh's report
# uses the repo's shared demo harness (../../scripts).
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

.PHONY: demo
demo: ## Build once, push, scan the image, promote by digest to dev1/qa1/prod1, compare
	REVISION=$(REVISION) ./demo.sh

.PHONY: status
status: ## Show the registry and the three environments (and which digest each runs)
	@docker compose ps --format 'table {{.Service}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'

.PHONY: stop
stop: ## Stop the registry and environments (the registry's images are kept in its volume)
	docker compose down --remove-orphans

.PHONY: clean
clean: ## Stop everything, delete the registry's storage and build output
	docker compose down -v --remove-orphans
	-./mvnw -B -q clean
