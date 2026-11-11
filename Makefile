# Index of the examples. Each example is self-contained (its own Maven build, Dockerfile, infrastructure and
# Makefile: cd examples/NN-* && make help); these targets run across all of them. The shared demo/report harness
# lives in scripts/.
SHELL := /bin/bash
.DEFAULT_GOAL := help

EXAMPLES := examples/01-jvm-args examples/02-dynamic-profiles examples/03-startup-connections \
            examples/04-one-image examples/05-all-together examples/06-training-workload

.PHONY: help
help: ## List targets
	@awk 'BEGIN {FS = ":.*## "} /^[a-zA-Z0-9_-]+:.*## / {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

## ---------- examples

.PHONY: examples
examples: ## Pick an example (or all) with fzf and run its demo; skip the picker with EX=01..06|all
	@./scripts/examples.sh $(EX)

## ---------- build & test every example (local JDK 25)

.PHONY: test
test: ## Unit + architecture tests of every example
	@set -e; for e in $(EXAMPLES); do echo "== $$e"; $(MAKE) -s -C $$e test; done

.PHONY: build
build: ## Build every example locally, incl. Spring AOT processing (no services needed)
	@set -e; for e in $(EXAMPLES); do echo "== $$e"; $(MAKE) -s -C $$e build; done

## ---------- containers across all examples

.PHONY: status
status: ## What's running: which demo (and how far along), every aot-* container, the last report
	@./scripts/status.sh

.PHONY: logs
logs: ## Pick any running container with fzf and follow its logs
	@./scripts/logs.sh

.PHONY: stop
stop: ## Stop every example (each one's apps and infrastructure)
	@for e in $(EXAMPLES); do $(MAKE) -s -C $$e stop >/dev/null 2>&1 || true; done
	@echo "stopped all examples"

.PHONY: clean
clean: ## Stop everything; delete images, volumes, secrets and build output of every example
	@for e in $(EXAMPLES); do $(MAKE) -s -C $$e clean >/dev/null 2>&1 || true; done
