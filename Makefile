# Index of the examples. Each example also has its own Makefile (cd examples/NN-* && make help).
include make/common.mk

EXAMPLES := examples/01-jvm-args examples/02-dynamic-profiles examples/03-startup-connections \
            examples/04-one-image examples/05-all-together

## ---------- examples

.PHONY: examples
examples: ## Pick an example (or all) with fzf and run its demo; skip the picker with EX=01..05|all
	@./scripts/examples.sh $(EX)

## ---------- build & test (local JDK 25)

.PHONY: test
test: check-jdk ## Unit + architecture tests for every module
	./mvnw -B verify

.PHONY: build
build: check-jdk ## Build every module, incl. Spring AOT processing (no services needed)
	./mvnw -B package -DskipTests

## ---------- containers across all examples

.PHONY: status
status: ## Every running container from every example (all named aot-*)
	@docker ps --filter 'name=^aot-' --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'

.PHONY: logs
logs: ## Pick any running container with fzf and follow its logs
	@./scripts/logs.sh

.PHONY: stop
stop: ## Stop every example and the shared infrastructure
	@for e in $(EXAMPLES); do $(MAKE) -s -C $$e stop >/dev/null 2>&1 || true; done
	@$(MAKE) -s -C infra stop >/dev/null 2>&1 || true
	@echo "stopped all examples and infra"

.PHONY: clean
clean: ## Stop everything; delete images, volumes, secrets and build output
	@for e in $(EXAMPLES); do $(MAKE) -s -C $$e clean >/dev/null 2>&1 || true; done
	@$(MAKE) -s -C infra clean >/dev/null 2>&1 || true
	-./mvnw -B -q clean
