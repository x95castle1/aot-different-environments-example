# Example 02: profiles decided at startup under Spring AOT, plus the @Profile pitfall. No external services needed.
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

IMAGE := profiles-app:1.0.0
RUNS ?= 5

.PHONY: demo
demo: image ## Build, run dev1/dev2/qa1/prod1 (+ debug, + without Spring AOT) from one image, compare, then time each RUNS times
	RUNS=$(RUNS) ./demo.sh

.PHONY: image
image: ## Build the image (Spring AOT + JDK AOT cache trained with the prod flags, offline)
	docker build --build-arg REVISION=$(REVISION) -t $(IMAGE) .

.PHONY: run
run: ## Run one env on :8201: make run APP_ENV=qa APP_ENV_INDEX=1
	docker rm -f aot-02-profiles >/dev/null 2>&1 || true
	docker run -d --name aot-02-profiles -p 8201:8080 -e APP_ENV=$(or $(APP_ENV),dev) -e APP_ENV_INDEX=$(APP_ENV_INDEX) $(IMAGE)
	@sleep 2; curl -s localhost:8201/info/profiles | jq .

.PHONY: stop
stop: ## Remove this example's containers
	-@docker rm -f $$(docker ps -aq --filter 'name=^aot-02-') >/dev/null 2>&1; true

.PHONY: clean
clean: stop ## Remove containers, the image and build output
	-docker image rm $(IMAGE)
	-./mvnw -B -q clean
