# Included by every Makefile in the repo.
ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/..)
SHELL := /bin/bash

# No "What's next: docker scout ..." hints after builds.
export DOCKER_CLI_HINTS := false
.DEFAULT_GOAL := help

# Local Maven builds need JDK 25. Use $JAVA_HOME if it already is 25, otherwise look in sdkman.
# (Docker targets don't need a local JDK.)
JDK25 := $(shell for d in "$$JAVA_HOME" $$HOME/.sdkman/candidates/java/25*; do \
	[ -x "$$d/bin/java" ] && "$$d/bin/java" -version 2>&1 | grep -q 'version "25' && echo "$$d" && break; done)
export JAVA_HOME := $(JDK25)

# Recorded in each image's OCI labels (see docker/app.Dockerfile).
export REVISION := $(shell git -C $(ROOT) rev-parse --short HEAD 2>/dev/null || echo unknown)

.PHONY: help
help: ## List targets
	@awk 'BEGIN {FS = ":.*## "} /^[a-zA-Z0-9_-]+:.*## / {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

.PHONY: check-jdk
check-jdk:
	@[ -n "$(JDK25)" ] || { echo "JDK 25 not found. Set JAVA_HOME to a JDK 25 (e.g. sdk install java 25.0.4-amzn)."; exit 1; }
