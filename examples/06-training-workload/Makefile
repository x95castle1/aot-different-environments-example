# Example 06: train the AOT cache with a real workload (in the pipeline, against throwaway services),
# then measure it against a cache trained on startup only and against no cache, and run it as dev1 and prod1.
#
#   training/compose.yml   the throwaway training stack + the "trainer" (the untrained image recording a cache)
#   compose.yml            the environments dev1 and prod1, with their own Config Server, Vault and Mongo
#
# Self-contained: this folder holds the whole build and everything it runs against. Only demo.sh's report uses the
# repo's shared demo harness (../../scripts).
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

RUNS ?= 5

.PHONY: demo
demo: ## Train with the workload, time all three images in dev1, run the trained image as dev1 + prod1, report
	RUNS=$(RUNS) ./demo.sh

.PHONY: train
train: ## Only the training pipeline: -> workload-app:untrained, :context-trained, :workload-trained
	./training-pipeline.sh

.PHONY: infra
infra: ## Start the environments' Config Server, Vault and MongoDB and wait until healthy
	docker compose up -d --wait --build config-server vault mongo

.PHONY: envs
envs: infra ## Run dev1 (:8602) and prod1 (:8603) from compose.yml (IMAGE=workload-app:<tag>, default workload-trained)
	./bootstrap.sh dev1 prod1
	docker compose up -d --no-deps --force-recreate app-dev1 app-prod1
	@echo "dev1  http://localhost:8602/info/runtime   prod1 http://localhost:8603/info/runtime"

.PHONY: workload
workload: ## Drive the request mix at a running instance: make workload URL=http://localhost:8602 N=300
	./run-workload.sh $(or $(URL),http://localhost:8602) $(or $(N),300) 1 | awk '{c[$$1]++; t+=$$2} END {for (k in c) printf "%s x%d  ", k, c[k]; printf "\ntotal %.3fs\n", t}'

.PHONY: stop
stop: ## Stop the environments and their infra, and remove the training stack
	-@docker compose down --remove-orphans >/dev/null 2>&1; true
	-@docker compose -f training/compose.yml down -v >/dev/null 2>&1; true

.PHONY: clean
clean: stop ## Also remove volumes, secrets, the images and build output
	-@docker compose down -v --remove-orphans >/dev/null 2>&1; true
	rm -rf .secrets
	-docker image rm workload-app:untrained workload-app:context-trained workload-app:workload-trained aot-06-config-server:1.0.0
	-./mvnw -B -q clean
